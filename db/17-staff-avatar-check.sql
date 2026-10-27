-- READ ONLY: ตรวจสอบ schema / bucket / policies / function หลังรัน
-- ห้ามใช้เป็นหลักฐานว่าทดสอบสิทธิ์ทุกบทบาทผ่านแล้ว; ต้องทดสอบด้วยบัญชีจริงแยกต่างหาก
SELECT column_name,data_type,is_nullable
FROM information_schema.columns
WHERE table_schema='public' AND table_name='staff' AND column_name='avatar_path';

SELECT id,public,file_size_limit,allowed_mime_types
FROM storage.buckets WHERE id='staff-avatars';

SELECT policyname,cmd,roles,qual,with_check
FROM pg_policies WHERE schemaname='storage' AND tablename='objects'
AND policyname IN ('siam_staff_avatar_select_v1','siam_staff_avatar_insert_v1','siam_staff_avatar_delete_v1')
ORDER BY policyname;

SELECT n.nspname,p.proname,pg_get_function_identity_arguments(p.oid) AS parameters,
       p.prosecdef AS security_definer
FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
WHERE n.nspname='public'
AND p.proname IN ('siam_avatar_can_manage_v1','set_staff_avatar_v1');

SELECT count(*) AS current_staff_with_avatar
FROM public.staff WHERE avatar_path IS NOT NULL;
