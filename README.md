# تطبيق التواصل — المرحلتان 1 و2 (الحسابات + المنشورات + الرسائل + المكالمات + الإشعارات + الهوية)

## التشغيل
1. ثبّت Flutter (3.27+).
2. داخل مجلد المشروع: `flutter create . --platforms=android` (يولّد مجلد android دون المساس بـ lib).
3. افتح `lib/config.dart` وضع رابط مشروع Supabase ومفتاح anon.
4. شغّل بالترتيب في Supabase > SQL Editor: `phase1_schema.sql` ثم `phase2_messages.sql` ثم `phase3_calls.sql` ثم `phase4_push.sql` ثم **`phase5_security_fixes.sql`** (إصلاحات أمنية، لا تتخطاها) ثم `phase6_media.sql` (الصور والفيديو والصوت وحدود الحجم) ثم `phase7_features.sql` (مركز التحكم في الخلاصة، الذكريات والألبومات، المنشورات المشتركة) ثم **`phase8_social.sql`** (الستوريات، التفاعلات، الإشارات، الجروبات، الإعدادات، الكتم، الجدولة والأرشفة، حذف الحساب وتصدير البيانات). كلها قابلة للتشغيل أكثر من مرة.
5. في Supabase > Authentication > Providers فعّل Email.
6. `flutter pub get` ثم `flutter run`.

## سياسة رفع صور الملف الشخصي (شغّلها في SQL Editor)
```sql
create policy avatars_upload on storage.objects for insert to authenticated
  with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);
create policy avatars_update on storage.objects for update to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);
```
وفي `android/app/src/main/AndroidManifest.xml` لا يلزم إذن إضافي لاختيار الصور من المعرض.

## الموجود
- تسجيل حساب، دخول، استعادة كلمة المرور بالبريد
- ملف شخصي: الاسم، اسم المستخدم، النبذة، الصورة، اللغة (عربي/إنجليزي مع RTL تلقائي)، من يستطيع مراسلتي
- AuthGate يحوّل بين الدخول والشاشة الرئيسية

- الخلاصة الزمنية، منشور نصي بجمهور (عام / أصدقاء / أنا فقط)، إعجاب، تعليقات، حفظ، حذف منشورك، إبلاغ عن منشور
- شاشة الأشخاص: بحث باسم المستخدم، طلب صداقة، قبول الطلبات، حظر (يلغي الصداقة)
- ما يظهر في الخلاصة تحدده قاعدة البيانات (RLS) وليس التطبيق

- محادثات فردية ومجموعات (من قائمة أصدقائك)، رسائل نصية فورية (Realtime)، فحص الحظر وإعداد "من يراسلني" في قاعدة البيانات

- مكالمات صوتية وفيديو فردية وجماعية، بمزودين قابلين للتبديل: **LiveKit** و**Agora** (واجهة موحدة `CallEngine`، وإضافة مزود ثالث تحتاج ملفًا واحدًا)
- إشعار مكالمة واردة داخل التطبيق، وشريط "مكالمة جارية، انضم" داخل المحادثة

## تفعيل المكالمات (كل مزود اختياري؛ فعّل الذي تريد تجربته فقط)
1. أنشئ حسابًا عند المزود بنفسك (LiveKit Cloud خطته المجانية بدون بطاقة، Agora تحتاج Project مع App Certificate).
2. ثبّت Supabase CLI وسجّل الدخول واربط المشروع: `supabase link`.
3. اضبط الأسرار على الخادم فقط:
```
supabase secrets set LIVEKIT_URL=wss://xxx.livekit.cloud LIVEKIT_API_KEY=... LIVEKIT_API_SECRET=...
supabase secrets set AGORA_APP_ID=... AGORA_APP_CERTIFICATE=...
```
4. انشر الدالة: `supabase functions deploy call-token`
5. في `android/app/src/main/AndroidManifest.xml` أضف داخل `<manifest>`:
```xml
<uses-permission android:name="android.permission.INTERNET"/>
<uses-permission android:name="android.permission.RECORD_AUDIO"/>
<uses-permission android:name="android.permission.CAMERA"/>
<uses-permission android:name="android.permission.MODIFY_AUDIO_SETTINGS"/>
<uses-permission android:name="android.permission.ACCESS_NETWORK_STATE"/>
<uses-permission android:name="android.permission.CHANGE_NETWORK_STATE"/>
<uses-permission android:name="android.permission.BLUETOOTH_CONNECT"/>
<uses-feature android:name="android.hardware.camera"/>
<uses-feature android:name="android.hardware.camera.autofocus"/>
```
وفي `android/app/build.gradle` اجعل `minSdkVersion` لا يقل عن 24.
6. اختيار المزود عند بدء المكالمة: أيقونة الهوائي في شريط المحادثة (الافتراضي من `lib/config.dart`).

