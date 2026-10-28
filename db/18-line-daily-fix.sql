-- 18-line-daily-fix.sql : แก้สรุปประจำวันที่ส่งเข้า LINE ให้ตัวเลขตรงกับหน้า "ปิดยอด" ในแอป (v75+)
-- รันหลัง 17 (รันซ้ำได้) แทนที่เฉพาะฟังก์ชัน daily_summary_text เท่านั้น
-- ไม่แตะ send_line_daily, cron, ตารางใดๆ และไม่เขียนข้อมูลลงฐานข้อมูล
--
-- สิ่งที่แก้ (เทียบกับ 06-line-daily.sql)
--  1) เงินรับ: นับเฉพาะรายการที่ตรวจแล้ว (verified) ไม่นับเงินโอนรอตรวจ ไม่นับรายการที่ถูกปฏิเสธ
--  2) คืนเงิน: แถว kind='refund' เก็บจำนวนเป็นบวกในตาราง จึงต้องหักออก (ของเดิมนับบวกเพิ่มเข้าไป)
--  3) จัดประเภทวิธีชำระด้วยกฎเดียวกับแอป (payKind): มี "สด" = เงินสด, มี "โอน" = เงินโอน, อื่นๆ = อื่นๆ/บัตร
--  4) ยอดบิล = total - refund_total (ตรงกับ monthly_stats และหน้ารายได้)
--  5) ยอดค้างชำระ: หักคืนเงิน และนับเฉพาะเงินที่ตรวจแล้ว
--  6) เพิ่มบรรทัด "เงินโอนรอตรวจ" ของวันนั้น และที่ค้างตรวจจากวันก่อน
--  7) เพิ่มคำเตือน "ยอดเปลี่ยนหลังปิดยอด" เมื่อยอดตอนนี้ไม่ตรงกับที่บันทึกปิดยอดไว้
--  8) นับพนักงานที่ต้องปิดยอดจากรายการที่นับในยอดเท่านั้น (ตรงกับตารางในหน้าปิดยอด)
--
-- หมายเหตุ: รายการลงวันตาม paid_at (เวลาไทย) เหมือนหน้าปิดยอด รายการเงินโอนที่ตรวจทีหลังจึงลงวันที่รับเงินเดิม
-- ย้อนกลับ: รันส่วน create or replace function daily_summary_text จาก 06-line-daily.sql ซ้ำ

create or replace function public.daily_summary_text(p_day date default (now() at time zone 'Asia/Bangkok')::date)
returns text language plpgsql stable security definer set search_path = public as $$
declare
  t0 timestamptz := (p_day::timestamp at time zone 'Asia/Bangkok');
  t1 timestamptz := ((p_day + 1)::timestamp at time zone 'Asia/Bangkok');
  b record; txt text; n_bill int; s_bill numeric; s_cash numeric; s_tr numeric; s_other numeric; s_debt numeric;
  n_car int; n_moto int;
  n_close int; n_staff int; d_close numeric; s_close numeric; n_late int; n_pass int; n_fail int; n_tax int; n_prb int;
  n_ref int; s_ref numeric; n_pend int; s_pend numeric; n_pend_all int; s_pend_all numeric;
