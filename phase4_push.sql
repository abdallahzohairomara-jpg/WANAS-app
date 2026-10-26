-- =====================================================================
-- المرحلة 5: الإشعارات (شغّله بعد phase3_calls.sql)
-- جدول رموز الأجهزة. إرسال الإشعارات نفسه يتم من Edge Function باسم send-push.
-- =====================================================================

create table device_tokens (
  token text primary key,
  user_id uuid not null references profiles(id) on delete cascade,
  platform text not null default 'android',
  updated_at timestamptz not null default now()
);
create index device_tokens_user on device_tokens (user_id);

alter table device_tokens enable row level security;

-- المستخدم يرى ويحذف رموز أجهزته فقط. التسجيل عبر الدالة أدناه فقط.
create policy tokens_select on device_tokens for select to authenticated
  using (user_id = auth.uid());
create policy tokens_delete on device_tokens for delete to authenticated
  using (user_id = auth.uid());

-- تسجيل الرمز: إن كان الجهاز مسجلًا لمستخدم سابق ينتقل للمستخدم الحالي
create or replace function register_device_token(t text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if t is null or char_length(t) not between 20 and 4096 then
    raise exception 'invalid token';
  end if;
  insert into device_tokens (token, user_id) values (t, auth.uid())
  on conflict (token) do update set user_id = auth.uid(), updated_at = now();
end $$;

revoke execute on function register_device_token(text) from public, anon;
grant execute on function register_device_token(text) to authenticated;
