-- =====================================================================
-- المرحلة 7: مركز التحكم في الخلاصة + الذكريات والألبومات + المنشورات المشتركة
-- شغّله بعد phase6_media.sql. آمن للتشغيل أكثر من مرة.
-- =====================================================================

-- ---------------------------------------------------------------------
-- (أ) مركز التحكم في الخلاصة (قواعد صريحة وليست ذكاءً اصطناعيًا)
-- ---------------------------------------------------------------------
alter table posts add column if not exists topics text[] not null default '{}';
do $$ begin
  alter table posts add constraint posts_topics_limit check (cardinality(topics) <= 5);
exception when duplicate_object then null; end $$;
create index if not exists posts_topics_gin on posts using gin (topics);

create table if not exists feed_prefs (
  user_id uuid primary key default auth.uid() references profiles(id) on delete cascade,
  mode text not null default 'custom' check (mode in ('chronological', 'custom')),
  friends_first boolean not null default true,
  lists_first boolean not null default true,
  updated_at timestamptz not null default now()
);

create table if not exists feed_topics (
  user_id uuid not null default auth.uid() references profiles(id) on delete cascade,
  topic text not null check (char_length(topic) between 2 and 30 and topic = lower(topic)),
  action text not null check (action in ('more', 'less', 'hide')),
  primary key (user_id, topic)
);

create or replace function my_topic_count() returns int
language sql stable security definer set search_path = public as $$
  select count(*)::int from feed_topics where user_id = auth.uid();
$$;

alter table feed_prefs enable row level security;
alter table feed_topics enable row level security;
drop policy if exists feed_prefs_own on feed_prefs;
create policy feed_prefs_own on feed_prefs for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
drop policy if exists feed_topics_select on feed_topics;
drop policy if exists feed_topics_insert on feed_topics;
drop policy if exists feed_topics_update on feed_topics;
drop policy if exists feed_topics_delete on feed_topics;
create policy feed_topics_select on feed_topics for select to authenticated using (user_id = auth.uid());
create policy feed_topics_insert on feed_topics for insert to authenticated
  with check (user_id = auth.uid() and my_topic_count() < 50);
create policy feed_topics_update on feed_topics for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy feed_topics_delete on feed_topics for delete to authenticated using (user_id = auth.uid());
revoke all on feed_prefs, feed_topics from anon;

-- الخلاصة: تعمل بصلاحية المستخدم نفسه (security invoker) فتطبّق سياسات المنشورات تلقائيًا.
-- reason: سبب ظهور المنشور (يترجمه التطبيق)
create or replace function get_feed(p_limit int default 30, p_offset int default 0)
returns table (post_id uuid, reason text, score double precision)
language sql stable security invoker set search_path = public as $$
  with prefs as (
    select
      coalesce((select mode from feed_prefs where user_id = auth.uid()), 'custom') as mode,
      coalesce((select friends_first from feed_prefs where user_id = auth.uid()), true) as ff,
      coalesce((select lists_first from feed_prefs where user_id = auth.uid()), true) as lf
  ),
  recent as (
    select * from posts order by created_at desc limit 300
  ),
  scored as (
    select r.id, r.created_at,
      exists (select 1 from feed_topics t where t.user_id = auth.uid() and t.action = 'hide' and t.topic = any (r.topics)) as hidden,
      exists (select 1 from feed_topics t where t.user_id = auth.uid() and t.action = 'more' and t.topic = any (r.topics)) as t_more,
      exists (select 1 from feed_topics t where t.user_id = auth.uid() and t.action = 'less' and t.topic = any (r.topics)) as t_less,
      (r.author_id <> auth.uid() and are_friends(auth.uid(), r.author_id)) as is_friend,
      (r.audience = 'list' and r.author_id <> auth.uid()) as via_list
    from recent r
  )
  select s.id,
    case
      when p.mode = 'chronological' then 'chronological'
      when s.t_more then 'topic_more'
      when s.via_list and p.lf then 'list'
      when s.is_friend and p.ff then 'friend'
      else 'recent'
    end,
    extract(epoch from s.created_at) / 3600.0
      + case when p.mode = 'chronological' then 0 else
          (case when s.t_more then 36 else 0 end)
          + (case when s.t_less then -72 else 0 end)
          + (case when s.via_list and p.lf then 48 else 0 end)
          + (case when s.is_friend and p.ff then 24 else 0 end)
        end
  from scored s cross join prefs p
  where not s.hidden
  order by 3 desc, s.created_at desc
  limit least(greatest(p_limit, 1), 100) offset greatest(p_offset, 0);
$$;

create or replace function reset_feed_prefs() returns void
language sql security invoker set search_path = public as $$
  delete from feed_topics where user_id = auth.uid();
  delete from feed_prefs where user_id = auth.uid();
$$;

