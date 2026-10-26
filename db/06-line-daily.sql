-- ตรอ.สยามเซอร์วิส : ส่งสรุปประจำวันเข้า LINE เจ้าของร้าน ทุกวัน 20:00 น.
-- รันครั้งเดียว หลัง 05-features.sql (รันซ้ำได้)
-- ก่อนใช้งาน ต้องเก็บ Channel access token และ User ID ของ LINE ไว้ใน Vault (ดูท้ายไฟล์)

create extension if not exists pg_net;
create extension if not exists pg_cron;

-- ---------- ข้อความสรุปของวันที่ระบุ (เวลาไทย) ----------
create or replace function public.daily_summary_text(p_day date default (now() at time zone 'Asia/Bangkok')::date)
returns text language plpgsql stable security definer set search_path = public as $$
declare
  t0 timestamptz := (p_day::timestamp at time zone 'Asia/Bangkok');
  t1 timestamptz := ((p_day + 1)::timestamp at time zone 'Asia/Bangkok');
  b record; txt text; n_bill int; s_bill numeric; s_cash numeric; s_tr numeric; s_other numeric; s_debt numeric;
  n_car int; n_moto int;
  n_close int; n_staff int; d_close numeric; n_late int; n_pass int; n_fail int; n_tax int; n_prb int;
  f text;
begin
  txt := '📊 สรุปประจำวัน ' || to_char(p_day, 'DD/MM/') || (extract(year from p_day)::int + 543);
  for b in select id, name from branches where active order by id loop
    select count(*), coalesce(sum(total), 0) into n_bill, s_bill
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
    select coalesce(sum(amount) filter (where method = 'เงินสด'), 0),
           coalesce(sum(amount) filter (where method = 'โอน'), 0),
           coalesce(sum(amount) filter (where method not in ('เงินสด', 'โอน')), 0)
      into s_cash, s_tr, s_other
      from payments where branch_id = b.id and paid_at >= t0 and paid_at < t1;
    -- ยอดค้างของทุกบิลในสาขา (ย้อนหลัง 400 วัน)
    select coalesce(sum(greatest(bi.total - coalesce(p.paid, 0), 0)), 0) into s_debt
      from bills bi left join (select bill_id, sum(amount) paid from payments group by bill_id) p on p.bill_id = bi.id
     where bi.branch_id = b.id and bi.status <> 'void' and bi.bill_at >= now() - interval '400 days';
    -- ปิดยอด: พนักงานที่รับเงินวันนี้ เทียบกับที่บันทึกปิดยอดแล้ว
    select count(distinct by_name) into n_staff from payments where branch_id = b.id and paid_at >= t0 and paid_at < t1;
    select count(*), coalesce(sum(counted_cash - cash) filter (where counted_cash is not null), 0)
      into n_close, d_close from cash_closes where branch_id = b.id and close_date = p_day;
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
      || E'\n• รับเงิน: สด ' || to_char(s_cash, 'FM999,999,990.00') || ' / โอน ' || to_char(s_tr, 'FM999,999,990.00')
      || case when s_other > 0 then ' / อื่นๆ ' || to_char(s_other, 'FM999,999,990.00') else '' end
      || E'\n• รวมรับ ' || to_char(s_cash + s_tr + s_other, 'FM999,999,990.00') || ' บาท'
      || E'\n• ยอดค้างชำระทั้งหมด ' || to_char(s_debt, 'FM999,999,990.00') || ' บาท'
      || E'\n• ปิดยอด: ' || case when n_staff = 0 then 'ไม่มีการรับเงิน'
                               when n_close = 0 then '⚠️ ยังไม่ปิดยอด'
                               when n_close < n_staff then '⚠️ ปิดแล้ว ' || n_close || '/' || n_staff || ' คน'
                               else 'ปิดแล้ว' end
      || case when n_close > 0 and d_close < 0 then ' (เงินสดขาด ' || to_char(-d_close, 'FM999,999,990.00') || ')'
              when n_close > 0 and d_close > 0 then ' (เงินสดเกิน ' || to_char(d_close, 'FM999,999,990.00') || ')'
              when n_close > 0 then ' (เงินสดตรง)' else '' end
      || case when n_pass + n_fail > 0 then E'\n• ตรวจสภาพ: ผ่าน ' || n_pass || ' / ไม่ผ่าน ' || n_fail else '' end
      || case when n_late > 0 then E'\n• ⚠️ งานขนส่งเกินกำหนด ' || n_late || ' งาน' else '' end;
  end loop;

  select count(*) filter (where tax_exp between p_day + 1 and p_day + 7),
         count(*) filter (where prb_exp between p_day + 1 and p_day + 7)
    into n_tax, n_prb from vehicles;
  txt := txt || E'\n\n📅 อีก 7 วันข้างหน้า: ภาษีหมด ' || n_tax || ' คัน · พ.ร.บ.หมด ' || n_prb || ' คัน';
  return txt;
