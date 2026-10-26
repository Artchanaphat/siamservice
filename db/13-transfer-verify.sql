-- 13-transfer-verify.sql : ยืนยันเงินโอนภายหลัง (หลังพิมพ์ใบเสร็จ)
-- เงินโอนที่บันทึกตอนเปิดบิลจะเป็น "รอตรวจสอบ" จนกว่าพนักงานจะกดยืนยันว่าเงินเข้าบัญชีร้านแล้ว
-- รายการรับเงินเดิมทั้งหมดถือว่าตรวจสอบแล้ว (ค่าเริ่มต้น true) จึงไม่กระทบยอดเก่า
-- รันซ้ำได้

alter table public.payments add column if not exists verified    boolean not null default true;
alter table public.payments add column if not exists verified_by text;
alter table public.payments add column if not exists verified_at timestamptz;

-- พนักงานทุกตำแหน่งในสาขานั้นกดยืนยันได้ (แก้ได้เฉพาะสถานะการตรวจสอบ ไม่แตะยอดเงิน)
create or replace function public.verify_payment(p_id bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r payments; who text;
begin
  if my_role() is null then raise exception 'ไม่มีสิทธิ์ใช้งาน'; end if;
  select * into r from payments where id = p_id;
  if not found then raise exception 'ไม่พบรายการรับเงิน'; end if;
  if not can_see_branch(r.branch_id) then raise exception 'ไม่มีสิทธิ์ยืนยันรายการของสาขาอื่น'; end if;
  if r.verified then
    return jsonb_build_object('id', r.id, 'verified', true, 'verified_by', r.verified_by, 'verified_at', r.verified_at);
  end if;
  select full_name into who from staff where user_id = auth.uid();
  update payments set verified = true, verified_by = coalesce(who, ''), verified_at = now() where id = p_id
    returning * into r;
  return jsonb_build_object('id', r.id, 'verified', true, 'verified_by', r.verified_by, 'verified_at', r.verified_at);
end $$;
revoke all on function public.verify_payment(bigint) from public, anon;
grant execute on function public.verify_payment(bigint) to authenticated;