-- ---------------------------------------------------------------------
-- (ب) الذكريات والألبومات (خاصة بصاحبها)
-- ---------------------------------------------------------------------
create table if not exists albums (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null default auth.uid() references profiles(id) on delete cascade,
  title text not null check (char_length(trim(title)) between 1 and 60),
  created_at timestamptz not null default now()
);
create table if not exists album_items (
  album_id uuid not null references albums(id) on delete cascade,
  post_id uuid not null references posts(id) on delete cascade,
  added_at timestamptz not null default now(),
  primary key (album_id, post_id)
);
create table if not exists memory_settings (
  user_id uuid primary key default auth.uid() references profiles(id) on delete cascade,
  on_this_day boolean not null default false
);

create or replace function my_album_count() returns int
language sql stable security definer set search_path = public as $$
  select count(*)::int from albums where owner_id = auth.uid();
$$;

alter table albums enable row level security;
alter table album_items enable row level security;
alter table memory_settings enable row level security;
drop policy if exists albums_select on albums;
drop policy if exists albums_insert on albums;
drop policy if exists albums_update on albums;
drop policy if exists albums_delete on albums;
create policy albums_select on albums for select to authenticated using (owner_id = auth.uid());
create policy albums_insert on albums for insert to authenticated
  with check (owner_id = auth.uid() and my_album_count() < 50);
create policy albums_update on albums for update to authenticated
  using (owner_id = auth.uid()) with check (owner_id = auth.uid());
create policy albums_delete on albums for delete to authenticated using (owner_id = auth.uid());

-- لا يظهر في الألبوم إلا ما ما زلت تملك صلاحية رؤيته الآن (جدول posts نفسه يطبّق can_view_post)
drop policy if exists album_items_select on album_items;
drop policy if exists album_items_insert on album_items;
drop policy if exists album_items_delete on album_items;
create policy album_items_select on album_items for select to authenticated
  using (exists (select 1 from albums a where a.id = album_id and a.owner_id = auth.uid())
         and exists (select 1 from posts p where p.id = post_id));
create policy album_items_insert on album_items for insert to authenticated
  with check (exists (select 1 from albums a where a.id = album_id and a.owner_id = auth.uid())
              and exists (select 1 from posts p where p.id = post_id));
create policy album_items_delete on album_items for delete to authenticated
  using (exists (select 1 from albums a where a.id = album_id and a.owner_id = auth.uid()));

drop policy if exists memory_settings_own on memory_settings;
create policy memory_settings_own on memory_settings for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
revoke all on albums, album_items, memory_settings from anon;

-- "في مثل هذا اليوم": منشوراتي ومنشورات ألبوماتي التي ما زلت أراها، من سنوات سابقة
create or replace function on_this_day(p_tz text default 'UTC')
returns setof posts
language sql stable security invoker set search_path = public as $$
  select p.* from posts p
  where (p.author_id = auth.uid()
         or exists (select 1 from album_items i join albums a on a.id = i.album_id
                    where i.post_id = p.id and a.owner_id = auth.uid()))
    and to_char(p.created_at at time zone p_tz, 'MM-DD') = to_char(now() at time zone p_tz, 'MM-DD')
    and (p.created_at at time zone p_tz)::date < (now() at time zone p_tz)::date
  order by p.created_at desc
  limit 50;
$$;

-- تصدير ذكرياتي (منشوراتي وألبوماتي) كـ JSON
create or replace function export_my_memories() returns jsonb
language sql stable security invoker set search_path = public as $$
  select jsonb_build_object(
    'exported_at', now(),
    'posts', coalesce((select jsonb_agg(jsonb_build_object(
        'id', p.id, 'body', p.body, 'audience', p.audience, 'topics', p.topics, 'created_at', p.created_at)
        order by p.created_at) from posts p where p.author_id = auth.uid()), '[]'::jsonb),
    'albums', coalesce((select jsonb_agg(jsonb_build_object(
        'title', a.title, 'created_at', a.created_at,
        'post_ids', coalesce((select jsonb_agg(i.post_id) from album_items i where i.album_id = a.id), '[]'::jsonb)))
        from albums a where a.owner_id = auth.uid()), '[]'::jsonb)
  );
$$;

-- ---------------------------------------------------------------------
-- (ج) المنشورات المشتركة: مالك واحد ومشاركون يوافقون بأنفسهم
-- ---------------------------------------------------------------------
create table if not exists post_participants (
  post_id uuid not null references posts(id) on delete cascade,
  user_id uuid not null references profiles(id) on delete cascade,
  invited_by uuid not null default auth.uid() references profiles(id) on delete cascade,
  status text not null default 'invited' check (status in ('invited', 'accepted', 'declined')),
  created_at timestamptz not null default now(),
  responded_at timestamptz,
  primary key (post_id, user_id)
);
create table if not exists post_contributions (
  id uuid primary key default gen_random_uuid(),
  post_id uuid not null references posts(id) on delete cascade,
  author_id uuid not null default auth.uid() references profiles(id) on delete cascade,
  body text not null check (char_length(trim(body)) between 1 and 1000),
  created_at timestamptz not null default now()
);