- إشعارات خارجية (FCM) للرسائل والمكالمات والتطبيق مغلق؛ الضغط على الإشعار يفتح المحادثة أو المكالمة. لا إشعار لمن بينك وبينه حظر.

## تفعيل الإشعارات (Firebase مجاني للاستخدام الأساسي)
1. في Firebase Console أنشئ مشروعًا، وأضف تطبيق Android بنفس `applicationId` الموجود في `android/app/build.gradle`.
2. نزّل `google-services.json` وضعه في `android/app/`.
3. فعّل إضافة Google Services في Gradle (حسب قالب مشروعك):
   - إن كان عندك `android/settings.gradle` فيه كتلة plugins: أضف فيها `id "com.google.gms.google-services" version "4.4.2" apply false`، وفي `android/app/build.gradle` أضف `id "com.google.gms.google-services"` ضمن plugins.
   - القالب القديم: `classpath 'com.google.gms:google-services:4.4.2'` في `android/build.gradle` و`apply plugin: 'com.google.gms.google-services'` في ملف التطبيق.
4. في `AndroidManifest.xml` أضف: `<uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>`
5. انسخ `android_setup/MainActivity.kt` فوق ملف MainActivity (وعدّل سطر package) لإنشاء قناتي الإشعارات.
6. في Firebase > Project settings > Service accounts > Generate new private key. احتفظ بالملف خارج المشروع ولا ترفعه على GitHub أبدًا.
7. على الخادم:
```
supabase secrets set PUSH_WEBHOOK_SECRET=<نص عشوائي طويل من اختيارك>
supabase secrets set FCM_SERVICE_ACCOUNT="$(cat service-account.json)"
supabase functions deploy send-push --no-verify-jwt
```
8. اربط الجدولين بالدالة: من Dashboard > Database > Webhooks (جدول messages وجدول calls، حدث Insert، ترويسة `x-webhook-secret` بنفس السر)، أو عدّل وشغّل `phase4b_webhooks_TEMPLATE.sql`.
9. إن تعارضت نسخ الحزم عند `flutter pub get` جرّب: `flutter pub upgrade --major-versions`.

## الهوية والاسم
الاسم المختار: "ونس / Wanas" (راجع فحص التوفر في brand/BRAND.md قبل النشر). التفاصيل والبدائل والألوان والخطوط في `brand/BRAND.md`.
- بعد `flutter pub get`: `flutter pub run flutter_launcher_icons` لتوليد أيقونة التطبيق.
- غيّر `android:label` في `AndroidManifest.xml` لاسم التطبيق.

## اختبار الصلاحيات
`cd tests && npm install && npm test` يشغّل 168 اختبارًا على Postgres حقيقي (هجمات من غريب/محظور/غير مسجل).
أعد تشغيله بعد أي تعديل على ملفات SQL.

## للتجربة
أنشئ حسابين (جهازين أو محاكي + هاتف)، أضف أحدهما الآخر، انشر بجمهور "أصدقاء" وتأكد أن الحساب الثالث لا يراه.

## غير موجود بعد
- التسجيل برقم الهاتف (يحتاج مزود SMS وله تكلفة، ينتظر موافقتك)
- صور وفيديو داخل المنشورات (يحتاج سياسات تخزين خاصة)، قوائم الأصدقاء المخصصة والاستثناءات في الواجهة، المتابعة، البحث في المنشورات، الإشعارات
- صور ومقاطع صوتية في الرسائل، إضافة/إزالة أعضاء المجموعة، إشعارات الرسائل
- شاشة اتصال بملء الشاشة فوق شاشة القفل (الحالي: إشعار منبثق برنين). وإشعارات iOS غير مضبوطة
- إعدادات إشعارات داخل التطبيق (كتم محادثة، إخفاء نص الرسالة من الإشعار). حاليًا نص الرسالة يظهر في الإشعار
- تجديد التصريح للمكالمات الأطول من ساعتين، ومشاركة الشاشة، وتسجيل المكالمات
- التكلفة: الفيديو الجماعي هو الأغلى؛ راقب الاستهلاك في لوحة المزود قبل أي إطلاق عام
- ما اتجرّب على جهاز أو محاكي بعد


