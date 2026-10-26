-- =====================================================================
-- قالب ربط قاعدة البيانات بدالة send-push.
-- لا تشغّله كما هو: استبدل PROJECT_REF بمعرّف مشروعك، وCHANGE_ME بنفس القيمة
-- التي ضبطتها في السر PUSH_WEBHOOK_SECRET.
-- البديل الأسهل: Supabase Dashboard > Database > Webhooks > Create، لجدولي
-- messages وcalls (حدث Insert)، النوع Supabase Edge Functions، الدالة send-push،
-- وأضف ترويسة x-webhook-secret بنفس القيمة.
-- =====================================================================

create trigger push_on_message
after insert on public.messages
for each row execute function supabase_functions.http_request(
  'https://PROJECT_REF.supabase.co/functions/v1/send-push',
  'POST',
  '{"Content-Type":"application/json","x-webhook-secret":"CHANGE_ME"}',
  '{}',
  '5000'
);

create trigger push_on_call
after insert on public.calls
for each row execute function supabase_functions.http_request(
  'https://PROJECT_REF.supabase.co/functions/v1/send-push',
  'POST',
  '{"Content-Type":"application/json","x-webhook-secret":"CHANGE_ME"}',
  '{}',
  '5000'
);

create trigger push_on_comment
after insert on public.comments
for each row execute function supabase_functions.http_request(
  'https://PROJECT_REF.supabase.co/functions/v1/send-push',
  'POST',
  '{"Content-Type":"application/json","x-webhook-secret":"CHANGE_ME"}',
  '{}',
  '5000'
);

create trigger push_on_mention
after insert on public.mentions
for each row execute function supabase_functions.http_request(
  'https://PROJECT_REF.supabase.co/functions/v1/send-push',
  'POST',
  '{"Content-Type":"application/json","x-webhook-secret":"CHANGE_ME"}',
  '{}',
  '5000'
);

create trigger push_on_friend_request
after insert on public.friendships
for each row execute function supabase_functions.http_request(
  'https://PROJECT_REF.supabase.co/functions/v1/send-push',
  'POST',
  '{"Content-Type":"application/json","x-webhook-secret":"CHANGE_ME"}',
  '{}',
  '5000'
);