-- دوال مساعدة تتجاوز RLS داخليًا لتفادي الحلقات
create or replace function is_participant(pid uuid, uid uuid, accepted_only boolean default false)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from post_participants pp
                 where pp.post_id = pid and pp.user_id = uid
                   and (not accepted_only or pp.status = 'accepted'));
$$;
create or replace function post_owner(pid uuid) returns uuid
language sql stable security definer set search_path = public as $$
  select author_id from posts where id = pid;
$$;
create or replace function participant_count(pid uuid) returns int
language sql stable security definer set search_path = public as $$
  select count(*)::int from post_participants where post_id = pid;
$$;

-- المدعو والمشارك يرون المنشور (ما لم يكن بينهم وبين المالك حظر)
create or replace function can_view_post(p posts) returns boolean
language sql stable security definer set search_path = public as $$
  select
    auth.uid() is not null
    and (
      p.author_id = auth.uid()
      or (
        not is_blocked_between(auth.uid(), p.author_id)
        and (
          exists (select 1 from post_participants pp
                  where pp.post_id = p.id and pp.user_id = auth.uid()
                    and pp.status in ('invited', 'accepted'))
          or (
            not exists (select 1 from post_exclusions e
                        where e.post_id = p.id and e.excluded_id = auth.uid())
            and (
              p.audience = 'public'
              or (p.audience = 'friends' and are_friends(auth.uid(), p.author_id))
              or (p.audience = 'list' and exists (
                    select 1 from friend_list_members m
                    where m.list_id = p.list_id and m.member_id = auth.uid()))
            )
          )
        )
      )
    );
$$;

alter table post_participants enable row level security;
alter table post_contributions enable row level security;
drop policy if exists pp_select on post_participants;
drop policy if exists pp_insert on post_participants;
drop policy if exists pp_update on post_participants;
drop policy if exists pp_delete on post_participants;
-- المالك يرى الكل، والمدعو يرى صفّه، والبقية لا يرون إلا من وافق
create policy pp_select on post_participants for select to authenticated
  using (
    user_id = auth.uid()
    or post_owner(post_id) = auth.uid()
    or (status = 'accepted' and not is_blocked_between(auth.uid(), user_id)
        and exists (select 1 from posts p where p.id = post_id))
  );
-- الدعوة: المالك فقط، لصديق غير محظور، حتى 10 مشاركين، ولا يدعو نفسه
create policy pp_insert on post_participants for insert to authenticated
  with check (
    post_owner(post_id) = auth.uid()
    and invited_by = auth.uid()
    and user_id <> auth.uid()
    and status = 'invited'
    and are_friends(auth.uid(), user_id)
    and not is_blocked_between(auth.uid(), user_id)
    and participant_count(post_id) < 10
  );
-- المشارك يرد على دعوته فقط (التفاصيل تحرسها الزناد أدناه)
create policy pp_update on post_participants for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
-- الانسحاب (المشارك) أو الإزالة (المالك)
create policy pp_delete on post_participants for delete to authenticated
  using (user_id = auth.uid() or post_owner(post_id) = auth.uid());

create or replace function pp_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.post_id <> old.post_id or new.user_id <> old.user_id or new.invited_by <> old.invited_by
     or new.created_at <> old.created_at then
    raise exception 'immutable columns';
  end if;
  if old.status <> 'invited' or new.status not in ('accepted', 'declined') then
    raise exception 'only a pending invitation can be answered';
  end if;
  new.responded_at := now();
  return new;
end $$;
drop trigger if exists pp_guard_trg on post_participants;
create trigger pp_guard_trg before update on post_participants
  for each row execute function pp_guard();

-- عند الانسحاب أو الإزالة تُحذف مساهمات الشخص من المنشور
create or replace function pp_cleanup() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  delete from post_contributions where post_id = old.post_id and author_id = old.user_id;
  return old;
end $$;
drop trigger if exists pp_cleanup_trg on post_participants;
create trigger pp_cleanup_trg after delete on post_participants
  for each row execute function pp_cleanup();

-- المساهمات: لا تظهر ولا تُكتب إلا من مشارك وافق، ويراها من يستطيع رؤية المنشور
drop policy if exists pc_select on post_contributions;
drop policy if exists pc_insert on post_contributions;
drop policy if exists pc_delete on post_contributions;
create policy pc_select on post_contributions for select to authenticated
  using (
    exists (select 1 from posts p where p.id = post_id)
    and (is_participant(post_id, author_id, true) or post_owner(post_id) = author_id)
  );
create policy pc_insert on post_contributions for insert to authenticated
  with check (
    author_id = auth.uid()
    and is_participant(post_id, auth.uid(), true)
    and exists (select 1 from posts p where p.id = post_id)
  );
create policy pc_delete on post_contributions for delete to authenticated
  using (author_id = auth.uid() or post_owner(post_id) = auth.uid());
revoke all on post_participants, post_contributions from anon;