begin
  txt := '📊 สรุปประจำวัน ' || to_char(p_day, 'DD/MM/') || (extract(year from p_day)::int + 543);
  for b in select id, name from branches where active order by id loop
    select count(*), coalesce(sum(total - refund_total), 0) into n_bill, s_bill
      from bills where branch_id = b.id and status <> 'void' and bill_at >= t0 and bill_at < t1;
    -- รถเข้าวันนี้ (นับทะเบียนไม่ซ้ำ จากบิล และคิวตรวจที่ยังไม่ได้เปิดบิล)
    select count(*) filter (where not moto), count(*) filter (where moto) into n_car, n_moto from (
      select coalesce(snapshot ->> 'plate', '') || '|' || coalesce(snapshot ->> 'prov', '') k,
             bool_or(coalesce(snapshot ->> 'type', '') like '%จักรยานยนต์%') moto
        from bills where branch_id = b.id and status <> 'void' and bill_at >= t0 and bill_at < t1 group by 1
      union all
      select plate || '|' || province, bool_or(car_type in ('รย.12', 'รย.17'))
        from insp_queue q where branch_id = b.id and created_at >= t0 and created_at < t1 and not billed
         and not exists (select 1 from bills x where x.branch_id = b.id and x.bill_at >= t0 and x.bill_at < t1
                          and x.snapshot ->> 'plate' = q.plate and x.snapshot ->> 'prov' = q.province)
       group by 1) v;
    -- เงินรับของวัน: เฉพาะที่ตรวจแล้ว (คืนเงินสร้างเป็นตรวจแล้วเสมอ) หักคืนเงิน ไม่นับที่ถูกปฏิเสธ
    select coalesce(sum(a) filter (where m ~ 'สด'), 0),
           coalesce(sum(a) filter (where m !~ 'สด' and m ~ 'โอน'), 0),
           coalesce(sum(a) filter (where m !~ 'สด' and m !~ 'โอน'), 0)
      into s_cash, s_tr, s_other
      from (select coalesce(method, '') m, case when kind = 'refund' then -amount else amount end a
              from payments
             where branch_id = b.id and paid_at >= t0 and paid_at < t1
               and not coalesce(rejected, false) and (verified or kind = 'refund')) x;
    select count(*), coalesce(sum(amount), 0) into n_ref, s_ref
      from payments where branch_id = b.id and paid_at >= t0 and paid_at < t1 and kind = 'refund';
    -- เงินโอนรอตรวจ: ของวันนี้ และที่ค้างทั้งหมด
    select count(*), coalesce(sum(amount), 0) into n_pend, s_pend
      from payments where branch_id = b.id and paid_at >= t0 and paid_at < t1
       and kind = 'pay' and not verified and not coalesce(rejected, false);
    select count(*), coalesce(sum(amount), 0) into n_pend_all, s_pend_all
      from payments where branch_id = b.id and kind = 'pay' and not verified and not coalesce(rejected, false);
    -- ยอดค้างของทุกบิลในสาขา (ย้อนหลัง 400 วัน) หลังหักคืนเงิน นับเฉพาะเงินที่ตรวจแล้ว
    select coalesce(sum(greatest(bi.total - bi.refund_total - coalesce(p.paid, 0), 0)), 0) into s_debt
      from bills bi
      left join (select bill_id,
                        sum(case when kind = 'refund' then -amount
                                 when verified and not coalesce(rejected, false) then amount else 0 end) paid
                   from payments group by bill_id) p on p.bill_id = bi.id
     where bi.branch_id = b.id and bi.status <> 'void' and bi.bill_at >= now() - interval '400 days';
    -- ปิดยอด: พนักงานที่มีรายการนับในยอดวันนี้ เทียบกับที่บันทึกปิดยอดแล้ว
    select count(distinct by_name) into n_staff
      from payments where branch_id = b.id and paid_at >= t0 and paid_at < t1
       and not coalesce(rejected, false) and (verified or kind = 'refund');
    select count(*), coalesce(sum(counted_cash - cash) filter (where counted_cash is not null), 0),
           coalesce(sum(coalesce(cash, 0) + coalesce(transfer, 0) + coalesce(card, 0) + coalesce(other, 0)), 0)
      into n_close, d_close, s_close from cash_closes where branch_id = b.id and close_date = p_day;
    -- คิวตรวจ
    select count(*) filter (where status = 'pass'), count(*) filter (where status = 'fail') into n_pass, n_fail
      from insp_queue where branch_id = b.id and created_at >= t0 and created_at < t1;
    -- งานขนส่งเกินกำหนด (รอยื่น 2 วัน / ยื่นแล้ว 7 วัน / ได้ป้าย 14 วัน)
    select count(*) into n_late
      from bills bi left join dlt_jobs j on j.bill_id = bi.id
     where bi.branch_id = b.id and bi.status <> 'void' and bi.bill_at >= now() - interval '400 days'
       and exists (select 1 from jsonb_array_elements(bi.items) it
                    where it ->> 0 in ('ค่าภาษีรถ','ค่าฝากต่อภาษี','ค่าโอน','ค่าย้าย','ค่าโอนย้าย','ค่าเปลี่ยนสี','ค่าตรวจสภาพโอน','ค่าเรื่อง'))
       and coalesce(j.status, 'received') <> 'done'
       and now() - case coalesce(j.status, 'received')
                     when 'received'  then bi.bill_at
                     when 'submitted' then coalesce(j.submitted_at, bi.bill_at)
                     else coalesce(j.plate_at, bi.bill_at) end
           > case coalesce(j.status, 'received') when 'received' then interval '2 days'
                                                 when 'submitted' then interval '7 days' else interval '14 days' end;

    txt := txt || E'\n\n🏢 ' || b.name
      || E'\n• รถเข้าวันนี้ ' || (n_car + n_moto) || ' คัน (รถยนต์ ' || n_car || ' / มอเตอร์ไซค์ ' || n_moto || ')'
      || E'\n• บิลวันนี้ ' || n_bill || ' ใบ ยอด ' || to_char(s_bill, 'FM999,999,990.00') || ' บาท'
      || E'\n• รับเงิน (ตรวจแล้ว): สด ' || to_char(s_cash, 'FM999,999,990.00') || ' / โอน ' || to_char(s_tr, 'FM999,999,990.00')
      || case when s_other <> 0 then ' / อื่นๆ ' || to_char(s_other, 'FM999,999,990.00') else '' end
      || E'\n• รวมรับ ' || to_char(s_cash + s_tr + s_other, 'FM999,999,990.00') || ' บาท'
      || case when n_ref > 0 then ' (หักคืนเงินแล้ว ' || to_char(s_ref, 'FM999,999,990.00') || ' บาท ' || n_ref || ' รายการ)' else '' end
      || case when n_pend > 0 then E'\n• ⏳ เงินโอนรอตรวจ ' || n_pend || ' รายการ ' || to_char(s_pend, 'FM999,999,990.00') || ' บาท (ยังไม่นับในยอดรับ)' else '' end
      || case when n_pend_all > n_pend then E'\n• ⏳ เงินโอนค้างตรวจจากวันก่อน ' || (n_pend_all - n_pend) || ' รายการ ' || to_char(s_pend_all - s_pend, 'FM999,999,990.00') || ' บาท' else '' end
      || E'\n• ยอดค้างชำระทั้งหมด ' || to_char(s_debt, 'FM999,999,990.00') || ' บาท'
      || E'\n• ปิดยอด: ' || case when n_staff = 0 and n_close = 0 then 'ไม่มีการรับเงิน'
                               when n_close = 0 then '⚠️ ยังไม่ปิดยอด'
                               when n_close < n_staff then '⚠️ ปิดแล้ว ' || n_close || '/' || n_staff || ' คน'
                               else 'ปิดแล้ว' end
      || case when n_close > 0 and d_close < 0 then ' (เงินสดขาด ' || to_char(-d_close, 'FM999,999,990.00') || ')'
              when n_close > 0 and d_close > 0 then ' (เงินสดเกิน ' || to_char(d_close, 'FM999,999,990.00') || ')'
              when n_close > 0 then ' (เงินสดตรง)' else '' end
      || case when n_close > 0 and abs(s_close - (s_cash + s_tr + s_other)) > 0.004
              then E'\n• ⚠️ ยอดเปลี่ยนหลังปิดยอด (ตอนปิด ' || to_char(s_close, 'FM999,999,990.00') || ' / ตอนนี้ ' || to_char(s_cash + s_tr + s_other, 'FM999,999,990.00') || ') กรุณาตรวจในหน้าปิดยอด' else '' end
      || case when n_pass + n_fail > 0 then E'\n• ตรวจสภาพ: ผ่าน ' || n_pass || ' / ไม่ผ่าน ' || n_fail else '' end
      || case when n_late > 0 then E'\n• ⚠️ งานขนส่งเกินกำหนด ' || n_late || ' งาน' else '' end;
  end loop;

  select count(*) filter (where tax_exp between p_day + 1 and p_day + 7),
         count(*) filter (where prb_exp between p_day + 1 and p_day + 7)
    into n_tax, n_prb from vehicles;
  txt := txt || E'\n\n📅 อีก 7 วันข้างหน้า: ภาษีหมด ' || n_tax || ' คัน · พ.ร.บ.หมด ' || n_prb || ' คัน';
  return txt;
end $$;

revoke all on function public.daily_summary_text(date) from public, anon, authenticated;

-- ---------- ตรวจผล (อ่านอย่างเดียว) รันใน SQL Editor แทนที่วันที่ด้วยวันที่มีทั้งเงินโอนรอตรวจ/คืนเงิน ----------
-- select public.daily_summary_text('2026-10-28');
-- แล้วเทียบ "รับเงินจริงทั้งวัน" ในหน้า ปิดยอด วันเดียวกัน ต้องเท่ากับ "รวมรับ" (รวมรายสาขาแล้ว)
