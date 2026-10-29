-- 23-insp-result.sql : บันทึกผลตรวจสภาพ (ผ่าน/ไม่ผ่าน) ในหน้าบิล สำหรับบิลที่ไม่ได้ผ่านคิวตรวจ (รันหลัง 22, รันซ้ำได้)
-- วิธีรัน: Supabase › SQL Editor › New query › วางทั้งไฟล์ › Run  (เพิ่มคอลัมน์ใหม่ ไม่แก้ข้อมูลเดิม)
-- กติกา: พนักงานทุกคนในสาขาบันทึกผลครั้งแรกได้ · เปลี่ยน/ล้างผลที่บันทึกแล้ว เฉพาะเจ้าของร้าน/หัวหน้าสาขา · บิลที่ยกเลิกแล้วบันทึกไม่ได้
-- ทุกครั้งที่บันทึกจะเก็บประวัติใน bill_edits
-- เพิ่ม: กันเปิดบิลใหม่ที่ยอดรวม 0 บาท (ตรวจในฐานข้อมูล)
-- ย้อนกลับ: drop function if exists public.set_insp_result(bigint, text);
--          alter table public.bills drop column if exists insp_result, drop column if exists insp_at, drop column if exists insp_by;

alter table public.bills add column if not exists insp_result text check (insp_result in ('pass','fail'));
alter table public.bills add column if not exists insp_at timestamptz;
alter table public.bills add column if not exists insp_by text;

create or replace function public.set_insp_result(p_bill bigint, p_result text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare b bills; who text; r text := nullif(trim(coalesce(p_result,'')),'');
begin
  if my_role() is null then raise exception 'ไม่มีสิทธิ์ใช้งาน'; end if;
  if r is not null and r not in ('pass','fail') then raise exception 'ผลตรวจไม่ถูกต้อง'; end if;
  select * into b from bills where id = p_bill for update;
  if not found or not can_see_branch(b.branch_id) then raise exception 'ไม่พบบิล'; end if;
  if b.status = 'void' then raise exception 'บิลนี้ถูกยกเลิกแล้ว'; end if;
  if b.insp_result is not null and my_role() not in ('owner','head') then
    raise exception 'บันทึกผลตรวจไปแล้ว การเปลี่ยนผลทำได้เฉพาะเจ้าของร้าน/หัวหน้าสาขา';
  end if;
  select full_name into who from staff where user_id = auth.uid(); who := coalesce(who,'');
  update bills set insp_result = r, insp_at = case when r is null then null else now() end, insp_by = case when r is null then null else who end
   where id = p_bill;
  insert into bill_edits (bill_id, what, by_name) values (p_bill,
    case when r = 'pass' then 'บันทึกผลตรวจสภาพ: ผ่าน' when r = 'fail' then 'บันทึกผลตรวจสภาพ: ไม่ผ่าน' else 'ล้างผลตรวจสภาพ' end
    || case when b.insp_result is not null then ' (เดิม: ' || case b.insp_result when 'pass' then 'ผ่าน' else 'ไม่ผ่าน' end || ')' else '' end, who);
  return (select jsonb_build_object('insp_result', insp_result, 'insp_at', insp_at, 'insp_by', insp_by) from bills where id = p_bill);
end $$;
revoke all on function public.set_insp_result(bigint, text) from public, anon;
grant execute on function public.set_insp_result(bigint, text) to authenticated;

-- ---------- กันบิลยอด 0 บาท (บิลใหม่เท่านั้น บิลเดิมไม่ถูกแก้) ----------
create or replace function public.bill_total_guard() returns trigger
language plpgsql set search_path = public as $$
begin
  if coalesce(current_setting('siam.restoring', true), '') = '1' then return new; end if;  -- กู้คืนข้อมูลเดิมได้
  if coalesce(new.total, 0) <= 0 then raise exception 'ยอดรวมบิลเป็น 0 บาท กรุณาตรวจว่าใส่ราคาของแต่ละรายการครบแล้ว'; end if;
  return new;
end $$;
drop trigger if exists bills_total_guard on public.bills;
create trigger bills_total_guard before insert on public.bills for each row execute function public.bill_total_guard();
-- ย้อนกลับส่วนนี้: drop trigger if exists bills_total_guard on public.bills; drop function if exists public.bill_total_guard();

-- ตรวจผล: select column_name from information_schema.columns where table_name = 'bills' and column_name like 'insp_%';  -- ต้องได้ 3 แถว
