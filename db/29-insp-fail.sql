-- 29-insp-fail.sql : ตรวจไม่ผ่าน ต้องระบุสาเหตุ + วันนัดตรวจซ้ำ + หมายเหตุ (รันหลัง 28, รันซ้ำได้)
-- วิธีรัน: Supabase › SQL Editor › New query › วางทั้งไฟล์ › Run  (เพิ่มคอลัมน์ใหม่ ไม่แก้ข้อมูลเดิม)
-- บิล: insp_reason (สาเหตุ), insp_retest (วันนัดตรวจซ้ำ), insp_note (หมายเหตุ) · คิวตรวจ: retest_date
-- ตารางเดิม ระบบสำรองข้อมูลเก็บทุกคอลัมน์อยู่แล้ว ไม่ต้องแก้ส่วนสำรอง
-- ย้อนกลับ: รัน 23-insp-result.sql อีกครั้ง แล้ว
--   drop function if exists public.set_insp_result(bigint, text, text, date, text);
--   alter table public.bills drop column if exists insp_reason, drop column if exists insp_retest, drop column if exists insp_note;
--   alter table public.insp_queue drop column if exists retest_date;

alter table public.bills add column if not exists insp_reason text;
alter table public.bills add column if not exists insp_retest date;
alter table public.bills add column if not exists insp_note text;
alter table public.insp_queue add column if not exists retest_date date;

-- แทนที่ฟังก์ชันเดิม (2 ช่อง) ด้วยฟังก์ชันที่รับสาเหตุ/วันนัด/หมายเหตุ · แอปเวอร์ชันเก่าที่ส่งแค่ 2 ช่องยังเรียกได้
drop function if exists public.set_insp_result(bigint, text);
create or replace function public.set_insp_result(p_bill bigint, p_result text, p_reason text default null, p_retest date default null, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare b bills; who text; r text := nullif(trim(coalesce(p_result,'')),'');
  rs text := nullif(trim(coalesce(p_reason,'')),''); nt text := nullif(trim(coalesce(p_note,'')),'');
begin
  if my_role() is null then raise exception 'ไม่มีสิทธิ์ใช้งาน'; end if;
  if r is not null and r not in ('pass','fail') then raise exception 'ผลตรวจไม่ถูกต้อง'; end if;
  if r = 'fail' and rs is null and p_reason is not null then raise exception 'กรุณาระบุสาเหตุที่ตรวจไม่ผ่าน'; end if;
  select * into b from bills where id = p_bill for update;
  if not found or not can_see_branch(b.branch_id) then raise exception 'ไม่พบบิล'; end if;
  if b.status = 'void' then raise exception 'บิลนี้ถูกยกเลิกแล้ว'; end if;
  if b.insp_result is not null and my_role() not in ('owner','head') then
    raise exception 'บันทึกผลตรวจไปแล้ว การเปลี่ยนผลทำได้เฉพาะเจ้าของร้าน/หัวหน้าสาขา';
  end if;
  select full_name into who from staff where user_id = auth.uid(); who := coalesce(who,'');
  update bills set insp_result = r, insp_at = case when r is null then null else now() end, insp_by = case when r is null then null else who end,
    insp_reason = case when r = 'fail' then rs end, insp_retest = case when r = 'fail' then p_retest end, insp_note = case when r = 'fail' then nt end
   where id = p_bill;
  insert into bill_edits (bill_id, what, by_name) values (p_bill,
    case when r = 'pass' then 'บันทึกผลตรวจสภาพ: ผ่าน'
         when r = 'fail' then 'บันทึกผลตรวจสภาพ: ไม่ผ่าน' || coalesce(' · สาเหตุ: ' || rs, '')
              || coalesce(' · นัดตรวจซ้ำ ' || to_char(p_retest, 'DD/MM/') || (extract(year from p_retest)::int + 543)::text, '') || coalesce(' · ' || nt, '')
         else 'ล้างผลตรวจสภาพ' end
    || case when b.insp_result is not null then ' (เดิม: ' || case b.insp_result when 'pass' then 'ผ่าน' else 'ไม่ผ่าน' end || ')' else '' end, who);
  return (select jsonb_build_object('insp_result', insp_result, 'insp_at', insp_at, 'insp_by', insp_by,
    'insp_reason', insp_reason, 'insp_retest', insp_retest, 'insp_note', insp_note) from bills where id = p_bill);
end $$;
revoke all on function public.set_insp_result(bigint, text, text, date, text) from public, anon;
grant execute on function public.set_insp_result(bigint, text, text, date, text) to authenticated;

-- ตรวจผล: select column_name from information_schema.columns where table_name in ('bills','insp_queue') and column_name in ('insp_reason','insp_retest','insp_note','retest_date');  -- ต้องได้ 4 แถว
