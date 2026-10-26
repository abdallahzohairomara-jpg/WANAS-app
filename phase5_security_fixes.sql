-- =====================================================================
-- إصلاحات أمنية وأخطاء (شغّله بعد phase4_push.sql، آمن للتشغيل أكثر من مرة)
-- كل بند هنا اكتُشف باختبار فعلي على Postgres، لا بالمراجعة النظرية.
-- =====================================================================

-- 1) خطأ: create_group كانت تفشل دائمًا (عدد أعمدة الإدراج لا يطابق القيم)
create or replace function create_group(title text, member_ids uuid[]) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  conv uuid;
  uid uuid;
  pol text;
begin
  if me is null then raise exception 'not authenticated'; end if;
  if title is null or char_length(trim(title)) not between 1 and 60 then
    raise exception 'invalid title';
  end if;
  if array_length(member_ids, 1) is null or array_length(member_ids, 1) > 49 then
    raise exception 'invalid members';
  end if;

  foreach uid in array member_ids loop
    if uid = me then continue; end if;
    if is_blocked_between(me, uid) then raise exception 'not allowed'; end if;
    select who_can_message into pol from profiles where id = uid;
    if pol is null then raise exception 'not found'; end if;
    if pol = 'nobody' or (pol = 'friends' and not are_friends(me, uid)) then
      raise exception 'not allowed';
    end if;
  end loop;

  insert into conversations (is_group, title, created_by)
  values (true, trim(title), me) returning id into conv;
  insert into conversation_members (conversation_id, user_id, is_admin) values (conv, me, true);
  insert into conversation_members (conversation_id, user_id)
    select distinct conv, u from unnest(member_ids) as u where u <> me;
  return conv;
end $$;

-- 2) تسريب: أي مستخدم كان يستطيع سؤال are_friends / is_blocked_between عن
--    شخصين غيره ويعرف من صديق من، ومن حظر من. صارتا تجيبان فقط عن علاقاتك أنت.
create or replace function are_friends(a uuid, b uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(auth.uid() in (a, b), false) and exists (
    select 1 from friendships
    where status = 'accepted'
      and ((requester_id = a and addressee_id = b)
        or (requester_id = b and addressee_id = a))
  );
$$;

create or replace function is_blocked_between(a uuid, b uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(auth.uid() in (a, b), false) and exists (
    select 1 from blocks
    where (blocker_id = a and blocked_id = b)
       or (blocker_id = b and blocked_id = a)
  );
$$;

-- 3) ثغرة: كان يمكن نشر منشور موجّه لقائمة أصدقاء شخص آخر فيصل لأعضائها (إزعاج/انتحال)
drop policy if exists posts_insert on posts;
create policy posts_insert on posts for insert to authenticated
  with check (
    author_id = auth.uid()
    and (list_id is null or exists (
      select 1 from friend_lists l where l.id = list_id and l.owner_id = auth.uid()))
  );

drop policy if exists posts_update on posts;
create policy posts_update on posts for update to authenticated
  using (author_id = auth.uid())
  with check (
    author_id = auth.uid()
    and (list_id is null or exists (
      select 1 from friend_lists l where l.id = list_id and l.owner_id = auth.uid()))
  );

-- 4) تشديد: إنشاء المحادثات وإضافة الأعضاء يمر حصرًا عبر get_or_create_dm
--    وcreate_group (حدّ 50 عضوًا + فحص الحظر وإعدادات الخصوصية). كان العميل
--    يستطيع الإدراج المباشر وتجاوز الحدّ.
drop policy if exists conv_insert on conversations;
drop policy if exists members_insert on conversation_members;
revoke insert on conversations from authenticated, anon;
revoke insert on conversation_members from authenticated, anon;

-- 5) تشديد: الرد على تعليق يجب أن يكون تحت نفس المنشور.
--    دالة منفصلة لأن الاستعلام عن comments داخل سياسة comments يسبب recursion.
create or replace function comment_in_post(cid uuid, pid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from comments c join posts p on p.id = c.post_id
    where c.id = cid and c.post_id = pid and can_view_post(p)
  );
$$;

drop policy if exists comments_insert on comments;
create policy comments_insert on comments for insert to authenticated
  with check (
    author_id = auth.uid()
    and exists (select 1 from posts p where p.id = post_id and can_view_post(p))
    and (parent_id is null or comment_in_post(parent_id, post_id))
  );
