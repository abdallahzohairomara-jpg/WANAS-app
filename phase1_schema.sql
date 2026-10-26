-- =====================================================================
-- المرحلة 1: الحسابات، المنشورات، الصداقة، الرسائل، الخصوصية، الحظر، الإبلاغ
-- شغّله في Supabase > SQL Editor على مشروع تجريبي أولًا.
-- الصلاحيات (RLS) مفروضة في قاعدة البيانات نفسها وليس في الواجهة فقط.
-- =====================================================================

create extension if not exists "pgcrypto";

-- ---------- الأنواع ----------
create type post_audience as enum ('public', 'friends', 'list', 'only_me');
create type friend_status as enum ('pending', 'accepted');
create type media_kind as enum ('image', 'video', 'audio');
create type report_target as enum ('user', 'post', 'comment', 'message');

-- ---------- الملفات الشخصية ----------
create table profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  username text unique not null check (username ~ '^[a-zA-Z0-9_]{3,30}$'),
  display_name text not null default '',
  bio text not null default '' check (char_length(bio) <= 300),
  avatar_url text,
  lang text not null default 'ar' check (lang in ('ar','en')),
  who_can_message text not null default 'everyone'
    check (who_can_message in ('everyone','friends','nobody')),
  created_at timestamptz not null default now()
);

-- إنشاء ملف شخصي تلقائيًا عند التسجيل
create or replace function handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into profiles (id, username, display_name)
  values (
    new.id,
    'user_' || substr(replace(new.id::text, '-', ''), 1, 10),
    coalesce(new.raw_user_meta_data->>'display_name', '')
  );
  return new;
end $$;

create trigger on_auth_user_created
after insert on auth.users
for each row execute function handle_new_user();

-- ---------- الصداقة والمتابعة والحظر ----------
create table friendships (
  requester_id uuid not null references profiles(id) on delete cascade,
  addressee_id uuid not null references profiles(id) on delete cascade,
  status friend_status not null default 'pending',
  created_at timestamptz not null default now(),
  primary key (requester_id, addressee_id),
  check (requester_id <> addressee_id)
);

create table follows (
  follower_id uuid not null references profiles(id) on delete cascade,
  followee_id uuid not null references profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (follower_id, followee_id),
  check (follower_id <> followee_id)
);

create table blocks (
  blocker_id uuid not null references profiles(id) on delete cascade,
  blocked_id uuid not null references profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (blocker_id, blocked_id),
  check (blocker_id <> blocked_id)
);

-- ---------- قوائم الأصدقاء المخصصة (العائلة، المقربين...) ----------
create table friend_lists (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references profiles(id) on delete cascade,
  name text not null check (char_length(name) between 1 and 40)
);

create table friend_list_members (
  list_id uuid not null references friend_lists(id) on delete cascade,
  member_id uuid not null references profiles(id) on delete cascade,
  primary key (list_id, member_id)
);

-- ---------- دوال مساعدة ----------
create or replace function are_friends(a uuid, b uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from friendships
    where status = 'accepted'
      and ((requester_id = a and addressee_id = b)
        or (requester_id = b and addressee_id = a))
  );
$$;

create or replace function is_blocked_between(a uuid, b uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from blocks
    where (blocker_id = a and blocked_id = b)
       or (blocker_id = b and blocked_id = a)
  );
$$;

-- ---------- المنشورات ----------
create table posts (
  id uuid primary key default gen_random_uuid(),
  author_id uuid not null default auth.uid() references profiles(id) on delete cascade,
  body text not null default '' check (char_length(body) <= 5000),
  audience post_audience not null default 'friends',
  list_id uuid references friend_lists(id) on delete set null,
  created_at timestamptz not null default now(),
  check (audience <> 'list' or list_id is not null)
);
create index posts_author_created on posts (author_id, created_at desc);
create index posts_created on posts (created_at desc);

create table post_media (
  id uuid primary key default gen_random_uuid(),
  post_id uuid not null references posts(id) on delete cascade,
  storage_path text not null,
  kind media_kind not null
);

-- استثناء أشخاص محددين من رؤية منشور
create table post_exclusions (
  post_id uuid not null references posts(id) on delete cascade,
  excluded_id uuid not null references profiles(id) on delete cascade,
  primary key (post_id, excluded_id)
);

