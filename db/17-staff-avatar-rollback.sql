-- Optional rollback: ให้ Claude ตรวจและเจ้าของร้านตัดสินใจก่อนใช้
-- ขั้นแรกต้องย้อน index.html เป็นเวอร์ชันก่อนเพิ่มรูป แล้วจึงรัน SQL นี้
-- คง staff.avatar_path และไฟล์ใน Storage ไว้ เพื่อไม่ให้รูปสูญหาย
BEGIN;
DROP POLICY IF EXISTS siam_staff_avatar_select_v1 ON storage.objects;
DROP POLICY IF EXISTS siam_staff_avatar_insert_v1 ON storage.objects;
DROP POLICY IF EXISTS siam_staff_avatar_delete_v1 ON storage.objects;
DROP FUNCTION IF EXISTS public.set_staff_avatar_v1(uuid,text);
DROP FUNCTION IF EXISTS public.siam_avatar_can_manage_v1(uuid);
COMMIT;
-- ไม่ DROP staff.avatar_path / staff-avatars: เก็บข้อมูลไว้สำหรับนำกลับมาใช้
