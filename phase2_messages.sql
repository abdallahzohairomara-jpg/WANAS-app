-- =====================================================================
-- المرحلة 3: الرسائل (شغّله بعد phase1_schema.sql)
-- =====================================================================

-- ترتيب المحادثات حسب آخر نشاط
alter table conversations add column if not exists last_message_at timestamptz not null default now();

create or replace function touch_conversation() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  update conversations set last_message_at = new.created_at where id = new.conversation_id;
  return new;
end $$;

drop trigger if exists on_message_insert on messages;
create trigger on_message_insert after insert on messages
for each row execute function touch_conversation();

-- في المحادثة الفردية: لا إرسال إذا حدث حظر بعد إنشائها
create or replace function can_send(conv uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select
    is_member(conv)
    and not exists (
      select 1
      from conversations c
      join conversation_members o on o.conversation_id = c.id and o.user_id <> auth.uid()
      where c.id = conv and not c.is_group and is_blocked_between(auth.uid(), o.user_id)
    );
$$;

drop policy if exists messages_insert on messages;
create policy messages_insert on messages for insert to authenticated
  with check (sender_id = auth.uid() and can_send(conversation_id));

-- محادثة فردية: يعيد الموجودة أو ينشئ جديدة بعد فحص الحظر وإعدادات الخصوصية
create or replace function get_or_create_dm(other uuid) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  conv uuid;
  pol text;
begin
  if me is null then raise exception 'not authenticated'; end if;
  if other = me then raise exception 'invalid'; end if;
  if is_blocked_between(me, other) then raise exception 'not allowed'; end if;

  select who_can_message into pol from profiles where id = other;
  if pol is null then raise exception 'not found'; end if;
  if pol = 'nobody' or (pol = 'friends' and not are_friends(me, other)) then
    raise exception 'not allowed';
  end if;

  select c.id into conv
  from conversations c
  where not c.is_group
    and exists (select 1 from conversation_members m where m.conversation_id = c.id and m.user_id = me)
    and exists (select 1 from conversation_members m where m.conversation_id = c.id and m.user_id = other)
  limit 1;
  if conv is not null then return conv; end if;

  insert into conversations (is_group, created_by) values (false, me) returning id into conv;
  insert into conversation_members (conversation_id, user_id) values (conv, me), (conv, other);
  return conv;
end $$;

-- مجموعة: المنشئ مشرف، ويُرفض أي عضو محظور أو مغلق الرسائل
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

revoke execute on function get_or_create_dm(uuid) from public, anon;
revoke execute on function create_group(text, uuid[]) from public, anon;
grant execute on function get_or_create_dm(uuid) to authenticated;
grant execute on function create_group(text, uuid[]) to authenticated;

-- الرسائل الفورية (الصلاحيات تُطبَّق على البث أيضًا عبر RLS)
alter publication supabase_realtime add table messages;
