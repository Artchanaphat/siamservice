-- SIAMSERVICE STAFF AVATARS V1
-- สำคัญ: ให้ Claude ตรวจสอบบน schema ของโปรเจ็กต์จริง + ทดลอง staging ก่อนรัน Production
-- เพิ่มเฉพาะ staff.avatar_path, private Storage bucket, policies และ RPC ใหม่
-- ไม่แก้ข้อมูลเดิม / ตารางบิล / สูตรภาษี / ฟังก์ชัน create_staff เดิม
-- SQL นี้ไม่อัปโหลดรูปให้ใครและไม่ลบรูปที่มีอยู่

BEGIN;

-- 1) ตรวจสอบว่าตารางและคอลัมน์เดิมตรงกับที่โค้ดสยามเซอร์วิสใช้
DO $preflight$
DECLARE
  t text;
BEGIN
  IF to_regclass('public.staff') IS NULL THEN
    RAISE EXCEPTION 'ไม่พบ public.staff — ยกเลิก Migration โดยไม่แก้ฐานข้อมูล';
  END IF;
  SELECT udt_name INTO t FROM information_schema.columns
  WHERE table_schema='public' AND table_name='staff' AND column_name='user_id';
  IF t IS DISTINCT FROM 'uuid' THEN
    RAISE EXCEPTION 'staff.user_id ไม่ใช่ UUID (ปัจจุบัน: %)', coalesce(t, 'ไม่มีคอลัมน์');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='staff' AND column_name='role')
    OR NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='staff' AND column_name='active') THEN
    RAISE EXCEPTION 'staff ไม่มี role หรือ active — กรุณาตรวจ schema ก่อน';
  END IF;
  IF to_regclass('storage.buckets') IS NULL OR to_regclass('storage.objects') IS NULL THEN
    RAISE EXCEPTION 'ไม่พบ Supabase Storage — กรุณาเปิดใช้งานและตรวจ schema';
  END IF;
  IF EXISTS (
    SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='staff'
    AND column_name='avatar_path' AND data_type <> 'text'
  ) THEN
    RAISE EXCEPTION 'staff.avatar_path มีอยู่แล้วแต่ไม่ใช่ TEXT — ห้ามเปลี่ยนชนิดอัตโนมัติ';
  END IF;
  IF EXISTS (SELECT 1 FROM storage.buckets WHERE id='staff-avatars' AND public IS TRUE) THEN
    RAISE EXCEPTION 'bucket staff-avatars มีอยู่แล้วเป็น PUBLIC — ให้ตรวจการตั้งค่าความเป็นส่วนตัวก่อน';
  END IF;
END;
$preflight$;

-- 2) เก็บเฉพาะ path ของไฟล์ ไม่บันทึก signed URL อายุสั้นลงฐานข้อมูล
ALTER TABLE public.staff ADD COLUMN IF NOT EXISTS avatar_path TEXT;
COMMENT ON COLUMN public.staff.avatar_path IS 'Private Supabase Storage key: staff-avatars/{user_id}/{file_uuid}.webp';

-- 3) Bucket รูปพนักงานแบบ PRIVATE, จำกัดไฟล์ที่อัปโหลดจริง
INSERT INTO storage.buckets (id,name,public,file_size_limit,allowed_mime_types)
VALUES ('staff-avatars','staff-avatars',FALSE,1048576,ARRAY['image/webp','image/png']::text[])
ON CONFLICT (id) DO NOTHING;

-- ป้องกันกรณี bucket เดิมมีค่าตั้งค่าไม่ปลอดภัย; ไม่แก้การตั้งค่าเดิมอัตโนมัติ
DO $bucketcheck$
DECLARE b record;
BEGIN
  SELECT public,file_size_limit,allowed_mime_types INTO b FROM storage.buckets WHERE id='staff-avatars';
  IF b.public IS DISTINCT FROM FALSE OR b.file_size_limit IS DISTINCT FROM 1048576
    OR b.allowed_mime_types IS DISTINCT FROM ARRAY['image/webp','image/png']::text[] THEN
    RAISE EXCEPTION 'Bucket staff-avatars มีการตั้งค่าไม่ตรงตามนโยบาย PRIVATE/1MB/WebP+PNG — ต้องตรวจสอบก่อน';
  END IF;
END;
$bucketcheck$;

