-- =====================================================================
-- المرحلة 8: ستوريات + تفاعلات + منشن + شير + جروبات + إعدادات + اقتراحات
-- شغّله بعد phase7_features.sql. آمن للتشغيل أكثر من مرة.
-- =====================================================================

-- ---------- أنواع جديدة ----------
alter type media_kind add value if not exists 'document';
alter type report_target add value if not exists 'story';
alter type report_target add value if not exists 'group';

-- ---------------------------------------------------------------------
-- (1) الإعدادات والكتم
-- ---------------------------------------------------------------------
create table if not exists user_settings (
  user_id uuid primary key default auth.uid() references profiles(id) on delete cascade,
  -- الخصوصية
  who_can_mention text not null default 'everyone' check (who_can_mention in ('everyone', 'friends', 'nobody')),
  who_can_add_me text not null default 'everyone' check (who_can_add_me in ('everyone', 'nobody')),
  default_audience post_audience not null default 'friends',
  default_allow_download boolean not null default true,
  default_allow_share boolean not null default true,
  -- الإشعارات
  notify_messages boolean not null default true,
  notify_calls boolean not null default true,
  notify_mentions boolean not null default true,
  notify_comments boolean not null default true,
  notify_reactions boolean not null default true,
  notify_friend_requests boolean not null default true,
  notify_groups boolean not null default true,
  notify_stories boolean not null default true,
  quiet_start smallint check (quiet_start between 0 and 23),
  quiet_end smallint check (quiet_end between 0 and 23),
  focus_until timestamptz,
  -- الوسائط
  autoplay text not null default 'wifi' check (autoplay in ('always', 'wifi', 'never')),
  data_saver boolean not null default false,
  upload_quality text not null default 'original' check (upload_quality in ('original', 'high', 'saver')),
  -- المظهر والاستخدام
  theme_mode text not null default 'system' check (theme_mode in ('system', 'light', 'dark')),
  font_scale real not null default 1.0 check (font_scale between 0.8 and 1.6),
  daily_limit_minutes integer check (daily_limit_minutes between 5 and 1440),
  updated_at timestamptz not null default now()
);

create table if not exists user_mutes (
  user_id uuid not null default auth.uid() references profiles(id) on delete cascade,
  muted_id uuid not null references profiles(id) on delete cascade,
  until timestamptz,
  scope text not null default 'all' check (scope in ('posts', 'stories', 'all')),
  created_at timestamptz not null default now(),
  primary key (user_id, muted_id),
  check (user_id <> muted_id)
);

create table if not exists story_hidden_from (
  owner_id uuid not null default auth.uid() references profiles(id) on delete cascade,
  hidden_id uuid not null references profiles(id) on delete cascade,
  primary key (owner_id, hidden_id),
  check (owner_id <> hidden_id)
);

alter table user_settings enable row level security;
alter table user_mutes enable row level security;
alter table story_hidden_from enable row level security;
drop policy if exists user_settings_own on user_settings;
create policy user_settings_own on user_settings for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
drop policy if exists user_mutes_own on user_mutes;
create policy user_mutes_own on user_mutes for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid() and muted_id <> auth.uid());
drop policy if exists story_hidden_own on story_hidden_from;
create policy story_hidden_own on story_hidden_from for all to authenticated
  using (owner_id = auth.uid()) with check (owner_id = auth.uid());
revoke all on user_settings, user_mutes, story_hidden_from from anon;

create or replace function accepts_friend_requests(uid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select who_can_add_me = 'everyone' from user_settings where user_id = uid), true);
$$;

-- طلب الصداقة يحترم إعداد "من يستطيع إضافتي"
drop policy if exists friendships_insert on friendships;
create policy friendships_insert on friendships for insert to authenticated
  with check (requester_id = auth.uid() and status = 'pending'
              and not is_blocked_between(requester_id, addressee_id)
              and accepts_friend_requests(addressee_id));