-- القرار الوحيد لمن يرى المنشور (يُستخدم في كل السياسات)
create or replace function can_view_post(p posts) returns boolean
language sql stable security definer set search_path = public as $$
  select
    auth.uid() is not null
    and (
      p.author_id = auth.uid()
      or (
        not is_blocked_between(auth.uid(), p.author_id)
        and not exists (
          select 1 from post_exclusions e
          where e.post_id = p.id and e.excluded_id = auth.uid()
        )
        and (
          p.audience = 'public'
          or (p.audience = 'friends' and are_friends(auth.uid(), p.author_id))
          or (p.audience = 'list' and exists (
                select 1 from friend_list_members m
                where m.list_id = p.list_id and m.member_id = auth.uid()))
        )
      )
    );
$$;

create table likes (
  post_id uuid not null references posts(id) on delete cascade,
  user_id uuid not null default auth.uid() references profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (post_id, user_id)
);

create table comments (
  id uuid primary key default gen_random_uuid(),
  post_id uuid not null references posts(id) on delete cascade,
  author_id uuid not null default auth.uid() references profiles(id) on delete cascade,
  parent_id uuid references comments(id) on delete cascade,
  body text not null check (char_length(body) between 1 and 2000),
  created_at timestamptz not null default now()
);
create index comments_post on comments (post_id, created_at);

create table saved_posts (
  post_id uuid not null references posts(id) on delete cascade,
  user_id uuid not null default auth.uid() references profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (post_id, user_id)
);

-- ---------- الرسائل ----------
create table conversations (
  id uuid primary key default gen_random_uuid(),
  is_group boolean not null default false,
  title text,
  created_by uuid not null default auth.uid() references profiles(id),
  created_at timestamptz not null default now()
);

create table conversation_members (
  conversation_id uuid not null references conversations(id) on delete cascade,
  user_id uuid not null references profiles(id) on delete cascade,
  is_admin boolean not null default false,
  joined_at timestamptz not null default now(),
  primary key (conversation_id, user_id)
);

create or replace function is_member(conv uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from conversation_members
    where conversation_id = conv and user_id = auth.uid()
  );
$$;

create table messages (
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references conversations(id) on delete cascade,
  sender_id uuid not null default auth.uid() references profiles(id) on delete cascade,
  body text not null default '' check (char_length(body) <= 4000),
  media_path text,
  media_kind media_kind,
  created_at timestamptz not null default now()
);
create index messages_conv_created on messages (conversation_id, created_at desc);

-- ---------- البلاغات ----------
create table reports (
  id uuid primary key default gen_random_uuid(),
  reporter_id uuid not null default auth.uid() references profiles(id) on delete cascade,
  target_type report_target not null,
  target_id uuid not null,
  reason text not null check (char_length(reason) between 3 and 1000),
  created_at timestamptz not null default now()
);

-- =====================================================================
-- سياسات الأمان (RLS)
-- =====================================================================
alter table profiles             enable row level security;
alter table friendships          enable row level security;
alter table follows              enable row level security;
alter table blocks               enable row level security;
alter table friend_lists         enable row level security;
alter table friend_list_members  enable row level security;
alter table posts                enable row level security;
alter table post_media           enable row level security;
alter table post_exclusions      enable row level security;
alter table likes                enable row level security;
alter table comments             enable row level security;
alter table saved_posts          enable row level security;
alter table conversations        enable row level security;
alter table conversation_members enable row level security;
alter table messages             enable row level security;
alter table reports              enable row level security;

-- الملفات الشخصية: يراها المسجلون ما لم يكن بينهم حظر
create policy profiles_select on profiles for select to authenticated
  using (id = auth.uid() or not is_blocked_between(auth.uid(), id));
create policy profiles_update on profiles for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());

-- الصداقة
create policy friendships_select on friendships for select to authenticated
  using (requester_id = auth.uid() or addressee_id = auth.uid());
create policy friendships_insert on friendships for insert to authenticated
  with check (requester_id = auth.uid() and status = 'pending'
              and not is_blocked_between(requester_id, addressee_id));
create policy friendships_accept on friendships for update to authenticated
  using (addressee_id = auth.uid()) with check (addressee_id = auth.uid());
create policy friendships_delete on friendships for delete to authenticated
  using (requester_id = auth.uid() or addressee_id = auth.uid());

-- المتابعة
create policy follows_select on follows for select to authenticated
  using (follower_id = auth.uid() or followee_id = auth.uid());
create policy follows_insert on follows for insert to authenticated
  with check (follower_id = auth.uid() and not is_blocked_between(follower_id, followee_id));
create policy follows_delete on follows for delete to authenticated
  using (follower_id = auth.uid());

-- الحظر: خاص بصاحبه فقط
create policy blocks_all on blocks for all to authenticated
  using (blocker_id = auth.uid()) with check (blocker_id = auth.uid());

-- القوائم المخصصة: لصاحبها فقط (العضو يتحقق منها عبر الدالة الآمنة)
create policy lists_all on friend_lists for all to authenticated
  using (owner_id = auth.uid()) with check (owner_id = auth.uid());