-- 4) ฟังก์ชันตรวจสิทธิ์: เจ้าของรูปที่ใช้งานอยู่ หรือเจ้าของร้านที่ใช้งานอยู่
-- SECURITY DEFINER เฉพาะการตรวจสิทธิ์; ไม่ใช้ข้อมูล role ที่ส่งจากหน้าเว็บ
CREATE OR REPLACE FUNCTION public.siam_avatar_can_manage_v1(p_user uuid)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $f$
  SELECT auth.uid() IS NOT NULL AND p_user IS NOT NULL
   AND EXISTS (SELECT 1 FROM public.staff target
               WHERE target.user_id=p_user AND target.active IS TRUE)
   AND (
     p_user=auth.uid()
     OR EXISTS (SELECT 1 FROM public.staff admin
                WHERE admin.user_id=auth.uid() AND admin.active IS TRUE AND admin.role='owner')
   );
$f$;
REVOKE ALL ON FUNCTION public.siam_avatar_can_manage_v1(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.siam_avatar_can_manage_v1(uuid) TO authenticated;

-- 5) Storage policy; ชื่อไฟล์ต้องเป็น <staff-uuid>/<random-uuid>.webp หรือ .png เท่านั้น
-- หมายเหตุ: SQL RLS ใช้ signed URL; ไม่เปิด public read
DROP POLICY IF EXISTS siam_staff_avatar_select_v1 ON storage.objects;
CREATE POLICY siam_staff_avatar_select_v1 ON storage.objects
  FOR SELECT TO authenticated
  USING (
    bucket_id='staff-avatars'
    AND name ~ '^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}/[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}\.(webp|png)$'
    AND public.siam_avatar_can_manage_v1(
      CASE WHEN split_part(name,'/',1) ~ '^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$'
        THEN split_part(name,'/',1)::uuid ELSE NULL END
    )
  );
DROP POLICY IF EXISTS siam_staff_avatar_insert_v1 ON storage.objects;
CREATE POLICY siam_staff_avatar_insert_v1 ON storage.objects
  FOR INSERT TO authenticated
  WITH CHECK (
    bucket_id='staff-avatars'
    AND name ~ '^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}/[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}\.(webp|png)$'
    AND public.siam_avatar_can_manage_v1(
      CASE WHEN split_part(name,'/',1) ~ '^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$'
        THEN split_part(name,'/',1)::uuid ELSE NULL END
    )
  );
DROP POLICY IF EXISTS siam_staff_avatar_delete_v1 ON storage.objects;
CREATE POLICY siam_staff_avatar_delete_v1 ON storage.objects
  FOR DELETE TO authenticated
  USING (
    bucket_id='staff-avatars'
    AND name ~ '^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}/[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}\.(webp|png)$'
    AND public.siam_avatar_can_manage_v1(
      CASE WHEN split_part(name,'/',1) ~ '^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$'
        THEN split_part(name,'/',1)::uuid ELSE NULL END
    )
  );

-- 6) ฟังก์ชันสำหรับอัปเดต path รูปของตัวเอง / เจ้าของร้านเปลี่ยนของพนักงาน
-- เปลี่ยน avatar_path เท่านั้น ห้ามแก้ role, branch หรืออื่น ๆ ผ่าน RPC นี้
-- คืนค่า path เดิมให้หน้าเว็บลบรูปเก่าหลังอัปเดตสำเร็จ
CREATE OR REPLACE FUNCTION public.set_staff_avatar_v1(p_target_user uuid, p_avatar_path text)
RETURNS text
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $f$
DECLARE previous_path text;
BEGIN
  IF NOT public.siam_avatar_can_manage_v1(p_target_user) THEN
    RAISE EXCEPTION 'ไม่มีสิทธิ์แก้รูปพนักงานบัญชีนี้' USING ERRCODE='42501';
  END IF;
  IF p_avatar_path IS NOT NULL THEN
    IF p_avatar_path !~ '^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}/[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}\.(webp|png)$'
       OR split_part(p_avatar_path,'/',1) <> p_target_user::text THEN
      RAISE EXCEPTION 'รูปแบบ path รูปพนักงานไม่ถูกต้อง';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM storage.objects
      WHERE bucket_id='staff-avatars' AND name=p_avatar_path) THEN
      RAISE EXCEPTION 'ไม่พบไฟล์รูปใน staff-avatars; กรุณาอัปโหลดรูปก่อน';
    END IF;
  END IF;

  SELECT avatar_path INTO previous_path FROM public.staff
   WHERE user_id=p_target_user AND active IS TRUE FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ไม่พบบัญชีพนักงานที่ใช้งานอยู่';
  END IF;
  UPDATE public.staff SET avatar_path=p_avatar_path WHERE user_id=p_target_user;
  RETURN previous_path;
END;
$f$;
REVOKE ALL ON FUNCTION public.set_staff_avatar_v1(uuid,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.set_staff_avatar_v1(uuid,text) TO authenticated;

COMMIT;

-- หลังรัน: ตรวจสอบด้วยไฟล์ siamservice-staff-avatar-check.sql โดยยังไม่อัปโหลดภาพทันที
