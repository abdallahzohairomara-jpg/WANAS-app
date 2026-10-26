-- =====================================================================
-- المرحلة 4: المكالمات (شغّله بعد phase2_messages.sql)
-- جدول المكالمات للإشعار الداخلي بالتطبيق والانضمام. الصوت والصورة نفسهما
-- يمرّان عبر مزود RTC (LiveKit أو Agora) وليس عبر قاعدة البيانات.
-- =====================================================================

create table calls (
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references conversations(id) on delete cascade,
  caller_id uuid not null default auth.uid() references profiles(id) on delete cascade,
  provider text not null check (provider in ('livekit', 'agora')),
  is_video boolean not null default false,
  status text not null default 'open' check (status in ('open', 'ended')),
  created_at timestamptz not null default now()
);
create index calls_conv_created on calls (conversation_id, created_at desc);

alter table calls enable row level security;

create policy calls_select on calls for select to authenticated
  using (is_member(conversation_id));

create policy calls_insert on calls for insert to authenticated
  with check (caller_id = auth.uid() and can_send(conversation_id));

-- أي عضو يستطيع إنهاء المكالمة (عند خروج آخر مشارك)، ولا يغيّر شيئًا آخر
revoke update on calls from authenticated;
grant update (status) on calls to authenticated;
create policy calls_end on calls for update to authenticated
  using (is_member(conversation_id))
  with check (is_member(conversation_id) and status = 'ended');

alter publication supabase_realtime add table calls;
