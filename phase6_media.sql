-- =====================================================================
-- المرحلة 6: الصور والفيديو والمقاطع الصوتية (شغّله بعد phase5_security_fixes.sql)
-- مسارات الملفات:
--   avatars:     {user_id}/avatar_*.jpg                (الحاوية عامة للقراءة)
--   post-media:  {author_id}/{post_id}/{file}           (خاصة، قراءتها حسب صلاحية المنشور)
--   chat-media:  {conversation_id}/{file}              (خاصة، لأعضاء المحادثة فقط)
-- =====================================================================

-- حدود الحجم والأنواع على مستوى الحاوية (يفرضها Storage نفسه)
update storage.buckets set file_size_limit = 5 * 1024 * 1024,
  allowed_mime_types = array['image/jpeg','image/png','image/webp'] where id = 'avatars';
update storage.buckets set file_size_limit = 50 * 1024 * 1024,
  allowed_mime_types = array['image/jpeg','image/png','image/webp','image/gif','video/mp4','video/quicktime']
  where id = 'post-media';
update storage.buckets set file_size_limit = 25 * 1024 * 1024,
  allowed_mime_types = array['image/jpeg','image/png','image/webp','audio/mp4','audio/aac','audio/mpeg','audio/x-m4a','audio/m4a','audio/ogg']
  where id = 'chat-media';

-- ---------- دوال مساعدة (تعمل بصلاحية المالك لتتجاوز RLS داخلها) ----------
-- هل يحق لي إرفاق ملف بهذا المنشور؟ (حاليًا: صاحبه فقط)
create or replace function can_attach_to_post(pid text) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select p.author_id = auth.uid() from posts p where p.id::text = pid), false);
$$;

create or replace function can_upload_chat(conv text) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select can_send(c.id) from conversations c where c.id::text = conv), false);
$$;

create or replace function can_read_chat_media(conv text) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select is_member(c.id) from conversations c where c.id::text = conv), false);
$$;

create or replace function can_read_post_media(pid text) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select can_view_post(p) from posts p where p.id::text = pid), false);
$$;

-- ---------- سياسات التخزين ----------
-- صور الملف الشخصي: كل مستخدم في مجلده فقط
drop policy if exists avatars_select on storage.objects;
drop policy if exists avatars_insert on storage.objects;
drop policy if exists avatars_update on storage.objects;
drop policy if exists avatars_delete on storage.objects;
-- الحاوية عامة أصلًا؛ سياسة القراءة ضرورية ليعمل الرفع (insert ... returning) والاستبدال
create policy avatars_select on storage.objects for select to authenticated
  using (bucket_id = 'avatars');
create policy avatars_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);
create policy avatars_update on storage.objects for update to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text)
  with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);
create policy avatars_delete on storage.objects for delete to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);

-- وسائط المنشورات
drop policy if exists postmedia_insert on storage.objects;
drop policy if exists postmedia_select on storage.objects;
drop policy if exists postmedia_delete on storage.objects;
create policy postmedia_insert on storage.objects for insert to authenticated
  with check (
    bucket_id = 'post-media'
    and array_length(storage.foldername(name), 1) = 2
    and (storage.foldername(name))[1] = auth.uid()::text
    and can_attach_to_post((storage.foldername(name))[2])
  );
create policy postmedia_select on storage.objects for select to authenticated
  using (bucket_id = 'post-media' and can_read_post_media((storage.foldername(name))[2]));
create policy postmedia_delete on storage.objects for delete to authenticated
  using (bucket_id = 'post-media' and (storage.foldername(name))[1] = auth.uid()::text);

-- وسائط المحادثات
drop policy if exists chatmedia_insert on storage.objects;
drop policy if exists chatmedia_select on storage.objects;
create policy chatmedia_insert on storage.objects for insert to authenticated
  with check (
    bucket_id = 'chat-media'
    and array_length(storage.foldername(name), 1) = 1
    and can_upload_chat((storage.foldername(name))[1])
  );
create policy chatmedia_select on storage.objects for select to authenticated
  using (bucket_id = 'chat-media' and can_read_chat_media((storage.foldername(name))[1]));

-- ---------- ربط الجداول بمسارات الملفات ----------
-- سجل وسائط المنشور: لصاحب المنشور فقط، والمسار لا بد أن يقع تحت {author}/{post}/
drop policy if exists post_media_write on post_media;
create policy post_media_write on post_media for all to authenticated
  using (exists (select 1 from posts p where p.id = post_id and p.author_id = auth.uid()))
  with check (exists (
    select 1 from posts p
    where p.id = post_id and p.author_id = auth.uid()
      and storage_path like p.author_id::text || '/' || p.id::text || '/%'
  ));

-- رسالة بوسائط: المسار تحت مجلد المحادثة نفسها والنوع محدد
drop policy if exists messages_insert on messages;
create policy messages_insert on messages for insert to authenticated
  with check (
    sender_id = auth.uid()
    and can_send(conversation_id)
    and (
      media_path is null
      or (media_kind is not null and media_path like conversation_id::text || '/%')
    )
    and (media_path is not null or char_length(trim(body)) > 0)
  );
