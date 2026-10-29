-- 19-close-pending-guard.sql : กันพนักงานปิดยอดตอนยังมีเงินโอนรอตรวจ (เช็คในฐานข้อมูล ให้ตรงกับหน้าเว็บ v80+)
-- รันหลัง 13–15 (รันซ้ำได้) เพิ่ม trigger บนตาราง cash_closes เท่านั้น ไม่แก้ข้อมูลเดิม
-- กติกา: บันทึก/แก้ปิดยอดของวันใด ถ้าสาขานั้นยังมีเงินโอน (kind='pay') ที่ยังไม่ตรวจและไม่ถูกปฏิเสธ ซึ่งรับในวันนั้น (เวลาไทย)
--        พนักงาน (staff) บันทึกไม่ได้ ส่วนเจ้าของร้าน (owner) และหัวหน้าสาขา (head) บันทึกได้ตามปกติ
--        งานเบื้องหลังที่ไม่มีผู้ใช้ล็อกอิน (auth.uid() ว่าง เช่น service role / cron) ไม่ถูกกัน
-- ย้อนกลับ: drop trigger if exists cash_closes_pending_guard on public.cash_closes;
--          drop function if exists public.cash_close_pending_guard();

create or replace function public.cash_close_pending_guard()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  t0 timestamptz := (new.close_date::timestamp at time zone 'Asia/Bangkok');
  t1 timestamptz := ((new.close_date + 1)::timestamp at time zone 'Asia/Bangkok');
  n int; s numeric;
begin
  if auth.uid() is null or coalesce(my_role(), '') in ('owner', 'head') then
    return new;
  end if;
  select count(*), coalesce(sum(amount), 0) into n, s
    from payments
   where branch_id = new.branch_id and paid_at >= t0 and paid_at < t1
     and kind = 'pay' and not verified and not coalesce(rejected, false);
  if n > 0 then
    raise exception 'ยังมีเงินโอนรอตรวจสอบ % รายการ (% บาท) กรุณาตรวจสอบเงินโอนก่อน หรือให้หัวหน้า/เจ้าของร้านเป็นผู้ปิดยอด',
      n, to_char(s, 'FM999,999,990.00') using errcode = 'P0001';
  end if;
  return new;
end $$;

revoke all on function public.cash_close_pending_guard() from public, anon, authenticated;

drop trigger if exists cash_closes_pending_guard on public.cash_closes;
create trigger cash_closes_pending_guard before insert or update on public.cash_closes
  for each row execute function public.cash_close_pending_guard();

-- ---------- ตรวจผล (อ่านอย่างเดียว) ----------
-- select tgname from pg_trigger where tgrelid = 'public.cash_closes'::regclass and not tgisinternal;
-- ต้องเห็น cash_closes_pending_guard