create policy list_members_all on friend_list_members for all to authenticated
  using (exists (select 1 from friend_lists l where l.id = list_id and l.owner_id = auth.uid()))
  with check (exists (select 1 from friend_lists l where l.id = list_id and l.owner_id = auth.uid()));

-- المنشورات
create policy posts_select on posts for select to authenticated
  using (can_view_post(posts));
create policy posts_insert on posts for insert to authenticated
  with check (author_id = auth.uid());
create policy posts_update on posts for update to authenticated
  using (author_id = auth.uid()) with check (author_id = auth.uid());
create policy posts_delete on posts for delete to authenticated
  using (author_id = auth.uid());

create policy post_media_select on post_media for select to authenticated
  using (exists (select 1 from posts p where p.id = post_id and can_view_post(p)));
create policy post_media_write on post_media for all to authenticated
  using (exists (select 1 from posts p where p.id = post_id and p.author_id = auth.uid()))
  with check (exists (select 1 from posts p where p.id = post_id and p.author_id = auth.uid()));

create policy exclusions_owner on post_exclusions for all to authenticated
  using (exists (select 1 from posts p where p.id = post_id and p.author_id = auth.uid()))
  with check (exists (select 1 from posts p where p.id = post_id and p.author_id = auth.uid()));

-- الإعجابات والتعليقات والحفظ: فقط على منشورات يحق لك رؤيتها
create policy likes_select on likes for select to authenticated
  using (exists (select 1 from posts p where p.id = post_id and can_view_post(p)));
create policy likes_insert on likes for insert to authenticated
  with check (user_id = auth.uid()
              and exists (select 1 from posts p where p.id = post_id and can_view_post(p)));
create policy likes_delete on likes for delete to authenticated
  using (user_id = auth.uid());

create policy comments_select on comments for select to authenticated
  using (exists (select 1 from posts p where p.id = post_id and can_view_post(p)));
create policy comments_insert on comments for insert to authenticated
  with check (author_id = auth.uid()
              and exists (select 1 from posts p where p.id = post_id and can_view_post(p)));
create policy comments_delete on comments for delete to authenticated
  using (author_id = auth.uid()
         or exists (select 1 from posts p where p.id = post_id and p.author_id = auth.uid()));

create policy saved_select on saved_posts for select to authenticated
  using (user_id = auth.uid());
create policy saved_insert on saved_posts for insert to authenticated
  with check (user_id = auth.uid()
              and exists (select 1 from posts p where p.id = post_id and can_view_post(p)));
create policy saved_delete on saved_posts for delete to authenticated
  using (user_id = auth.uid());

-- المحادثات: الأعضاء فقط
create policy conv_select on conversations for select to authenticated
  using (is_member(id) or created_by = auth.uid());
create policy conv_insert on conversations for insert to authenticated
  with check (created_by = auth.uid());

create policy members_select on conversation_members for select to authenticated
  using (is_member(conversation_id));
-- إضافة الأعضاء: المنشئ يضيف نفسه والآخرين، ولا يُضاف محظور أو من أغلق الرسائل
create policy members_insert on conversation_members for insert to authenticated
  with check (
    exists (select 1 from conversations c
            where c.id = conversation_id and c.created_by = auth.uid())
    and (user_id = auth.uid() or (
          not is_blocked_between(auth.uid(), user_id)
          and exists (select 1 from profiles pr where pr.id = user_id and (
                pr.who_can_message = 'everyone'
                or (pr.who_can_message = 'friends' and are_friends(auth.uid(), user_id))))))
  );
create policy members_delete on conversation_members for delete to authenticated
  using (user_id = auth.uid());

create policy messages_select on messages for select to authenticated
  using (is_member(conversation_id));
create policy messages_insert on messages for insert to authenticated
  with check (sender_id = auth.uid() and is_member(conversation_id));

-- البلاغات: يُنشئها المبلّغ ويراها هو فقط (المراجعة من لوحة الإدارة بمفتاح الخدمة)
create policy reports_insert on reports for insert to authenticated
  with check (reporter_id = auth.uid());
create policy reports_select on reports for select to authenticated
  using (reporter_id = auth.uid());

-- =====================================================================
-- التخزين: ثلاث حاويات خاصة (avatars, post-media, chat-media)
-- ملاحظة: سياسات الوصول للملفات تُضاف بعد تثبيت مسارات الرفع في التطبيق.
-- =====================================================================
insert into storage.buckets (id, name, public) values
  ('avatars', 'avatars', true),
  ('post-media', 'post-media', false),
  ('chat-media', 'chat-media', false)
on conflict (id) do nothing;