-- ---------------------------------------------------------------------
-- (2) الجروبات
-- ---------------------------------------------------------------------
create table if not exists groups (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(trim(name)) between 2 and 60),
  description text not null default '' check (char_length(description) <= 500),
  rules text not null default '' check (char_length(rules) <= 2000),
  privacy text not null default 'public' check (privacy in ('public', 'private')),
  post_approval boolean not null default false,
  created_by uuid not null default auth.uid() references profiles(id) on delete cascade,
  created_at timestamptz not null default now()
);
create table if not exists group_members (
  group_id uuid not null references groups(id) on delete cascade,
  user_id uuid not null references profiles(id) on delete cascade,
  role text not null default 'member' check (role in ('owner', 'admin', 'member')),
  status text not null default 'active' check (status in ('active', 'pending', 'invited', 'banned')),
  joined_at timestamptz not null default now(),
  primary key (group_id, user_id)
);
create index if not exists group_members_user on group_members (user_id);

create or replace function group_role(gid uuid, uid uuid) returns text
language sql stable security definer set search_path = public as $$
  select role from group_members where group_id = gid and user_id = uid and status = 'active';
$$;
create or replace function group_is_public(gid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select privacy = 'public' from groups where id = gid), false);
$$;
create or replace function is_group_member(gid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select group_role(gid, auth.uid()) is not null;
$$;
create or replace function is_group_admin(gid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(group_role(gid, auth.uid()) in ('owner', 'admin'), false);
$$;

alter table groups enable row level security;
alter table group_members enable row level security;
drop policy if exists groups_select on groups;
drop policy if exists groups_update on groups;
drop policy if exists groups_delete on groups;
create policy groups_select on groups for select to authenticated using (true);
create policy groups_update on groups for update to authenticated
  using (is_group_admin(id)) with check (is_group_admin(id));
create policy groups_delete on groups for delete to authenticated
  using (group_role(id, auth.uid()) = 'owner');
drop policy if exists gm_select on group_members;
create policy gm_select on group_members for select to authenticated
  using (user_id = auth.uid()
         or is_group_admin(group_id)
         or (status = 'active' and (is_group_member(group_id) or group_is_public(group_id))));
revoke insert on groups from authenticated, anon;
revoke insert, update, delete on group_members from authenticated, anon;
revoke all on groups, group_members from anon;

create or replace function create_group_space(p_name text, p_description text default '', p_privacy text default 'public')
returns uuid language plpgsql security definer set search_path = public as $$
declare gid uuid;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if (select count(*) from groups where created_by = auth.uid()) >= 20 then
    raise exception 'group limit reached';
  end if;
  insert into groups (name, description, privacy, created_by)
    values (p_name, coalesce(p_description, ''), p_privacy, auth.uid()) returning id into gid;
  insert into group_members (group_id, user_id, role, status) values (gid, auth.uid(), 'owner', 'active');
  return gid;
end $$;

create or replace function join_group(gid uuid) returns text
language plpgsql security definer set search_path = public as $$
declare cur group_members; pub boolean;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select * into cur from group_members where group_id = gid and user_id = auth.uid();
  if found then
    if cur.status = 'banned' then raise exception 'banned'; end if;
    if cur.status = 'invited' then
      update group_members set status = 'active', joined_at = now() where group_id = gid and user_id = auth.uid();
      return 'active';
    end if;
    return cur.status;
  end if;
  select privacy = 'public' into pub from groups where id = gid;
  if pub is null then raise exception 'no such group'; end if;
  insert into group_members (group_id, user_id, role, status)
    values (gid, auth.uid(), 'member', case when pub then 'active' else 'pending' end);
  return case when pub then 'active' else 'pending' end;
end $$;

create or replace function leave_group(gid uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if group_role(gid, auth.uid()) = 'owner' then raise exception 'owner cannot leave'; end if;
  delete from group_members where group_id = gid and user_id = auth.uid() and status <> 'banned';
end $$;

create or replace function respond_group_request(gid uuid, uid uuid, approve boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_group_admin(gid) then raise exception 'forbidden'; end if;
  if not exists (select 1 from group_members where group_id = gid and user_id = uid and status = 'pending') then
    raise exception 'no pending request';
  end if;
  if approve then
    update group_members set status = 'active', joined_at = now() where group_id = gid and user_id = uid;
  else
    delete from group_members where group_id = gid and user_id = uid;
  end if;
end $$;

create or replace function invite_to_group(gid uuid, uid uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_group_admin(gid) then raise exception 'forbidden'; end if;
  if not are_friends(auth.uid(), uid) or is_blocked_between(auth.uid(), uid) then
    raise exception 'can only invite friends';
  end if;
  if exists (select 1 from group_members where group_id = gid and user_id = uid) then
    raise exception 'already related';
  end if;
  insert into group_members (group_id, user_id, role, status) values (gid, uid, 'member', 'invited');
end $$;

create or replace function respond_group_invite(gid uuid, accept boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from group_members where group_id = gid and user_id = auth.uid() and status = 'invited') then
    raise exception 'no invitation';
  end if;
  if accept then
    update group_members set status = 'active', joined_at = now() where group_id = gid and user_id = auth.uid();
  else
    delete from group_members where group_id = gid and user_id = auth.uid();
  end if;
end $$;

create or replace function set_group_role(gid uuid, uid uuid, new_role text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if group_role(gid, auth.uid()) <> 'owner' then raise exception 'forbidden'; end if;
  if new_role not in ('admin', 'member') then raise exception 'bad role'; end if;
  update group_members set role = new_role
    where group_id = gid and user_id = uid and status = 'active' and role <> 'owner';
end $$;

create or replace function remove_group_member(gid uuid, uid uuid, ban boolean default false) returns void
language plpgsql security definer set search_path = public as $$
declare target text; me text;
begin
  me := group_role(gid, auth.uid());
  target := group_role(gid, uid);
  if me not in ('owner', 'admin') then raise exception 'forbidden'; end if;
  if target = 'owner' then raise exception 'cannot remove owner'; end if;
  if target = 'admin' and me <> 'owner' then raise exception 'only owner removes admins'; end if;
  if ban then
    update group_members set status = 'banned', role = 'member' where group_id = gid and user_id = uid;
  else
    delete from group_members where group_id = gid and user_id = uid;
  end if;
end $$;

-- ---------------------------------------------------------------------
-- (3) أعمدة المنشورات الجديدة + قاعدة الرؤية
-- ---------------------------------------------------------------------
alter table posts add column if not exists allow_download boolean not null default true;
alter table posts add column if not exists allow_share boolean not null default true;
alter table posts add column if not exists archived_at timestamptz;
alter table posts add column if not exists publish_at timestamptz;
alter table posts add column if not exists shared_post_id uuid references posts(id) on delete set null;
alter table posts add column if not exists group_id uuid references groups(id) on delete cascade;
alter table posts add column if not exists group_status text not null default 'published';
do $$ begin
  alter table posts add constraint posts_group_status_chk check (group_status in ('published', 'pending'));
exception when duplicate_object then null; end $$;
create index if not exists posts_group on posts (group_id, created_at desc) where group_id is not null;

create or replace function can_view_post(p posts) returns boolean
language sql stable security definer set search_path = public as $$
  select
    auth.uid() is not null
    and (
      p.author_id = auth.uid()
      or (
        not is_blocked_between(auth.uid(), p.author_id)
        and p.archived_at is null
        and (p.publish_at is null or p.publish_at <= now())
        and (
          exists (select 1 from post_participants pp
                  where pp.post_id = p.id and pp.user_id = auth.uid()
                    and pp.status in ('invited', 'accepted'))
          or case
            when p.group_id is not null then
              (p.group_status = 'published'
                 and (group_is_public(p.group_id) or group_role(p.group_id, auth.uid()) is not null))
              or (p.group_status = 'pending' and group_role(p.group_id, auth.uid()) in ('owner', 'admin'))
            else
              not exists (select 1 from post_exclusions e
                          where e.post_id = p.id and e.excluded_id = auth.uid())
              and (
                p.audience = 'public'
                or (p.audience = 'friends' and are_friends(auth.uid(), p.author_id))
                or (p.audience = 'list' and exists (
                      select 1 from friend_list_members m
                      where m.list_id = p.list_id and m.member_id = auth.uid()))
              )
          end
        )
      )
    );
$$;

create or replace function can_share_post(pid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select can_view_post(p) and (p.allow_share or p.author_id = auth.uid())
                   from posts p where p.id = pid), false);
$$;

-- حارس المنشورات: يحدد حالة منشور الجروب، ويمنع تغيير الحقول الحساسة من العميل
create or replace function posts_guard() returns trigger
language plpgsql set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    if new.group_id is not null then
      if group_role(new.group_id, new.author_id) is null then
        raise exception 'not a group member';
      end if;
      new.group_status := case
        when coalesce((select post_approval from groups where id = new.group_id), false)
             and group_role(new.group_id, new.author_id) not in ('owner', 'admin')
        then 'pending' else 'published' end;
    else
      new.group_status := 'published';
    end if;
  elsif current_user in ('authenticated', 'anon') then
    if new.group_id is distinct from old.group_id
       or new.group_status is distinct from old.group_status
       or new.shared_post_id is distinct from old.shared_post_id
       or new.author_id <> old.author_id then
      raise exception 'immutable columns';
    end if;
  end if;
  return new;
end $$;
drop trigger if exists posts_guard_trg on posts;
create trigger posts_guard_trg before insert or update on posts
  for each row execute function posts_guard();

drop policy if exists posts_insert on posts;
create policy posts_insert on posts for insert to authenticated
  with check (
    author_id = auth.uid()
    and (list_id is null or exists (
      select 1 from friend_lists l where l.id = list_id and l.owner_id = auth.uid()))
    and (shared_post_id is null or can_share_post(shared_post_id))
    and (group_id is null or is_group_member(group_id))
  );

create or replace function moderate_group_post(pid uuid, approve boolean) returns void
language plpgsql security definer set search_path = public as $$
declare gid uuid;
begin
  select group_id into gid from posts where id = pid and group_status = 'pending';
  if gid is null or not is_group_admin(gid) then raise exception 'forbidden'; end if;
  if approve then
    update posts set group_status = 'published' where id = pid;
  else
    delete from posts where id = pid;
  end if;
end $$;

-- المشرف يحذف أي منشور داخل جروبه
drop policy if exists posts_delete_group_admin on posts;
create policy posts_delete_group_admin on posts for delete to authenticated
  using (group_id is not null and is_group_admin(group_id));

-- ---------------------------------------------------------------------
-- (4) وسائط المنشورات الموسعة + اللينكات
-- ---------------------------------------------------------------------
alter table post_media add column if not exists thumb_path text;
alter table post_media add column if not exists title text;
alter table post_media add column if not exists mime text;
alter table post_media add column if not exists size_bytes bigint;
alter table post_media add column if not exists duration_ms integer;
alter table post_media add column if not exists width integer;
alter table post_media add column if not exists height integer;

drop policy if exists post_media_write on post_media;
create policy post_media_write on post_media for all to authenticated
  using (exists (select 1 from posts p where p.id = post_id and p.author_id = auth.uid()))
  with check (exists (
    select 1 from posts p
    where p.id = post_id and p.author_id = auth.uid()
      and storage_path like p.author_id::text || '/' || p.id::text || '/%'
      and (thumb_path is null or thumb_path like p.author_id::text || '/' || p.id::text || '/%')
  ));

create table if not exists post_links (
  id uuid primary key default gen_random_uuid(),
  post_id uuid not null references posts(id) on delete cascade,
  url text not null check (url ~* '^https?://' and char_length(url) <= 2000),
  title text check (char_length(title) <= 300),
  description text check (char_length(description) <= 600),
  created_at timestamptz not null default now()
);
create or replace function post_link_count(pid uuid) returns int
language sql stable security definer set search_path = public as $$
  select count(*)::int from post_links where post_id = pid;
$$;
alter table post_links enable row level security;
drop policy if exists post_links_select on post_links;
drop policy if exists post_links_write on post_links;
create policy post_links_select on post_links for select to authenticated
  using (exists (select 1 from posts p where p.id = post_id));
create policy post_links_write on post_links for all to authenticated
  using (exists (select 1 from posts p where p.id = post_id and p.author_id = auth.uid()))
  with check (exists (select 1 from posts p where p.id = post_id and p.author_id = auth.uid())
              and post_link_count(post_id) < 5);
revoke all on post_links from anon;

-- ---------------------------------------------------------------------
-- (5) الستوريات
-- ---------------------------------------------------------------------
create table if not exists stories (
  id uuid primary key default gen_random_uuid(),
  author_id uuid not null default auth.uid() references profiles(id) on delete cascade,
  kind text not null check (kind in ('text', 'image', 'video', 'audio', 'document', 'link')),
  body text not null default '' check (char_length(body) <= 1000),
  bg_color text check (bg_color ~ '^#[0-9a-fA-F]{6}$'),
  media_path text,
  thumb_path text,
  mime text,
  title text check (char_length(title) <= 200),
  duration_ms integer,
  size_bytes bigint,
  link_url text check (link_url ~* '^https?://' and char_length(link_url) <= 2000),
  link_title text check (char_length(link_title) <= 300),
  audience post_audience not null default 'friends',
  list_id uuid references friend_lists(id) on delete set null,
  allow_download boolean not null default true,
  allow_share boolean not null default true,
  highlight boolean not null default false,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '24 hours',
  check (audience <> 'list' or list_id is not null),
  check ((kind = 'text' and char_length(trim(body)) > 0)
         or (kind = 'link' and link_url is not null)
         or (kind not in ('text', 'link') and media_path is not null))
);
create index if not exists stories_author_created on stories (author_id, created_at desc);
create index if not exists stories_expires on stories (expires_at);

create or replace function story_owner(sid uuid) returns uuid
language sql stable security definer set search_path = public as $$
  select author_id from stories where id = sid;
$$;

create or replace function can_view_story(s stories) returns boolean
language sql stable security definer set search_path = public as $$
  select
    auth.uid() is not null
    and (
      s.author_id = auth.uid()
      or (
        not is_blocked_between(auth.uid(), s.author_id)
        and (s.expires_at > now() or s.highlight)
        and not exists (select 1 from story_hidden_from h
                        where h.owner_id = s.author_id and h.hidden_id = auth.uid())
        and (
          s.audience = 'public'
          or (s.audience = 'friends' and are_friends(auth.uid(), s.author_id))
          or (s.audience = 'list' and exists (
                select 1 from friend_list_members m
                where m.list_id = s.list_id and m.member_id = auth.uid()))
        )
      )
    );
$$;

create or replace function can_share_story(sid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select can_view_story(s) and (s.allow_share or s.author_id = auth.uid())
                   from stories s where s.id = sid), false);
$$;

create table if not exists story_views (
  story_id uuid not null references stories(id) on delete cascade,
  viewer_id uuid not null default auth.uid() references profiles(id) on delete cascade,
  viewed_at timestamptz not null default now(),
  primary key (story_id, viewer_id)
);
create table if not exists story_replies (
  id uuid primary key default gen_random_uuid(),
  story_id uuid not null references stories(id) on delete cascade,
  sender_id uuid not null default auth.uid() references profiles(id) on delete cascade,
  body text not null check (char_length(trim(body)) between 1 and 500),
  created_at timestamptz not null default now()
);
create table if not exists saved_stories (
  story_id uuid not null references stories(id) on delete cascade,
  user_id uuid not null default auth.uid() references profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (story_id, user_id)
);

alter table stories enable row level security;
alter table story_views enable row level security;
alter table story_replies enable row level security;
alter table saved_stories enable row level security;

drop policy if exists stories_select on stories;
drop policy if exists stories_insert on stories;
drop policy if exists stories_update on stories;
drop policy if exists stories_delete on stories;
create policy stories_select on stories for select to authenticated using (can_view_story(stories));
create policy stories_insert on stories for insert to authenticated
  with check (
    author_id = auth.uid()
    and expires_at <= now() + interval '24 hours 1 minute'
    and (list_id is null or exists (
      select 1 from friend_lists l where l.id = list_id and l.owner_id = auth.uid()))
    and (media_path is null or media_path like author_id::text || '/' || id::text || '/%')
    and (thumb_path is null or thumb_path like author_id::text || '/' || id::text || '/%')
  );
create policy stories_update on stories for update to authenticated
  using (author_id = auth.uid()) with check (author_id = auth.uid());
create policy stories_delete on stories for delete to authenticated using (author_id = auth.uid());

create or replace function stories_guard() returns trigger
language plpgsql set search_path = public as $$
begin
  if new.author_id <> old.author_id or new.created_at <> old.created_at
     or new.expires_at <> old.expires_at or new.kind <> old.kind
     or new.media_path is distinct from old.media_path then
    raise exception 'immutable columns';
  end if;
  return new;
end $$;
drop trigger if exists stories_guard_trg on stories;
create trigger stories_guard_trg before update on stories
  for each row execute function stories_guard();

drop policy if exists sv_select on story_views;
drop policy if exists sv_insert on story_views;
create policy sv_select on story_views for select to authenticated
  using (viewer_id = auth.uid() or story_owner(story_id) = auth.uid());
create policy sv_insert on story_views for insert to authenticated
  with check (viewer_id = auth.uid() and exists (select 1 from stories s where s.id = story_id));

drop policy if exists sr_select on story_replies;
drop policy if exists sr_insert on story_replies;
drop policy if exists sr_delete on story_replies;
create policy sr_select on story_replies for select to authenticated
  using (sender_id = auth.uid() or story_owner(story_id) = auth.uid());
create policy sr_insert on story_replies for insert to authenticated
  with check (sender_id = auth.uid() and story_owner(story_id) <> auth.uid()
              and exists (select 1 from stories s where s.id = story_id));
create policy sr_delete on story_replies for delete to authenticated
  using (sender_id = auth.uid() or story_owner(story_id) = auth.uid());

drop policy if exists ss_select on saved_stories;
drop policy if exists ss_insert on saved_stories;
drop policy if exists ss_delete on saved_stories;
create policy ss_select on saved_stories for select to authenticated
  using (user_id = auth.uid() and exists (select 1 from stories s where s.id = story_id));
create policy ss_insert on saved_stories for insert to authenticated
  with check (user_id = auth.uid() and exists (select 1 from stories s where s.id = story_id));
create policy ss_delete on saved_stories for delete to authenticated using (user_id = auth.uid());
revoke all on stories, story_views, story_replies, saved_stories from anon;

-- شريط الستوريات: من لديهم ستوريات نشطة أراها، وهل شاهدتها كلها
create or replace function story_tray()
returns table (author_id uuid, latest timestamptz, n int, all_seen boolean)
language sql stable security invoker set search_path = public as $$
  select s.author_id, max(s.created_at), count(*)::int,
         bool_and(exists (select 1 from story_views v where v.story_id = s.id and v.viewer_id = auth.uid()))
  from stories s
  where s.expires_at > now()
    and not exists (select 1 from user_mutes m
                    where m.user_id = auth.uid() and m.muted_id = s.author_id
                      and m.scope in ('stories', 'all') and (m.until is null or m.until > now()))
  group by s.author_id;
$$;

-- تنظيف الستوريات المنتهية (للخادم فقط، يُستدعى من مهمة مجدولة)
create or replace function purge_expired_stories() returns integer
language sql security definer set search_path = public as $$
  with d as (delete from stories where expires_at < now() - interval '7 days' and not highlight returning 1)
  select count(*)::int from d;
$$;
revoke all on function purge_expired_stories() from public, anon, authenticated;
grant execute on function purge_expired_stories() to service_role;

-- ---------------------------------------------------------------------
-- (6) التفاعلات (لايك، حب، ضحك، دهشة، حزن، غضب) على المنشورات والتعليقات والستوريات
-- ---------------------------------------------------------------------
create table if not exists reactions (
  target_type text not null check (target_type in ('post', 'comment', 'story')),
  target_id uuid not null,
  user_id uuid not null default auth.uid() references profiles(id) on delete cascade,
  kind text not null check (kind in ('like', 'love', 'haha', 'wow', 'sad', 'angry')),
  is_private boolean not null default false,
  created_at timestamptz not null default now(),
  primary key (target_type, target_id, user_id)
);
create index if not exists reactions_target on reactions (target_type, target_id);

create or replace function can_view_target(t text, tid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select case t
    when 'post' then coalesce((select can_view_post(p) from posts p where p.id = tid), false)
    when 'comment' then coalesce((select can_view_post(p) from comments c join posts p on p.id = c.post_id where c.id = tid), false)
    when 'story' then coalesce((select can_view_story(s) from stories s where s.id = tid), false)
    else false end;
$$;

alter table reactions enable row level security;
drop policy if exists reactions_select on reactions;
drop policy if exists reactions_insert on reactions;
drop policy if exists reactions_update on reactions;
drop policy if exists reactions_delete on reactions;
-- التفاعل الخاص لا يراه غير صاحبه (لكنه يُحتسب في العدّاد)
create policy reactions_select on reactions for select to authenticated
  using (user_id = auth.uid() or (not is_private and can_view_target(target_type, target_id)));
create policy reactions_insert on reactions for insert to authenticated
  with check (user_id = auth.uid() and can_view_target(target_type, target_id));
create policy reactions_update on reactions for update to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid() and can_view_target(target_type, target_id));
create policy reactions_delete on reactions for delete to authenticated using (user_id = auth.uid());
revoke all on reactions from anon;

-- نقل الإعجابات القديمة
insert into reactions (target_type, target_id, user_id, kind, created_at)
  select 'post', post_id, user_id, 'like', created_at from likes
  on conflict do nothing;

create or replace function reaction_counts(p_type text, p_ids uuid[])
returns table (target_id uuid, kind text, n int, mine boolean)
language sql stable security definer set search_path = public as $$
  select r.target_id, r.kind, count(*)::int, bool_or(r.user_id = auth.uid())
  from reactions r
  where r.target_type = p_type
    and r.target_id = any (p_ids[1:200])
    and can_view_target(p_type, r.target_id)
  group by r.target_id, r.kind;
$$;

-- ---------------------------------------------------------------------
-- (7) المنشن
-- ---------------------------------------------------------------------
create table if not exists mentions (
  id uuid primary key default gen_random_uuid(),
  source_type text not null check (source_type in ('post', 'comment', 'story')),
  source_id uuid not null,
  author_id uuid not null default auth.uid() references profiles(id) on delete cascade,
  mentioned_id uuid not null references profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  unique (source_type, source_id, mentioned_id)
);
create index if not exists mentions_mentioned on mentions (mentioned_id, created_at desc);
alter table mentions enable row level security;
drop policy if exists mentions_select on mentions;
create policy mentions_select on mentions for select to authenticated
  using (mentioned_id = auth.uid() or author_id = auth.uid());
revoke insert, update, delete on mentions from authenticated, anon;
revoke all on mentions from anon;

create or replace function add_mentions(p_type text, p_source uuid, p_usernames text[])
returns integer language plpgsql security definer set search_path = public as $$
declare owner uuid; u text; target uuid; allow text; n int := 0;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  owner := case p_type
    when 'post' then (select author_id from posts where id = p_source)
    when 'comment' then (select author_id from comments where id = p_source)
    when 'story' then (select author_id from stories where id = p_source)
  end;
  if owner is distinct from auth.uid() then raise exception 'not your content'; end if;
  foreach u in array coalesce(p_usernames[1:10], '{}') loop
    select id into target from profiles where username = u;
    continue when target is null or target = auth.uid();
    continue when is_blocked_between(auth.uid(), target);
    select coalesce((select who_can_mention from user_settings where user_id = target), 'everyone') into allow;
    continue when allow = 'nobody' or (allow = 'friends' and not are_friends(auth.uid(), target));
    insert into mentions (source_type, source_id, author_id, mentioned_id)
      values (p_type, p_source, auth.uid(), target) on conflict do nothing;
    n := n + 1;
  end loop;
  return n;
end $$;

-- ---------------------------------------------------------------------
-- (8) الرسائل: مشاركة منشور/ستوري، والتراجع عن الإرسال
-- ---------------------------------------------------------------------
alter table messages add column if not exists shared_post_id uuid references posts(id) on delete set null;
alter table messages add column if not exists shared_story_id uuid references stories(id) on delete set null;

drop policy if exists messages_insert on messages;
create policy messages_insert on messages for insert to authenticated
  with check (
    sender_id = auth.uid()
    and can_send(conversation_id)
    and (
      media_path is null
      or (media_kind is not null and media_path like conversation_id::text || '/%')
    )
    and (shared_post_id is null or can_share_post(shared_post_id))
    and (shared_story_id is null or can_share_story(shared_story_id))
    and (media_path is not null or shared_post_id is not null or shared_story_id is not null
         or char_length(trim(body)) > 0)
  );
drop policy if exists messages_delete on messages;
create policy messages_delete on messages for delete to authenticated using (sender_id = auth.uid());

-- ---------------------------------------------------------------------
-- (9) الخلاصة (نسخة محدثة): كتم مؤقت + منشورات الجروبات + استبعاد المجدولة
-- ---------------------------------------------------------------------
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
    select * from posts
    where (publish_at is null or publish_at <= now())
      and not exists (select 1 from user_mutes m
                      where m.user_id = auth.uid() and m.muted_id = posts.author_id
                        and m.scope in ('posts', 'all') and (m.until is null or m.until > now()))
    order by created_at desc limit 300
  ),
  scored as (
    select r.id, r.created_at, r.group_id,
      exists (select 1 from feed_topics t where t.user_id = auth.uid() and t.action = 'hide' and t.topic = any (r.topics)) as hidden,
      exists (select 1 from feed_topics t where t.user_id = auth.uid() and t.action = 'more' and t.topic = any (r.topics)) as t_more,
      exists (select 1 from feed_topics t where t.user_id = auth.uid() and t.action = 'less' and t.topic = any (r.topics)) as t_less,
      (r.author_id <> auth.uid() and are_friends(auth.uid(), r.author_id)) as is_friend,
      (r.audience = 'list' and r.group_id is null and r.author_id <> auth.uid()) as via_list
    from recent r
  )
  select s.id,
    case
      when p.mode = 'chronological' then 'chronological'
      when s.t_more then 'topic_more'
      when s.group_id is not null then 'group'
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

-- ---------------------------------------------------------------------
-- (10) الحساب والبيانات
-- ---------------------------------------------------------------------
create or replace function delete_my_account() returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  delete from auth.users where id = auth.uid();
end $$;
revoke all on function delete_my_account() from public, anon;
grant execute on function delete_my_account() to authenticated;

create or replace function export_my_data() returns jsonb
language sql stable security invoker set search_path = public as $$
  select export_my_memories() || jsonb_build_object(
    'profile', (select to_jsonb(p) - 'id' from profiles p where p.id = auth.uid()),
    'settings', (select to_jsonb(s) - 'user_id' from user_settings s where s.user_id = auth.uid()),
    'stories', coalesce((select jsonb_agg(jsonb_build_object(
        'id', s.id, 'kind', s.kind, 'body', s.body, 'created_at', s.created_at) order by s.created_at)
        from stories s where s.author_id = auth.uid()), '[]'::jsonb)
  );
$$;

-- ---------------------------------------------------------------------
-- (11) التخزين: أنواع وحدود الملفات الجديدة + حاوية الستوريات
-- ---------------------------------------------------------------------
insert into storage.buckets (id, name, public) values ('story-media', 'story-media', false)
  on conflict (id) do nothing;

update storage.buckets set file_size_limit = 50 * 1024 * 1024, allowed_mime_types = array[
  'image/jpeg','image/png','image/webp','image/gif','image/heic','image/avif',
  'video/mp4','video/quicktime','video/webm',
  'audio/mpeg','audio/mp4','audio/aac','audio/ogg','audio/wav','audio/x-wav','audio/flac','audio/x-flac',
  'audio/opus','audio/webm','audio/x-m4a','audio/m4a',
  'application/pdf','application/epub+zip'] where id in ('post-media', 'story-media');
update storage.buckets set file_size_limit = 25 * 1024 * 1024, allowed_mime_types = array[
  'image/jpeg','image/png','image/webp','video/mp4',
  'audio/mp4','audio/aac','audio/mpeg','audio/x-m4a','audio/m4a','audio/ogg','audio/wav','audio/x-wav',
  'audio/flac','audio/x-flac','audio/opus','audio/webm','application/pdf'] where id = 'chat-media';

create or replace function can_attach_to_story(sid text) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select s.author_id = auth.uid() from stories s where s.id::text = sid), false);
$$;
create or replace function can_read_story_media(sid text) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select can_view_story(s) from stories s where s.id::text = sid), false);
$$;

drop policy if exists storymedia_insert on storage.objects;
drop policy if exists storymedia_select on storage.objects;
drop policy if exists storymedia_delete on storage.objects;
create policy storymedia_insert on storage.objects for insert to authenticated
  with check (
    bucket_id = 'story-media'
    and array_length(storage.foldername(name), 1) = 2
    and (storage.foldername(name))[1] = auth.uid()::text
    and can_attach_to_story((storage.foldername(name))[2])
  );
create policy storymedia_select on storage.objects for select to authenticated
  using (bucket_id = 'story-media' and can_read_story_media((storage.foldername(name))[2]));
create policy storymedia_delete on storage.objects for delete to authenticated
  using (bucket_id = 'story-media' and (storage.foldername(name))[1] = auth.uid()::text);