end $$;

-- ---------- ส่งเข้า LINE (Messaging API push) ----------
-- Vault: line_token = Channel access token, line_to = User ID (หลายคนคั่นด้วย ,)
create or replace function public.send_line_daily(p_day date default (now() at time zone 'Asia/Bangkok')::date)
returns int language plpgsql security definer set search_path = public as $$
declare tok text; tos text; u text; msg text; n int := 0;
begin
  select decrypted_secret into tok from vault.decrypted_secrets where name = 'line_token';
  select decrypted_secret into tos from vault.decrypted_secrets where name = 'line_to';
  if coalesce(tok, '') = '' or coalesce(tos, '') = '' then
    raise exception 'ยังไม่ได้ใส่ line_token หรือ line_to ใน Vault';
  end if;
  msg := left(daily_summary_text(p_day), 4900);
  foreach u in array regexp_split_to_array(tos, '\s*,\s*') loop
    continue when u = '';
    perform net.http_post(
      url     := 'https://api.line.me/v2/bot/message/push',
      headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer ' || tok),
      body    := jsonb_build_object('to', u, 'messages', jsonb_build_array(jsonb_build_object('type', 'text', 'text', msg))));
    n := n + 1;
  end loop;
  return n;
end $$;

-- ให้เจ้าของร้านกดดูตัวอย่าง / ส่งทดสอบจากหน้าตั้งค่าในแอป
create or replace function public.line_preview() returns text
language plpgsql security definer set search_path = public as $$
begin
  if coalesce(my_role(), '') <> 'owner' then raise exception 'เฉพาะเจ้าของร้านเท่านั้น'; end if;
  return daily_summary_text();
end $$;
create or replace function public.line_test() returns int
language plpgsql security definer set search_path = public as $$
begin
  if coalesce(my_role(), '') <> 'owner' then raise exception 'เฉพาะเจ้าของร้านเท่านั้น'; end if;
  return send_line_daily();
end $$;

revoke all on function public.daily_summary_text(date) from public, anon, authenticated;
revoke all on function public.send_line_daily(date) from public, anon, authenticated;
revoke all on function public.line_preview() from public, anon;
revoke all on function public.line_test() from public, anon;
grant execute on function public.line_preview() to authenticated;
grant execute on function public.line_test() to authenticated;

-- ---------- ตั้งเวลา ทุกวัน 20:00 น. เวลาไทย (= 13:00 UTC) ----------
select cron.schedule('siam-line-daily', '0 13 * * *', 'select public.send_line_daily()');

-- ---------- ขั้นตอนสุดท้าย: ใส่ค่าของ LINE (ทำเองใน SQL Editor ห้ามส่งในแชต) ----------
-- เอาเครื่องหมาย -- ข้างหน้าออก แล้วแทนค่าในเครื่องหมาย ' ' ด้วยของจริง แล้วกด Run
-- select vault.create_secret('ใส่ Channel access token ตรงนี้', 'line_token');
-- select vault.create_secret('ใส่ User ID ที่ขึ้นต้นด้วย U ตรงนี้', 'line_to');
-- ส่งทดสอบทันที:
-- select public.send_line_daily();
