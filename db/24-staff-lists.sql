-- 24: แก้รายการ/ราคาในระบบได้โดยไม่ต้องแก้โค้ด
--   key 'lists' (เหตุผลตรวจไม่ผ่าน, เอกสารที่ต้องใช้)  -> ทุกตำแหน่งเพิ่ม/ลบได้
--   key 'rates' (เบี้ย พ.ร.บ.)                          -> หัวหน้าสาขา และเจ้าของร้าน
--   key อื่น เช่น 'main' (ตั้งค่าระบบ)                  -> เจ้าของร้านเท่านั้น (เหมือนเดิม)
-- รันซ้ำได้
drop policy if exists as_ins on public.app_settings;
drop policy if exists as_upd on public.app_settings;
create policy as_ins on public.app_settings for insert to authenticated
  with check (my_role() = 'owner'
    or (key = 'lists' and my_role() is not null)
    or (key = 'rates' and my_role() = 'head'));
create policy as_upd on public.app_settings for update to authenticated
  using (my_role() = 'owner'
    or (key = 'lists' and my_role() is not null)
    or (key = 'rates' and my_role() = 'head'))
  with check (my_role() = 'owner'
    or (key = 'lists' and my_role() is not null)
    or (key = 'rates' and my_role() = 'head'));