## الوسائط والميزات المميزة (المرحلة 6 و7)
- **الوسائط**: صور حتى 50MB للمنشورات (وفيديو mp4/mov) و25MB للمحادثات (صور وصوت). المسارات تفرضها سياسات التخزين: `post-media/{author}/{post}/` و`chat-media/{conversation}/`. العرض بروابط موقّعة مدتها ساعة. أذونات أندرويد: الميكروفون (موجود) والصور عبر منتقي النظام.
- **التحكم في الخلاصة**: ترتيب زمني أو مخصص بقواعد صريحة (أولوية الأصدقاء/القوائم المقربة، موضوعات أكثر/أقل/إخفاء)، وزر "لماذا أرى هذا؟" وإعادة الضبط. الموضوعات هي وسوم يضعها كاتب المنشور (حتى 5). ليست ذكاءً اصطناعيًا.
- **الذكريات**: خط زمني بحثي، "في مثل هذا اليوم" (تنبيه اختياري)، ألبومات خاصة، وتصدير JSON إلى الحافظة. ما فقدتَ صلاحية رؤيته يختفي من الألبوم تلقائيًا.
- **المنشورات المشتركة**: المالك يدعو أصدقاءه (حتى 10)، ولا يظهر اسم المدعو ولا مساهمته إلا بعد قبوله، ويمكنه الانسحاب (تُحذف مساهماته)، ولا يستطيع تعديل المنشور أو إعداداته.
- حدود معروفة: لا إشعار دفع للدعوات بعد (يمكن إضافة webhook على `post_participants`)، والألبومات خاصة ولا تُشارك.


## الإصدار 3: ما الجديد وما حدوده بصدق

الجديد: ستوريات 24 ساعة (نص/صورة/فيديو/صوت/كتاب/رابط) مع المشاهدين والردود والحفظ والتمييز، تفاعلات متعددة (حتى الخاصة) على المنشورات والتعليقات والستوريات، إشارات @، مشاركة المنشورات والستوريات (على صفحتك أو في محادثة أو خارجيًا)، جروبات عامة/خاصة بإدارة وموافقة منشورات ودعوات، إعدادات كاملة (حساب، خصوصية، إشعارات، وسائط، مظهر، وقت الاستخدام، بياناتك)، كتم مؤقت، وضع التركيز، جدولة وأرشفة المنشورات، حذف الرسالة بضغطة مطولة.

الحدود (للأمانة):
- الكود لم يُترجم ولم يُشغَّل بعد؛ المتوقع ظهور أخطاء بناء أولى نصلحها معًا عبر GitHub Actions. اختبارات قاعدة البيانات (313) ناجحة، وهي لا تغني عن تجربة التطبيق.
- منع التنزيل/المشاركة على مستوى الواجهة فقط؛ لا يمنع تصوير الشاشة.
- حد الملف 50 ميجا (الخطة المجانية)، ويُرفع لاحقًا من إعدادات Supabase.
- حذف ملفات الستوريات المنتهية يحتاج مهمة مجدولة تستدعي `purge_expired_stories()` وتحذف الملفات؛ حتى ذلك الحين تختفي من التطبيق لكن الملفات تبقى.
- ساعات الهدوء في الإشعارات تُحسب بتوقيت UTC حاليًا.
- لا إشعارات لدعوات الجروبات والمشاركين بعد.
- دالة `link-preview` تُنشر بـ `supabase functions deploy link-preview`؛ وإشعارات التعليقات والإشارات والطلبات تحتاج إضافة الـ triggers الجديدة في `phase4b_webhooks_TEMPLATE.sql`.
- المصادقة الثنائية (2FA) غير مضافة بعد.
