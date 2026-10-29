-- 28-owner-overview.sql : หน้า "ภาพรวมเจ้าของ" ดูทุกสาขาในหน้าเดียว (รันหลัง 27, รันซ้ำได้)
-- วิธีรัน: Supabase › SQL Editor › New query › วางทั้งไฟล์ › Run  (อ่านอย่างเดียว ไม่แก้ข้อมูล)
-- ฟังก์ชัน owner_overview(วันที่, รายการเงินนำส่ง) ใช้ได้เฉพาะเจ้าของร้าน
-- ตัวเลขคิดแบบเดียวกับสรุป LINE (daily_summary_text) และสรุปรายเดือน (monthly_stats)

create or replace function public.owner_overview(p_day date, p_pass text[]) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  t0 timestamptz := (p_day::timestamp at time zone 'Asia/Bangkok');
  t1 timestamptz := ((p_day + 1)::timestamp at time zone 'Asia/Bangkok');
  m0 date := date_trunc('month', p_day)::date;
  pm0 date := (date_trunc('month', p_day) - interval '1 month')::date;
  pm1 date := least((date_trunc('month', p_day) - interval '1 month')::date + (p_day - date_trunc('month', p_day)::date), (date_trunc('month', p_day) - interval '1 day')::date);
  b record; st jsonb; v_items jsonb; l_rec int; l_sub int; l_pl int; out jsonb := '[]'; o jsonb;
  j_today jsonb; j_close jsonb; j_out jsonb; j_mtd jsonb; j_prev jsonb; j_todo jsonb; j_follow jsonb;
begin
  if my_role() is distinct from 'owner' then raise exception 'หน้านี้ใช้ได้เฉพาะเจ้าของร้าน'; end if;
  select value into st from app_settings where key = 'main';
  l_rec := coalesce(nullif(st ->> 'dlt_late_received', '')::int, 2);
  l_sub := coalesce(nullif(st ->> 'dlt_late_submitted', '')::int, 7);
  l_pl  := coalesce(nullif(st ->> 'dlt_late_plate', '')::int, 14);
  v_items := coalesce(st -> 'dlt_items_tax', '["ค่าภาษีรถ","ค่าฝากต่อภาษี"]'::jsonb)
          || coalesce(st -> 'dlt_items_tr', '["ค่าโอน","ค่าย้าย","ค่าโอนย้าย","ค่าเปลี่ยนสี","ค่าตรวจสภาพโอน","ค่าเรื่อง"]'::jsonb);

  for b in select id, code, name from branches where active order by id loop
    -- ---------- วันนี้ ----------
    select jsonb_build_object(
      'car', count(*) filter (where not moto), 'moto', count(*) filter (where moto)) into j_today
      from (select coalesce(snapshot ->> 'plate', '') || '|' || coalesce(snapshot ->> 'prov', '') k,
                   bool_or(coalesce(snapshot ->> 'type', '') like '%จักรยานยนต์%') moto
              from bills where branch_id = b.id and status <> 'void' and bill_at >= t0 and bill_at < t1 group by 1
            union all
            select plate || '|' || province, bool_or(car_type in ('รย.12', 'รย.17'))
              from insp_queue q where branch_id = b.id and created_at >= t0 and created_at < t1 and not billed
               and not exists (select 1 from bills x where x.branch_id = b.id and x.bill_at >= t0 and x.bill_at < t1
                                and x.snapshot ->> 'plate' = q.plate and x.snapshot ->> 'prov' = q.province)
             group by 1) v;
    j_today := j_today
      || (select jsonb_build_object('bills', count(*), 'bill_sum', coalesce(sum(total - refund_total), 0),
                                    'insp', count(*) filter (where exists (select 1 from jsonb_array_elements(items) it where it ->> 0 = 'ค่าตรวจสภาพ')))
            from bills where branch_id = b.id and status <> 'void' and bill_at >= t0 and bill_at < t1)
      || (select jsonb_build_object('pass', count(*) filter (where status = 'pass'), 'fail', count(*) filter (where status = 'fail'),
                                    'wait', count(*) filter (where status in ('wait','check')))
            from insp_queue where branch_id = b.id and created_at >= t0 and created_at < t1)
      || (select jsonb_build_object('cash', coalesce(sum(a) filter (where m ~ 'สด'), 0),
                                    'tr', coalesce(sum(a) filter (where m !~ 'สด' and m ~ 'โอน'), 0),
                                    'card', coalesce(sum(a) filter (where m !~ 'สด' and m !~ 'โอน' and m ~ 'บัตร'), 0),
                                    'other', coalesce(sum(a) filter (where m !~ 'สด' and m !~ 'โอน' and m !~ 'บัตร'), 0),
                                    'ref_n', count(*) filter (where k = 'refund'), 'ref_sum', coalesce(-sum(a) filter (where k = 'refund'), 0))
            from (select coalesce(method, '') m, kind k, case when kind = 'refund' then -amount else amount end a
                    from payments where branch_id = b.id and paid_at >= t0 and paid_at < t1
                     and not coalesce(rejected, false) and (verified or kind = 'refund')) x)
      || (select jsonb_build_object('pend_n', count(*), 'pend_sum', coalesce(sum(amount), 0))
            from payments where branch_id = b.id and paid_at >= t0 and paid_at < t1 and kind = 'pay' and not verified and not coalesce(rejected, false));
    -- ปิดยอด (เงินสดที่ควรมี = เงินทอนตั้งต้น + เงินสดที่รับ − เงินที่จ่ายออกจากลิ้นชัก)
    select jsonb_build_object('staff_n', (select count(distinct coalesce(nullif(by_name, ''), 'ไม่ระบุ')) from payments
                                          where branch_id = b.id and paid_at >= t0 and paid_at < t1 and not coalesce(rejected, false) and (verified or kind = 'refund')),
                              'close_n', count(*), 'counted_n', count(*) filter (where counted_cash is not null),
                              'diff', coalesce(sum(counted_cash - cash - float_cash + cash_out) filter (where counted_cash is not null), 0),
                              'float', coalesce(sum(float_cash), 0), 'cash_out', coalesce(sum(cash_out), 0),
                              'by', max(closed_by_name), 'at', max(coalesce(updated_at, created_at)),
                              'sum', coalesce(sum(cash + transfer + card + other), 0),
                              'rows', coalesce(jsonb_agg(jsonb_build_object('staff', staff_name, 'cash', cash, 'float', float_cash, 'out', cash_out, 'counted', counted_cash,
                                                                              'diff', case when counted_cash is null then null else counted_cash - cash - float_cash + cash_out end)
                                                         order by staff_name) filter (where id is not null), '[]'))
      into j_close from cash_closes where branch_id = b.id and close_date = p_day;
    -- เงินที่จ่ายออกวันนี้
    select jsonb_build_object(
      'exp', coalesce((select sum(amount) from expenses where branch_id = b.id and exp_date = p_day), 0),
      'exp_n', (select count(*) from expenses where branch_id = b.id and exp_date = p_day),
      'remit', coalesce((select sum(amount) from remits where branch_id = b.id and remit_date = p_day), 0),
      'owner', coalesce((select sum(amount) from cash_outs where branch_id = b.id and out_date = p_day and kind = 'owner'), 0),
      'bank', coalesce((select sum(amount) from cash_outs where branch_id = b.id and out_date = p_day and kind = 'bank'), 0),
      'advance', coalesce((select sum(amount) from cash_outs where branch_id = b.id and out_date = p_day and kind = 'advance'), 0),
      'other', coalesce((select sum(amount) from cash_outs where branch_id = b.id and out_date = p_day and kind = 'other'), 0),
      'drawer', drawer_total(b.id, p_day)) into j_out;

    -- ---------- เดือนนี้ถึงวันที่เลือก และช่วงเดียวกันของเดือนก่อน ----------
    j_mtd := month_part(b.id, m0, p_day, p_pass);
    j_prev := month_part(b.id, pm0, pm1, p_pass);

    -- ---------- ต้องจัดการ ----------
    select jsonb_build_object(
      'transfers', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'bill_id', p.bill_id, 'bill_no', bi.bill_no, 'plate', bi.snapshot ->> 'plate',
                                                               'name', bi.snapshot ->> 'name', 'amt', p.amount, 'by', p.by_name, 'at', p.paid_at) order by p.paid_at)
                              from payments p join bills bi on bi.id = p.bill_id
                             where p.branch_id = b.id and p.kind = 'pay' and not p.verified and not coalesce(p.rejected, false)), '[]'),
      'bill_reqs', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'bill_id', r.bill_id, 'bill_no', bi.bill_no, 'plate', bi.snapshot ->> 'plate',
                                                               'kind', r.kind, 'amt', r.amount, 'reason', r.reason, 'by', r.requested_by, 'at', r.requested_at,
                                                               'total', bi.total - bi.refund_total) order by r.requested_at)
                              from bill_requests r join bills bi on bi.id = r.bill_id where r.branch_id = b.id and r.status = 'pending'), '[]'),
      'exp_reqs', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'cat', category, 'amt', amount, 'note', note, 'by', req_by, 'd', req_date,
                                                               'photo', photo <> '') order by created_at)
                              from exp_requests where branch_id = b.id and status = 'pending'), '[]'),
      'unclosed', coalesce((select jsonb_agg(d order by d) from (
                     select distinct (p.paid_at at time zone 'Asia/Bangkok')::date d from payments p
                      where p.branch_id = b.id and p.paid_at >= t0 - interval '7 days' and p.paid_at < t1
                        and not coalesce(p.rejected, false) and (p.verified or p.kind = 'refund')
                        and not exists (select 1 from cash_closes c where c.branch_id = b.id and c.close_date = (p.paid_at at time zone 'Asia/Bangkok')::date)) u), '[]'))
      into j_todo;

    -- ---------- ตามเก็บ ----------
    select jsonb_build_object(
      'debt', coalesce(sum(greatest(bi.total - bi.refund_total - coalesce(p.paid, 0), 0)), 0),
      'debt_n', count(*) filter (where bi.total - bi.refund_total - coalesce(p.paid, 0) > 0.004),
      'debt_old', coalesce(sum(greatest(bi.total - bi.refund_total - coalesce(p.paid, 0), 0)) filter (where bi.bill_at < now() - interval '30 days'), 0))
      into j_follow
      from bills bi
      left join (select bill_id, sum(case when kind = 'refund' then -amount
                                          when verified and not coalesce(rejected, false) then amount else 0 end) paid
                   from payments group by bill_id) p on p.bill_id = bi.id
     where bi.branch_id = b.id and bi.status <> 'void' and bi.bill_at >= now() - interval '400 days';
    j_follow := j_follow || jsonb_build_object(
      'dlt_late', (select count(*) from bills bi left join dlt_jobs j on j.bill_id = bi.id
                    where bi.branch_id = b.id and bi.status <> 'void' and bi.bill_at >= now() - interval '400 days'
                      and exists (select 1 from jsonb_array_elements(bi.items) it where it ->> 0 in (select jsonb_array_elements_text(v_items)))
                      and coalesce(j.status, 'received') <> 'done'
                      and now() - case coalesce(j.status, 'received') when 'received' then bi.bill_at
                                    when 'submitted' then coalesce(j.submitted_at, bi.bill_at) else coalesce(j.plate_at, bi.bill_at) end
                          > case coalesce(j.status, 'received') when 'received' then make_interval(days => l_rec)
                                                                when 'submitted' then make_interval(days => l_sub) else make_interval(days => l_pl) end),
      'dlt_wait', (select count(*) from dlt_jobs j join bills bi on bi.id = j.bill_id where bi.branch_id = b.id and bi.status <> 'void' and j.status = 'plate'),
      'adv', coalesce((select sum(amount) from cash_outs where branch_id = b.id and kind = 'advance' and settled_ym = ''), 0),
      'adv_n', (select count(distinct person) from cash_outs where branch_id = b.id and kind = 'advance' and settled_ym = ''),
      'remit_paid_mtd', coalesce((select sum(amount) from remits where branch_id = b.id and remit_date >= m0 and remit_date <= p_day), 0));

    out := out || jsonb_build_array(jsonb_build_object('id', b.id, 'code', b.code, 'name', b.name, 'today', j_today, 'close', j_close, 'out', j_out,
                                                       'mtd', j_mtd, 'prev', j_prev, 'todo', j_todo, 'follow', j_follow));
  end loop;
  return jsonb_build_object('day', p_day, 'prev_from', pm0, 'prev_to', pm1, 'branches', out);
end $$;

-- ยอดรวมของเดือน (ช่วงวันที่) ต่อสาขา: แบบเดียวกับ monthly_stats
create or replace function public.month_part(p_branch bigint, p_from date, p_to date, p_pass text[]) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'bills', count(*), 'cars', count(distinct coalesce(bi.snapshot ->> 'plate', '') || '|' || coalesce(bi.snapshot ->> 'prov', '')),
    'total', coalesce(sum(bi.total - bi.refund_total), 0),
    'pass', coalesce(sum((select coalesce(sum((it ->> 1)::numeric), 0) from jsonb_array_elements(bi.items) it where it ->> 0 = any (p_pass))), 0),
    'expense', coalesce((select sum(amount) from expenses where branch_id = p_branch and exp_date between p_from and p_to), 0),
    'recv', coalesce((select sum(case when kind = 'refund' then -amount else amount end) from payments
                       where branch_id = p_branch and not coalesce(rejected, false) and (verified or kind = 'refund')
                         and paid_at >= (p_from::timestamp at time zone 'Asia/Bangkok') and paid_at < ((p_to + 1)::timestamp at time zone 'Asia/Bangkok')), 0))
    from bills bi
   where bi.branch_id = p_branch and bi.status <> 'void'
     and bi.bill_at >= (p_from::timestamp at time zone 'Asia/Bangkok') and bi.bill_at < ((p_to + 1)::timestamp at time zone 'Asia/Bangkok')
$$;
revoke all on function public.month_part(bigint, date, date, text[]) from public, anon, authenticated;

-- เงินสดที่จ่ายออกจากลิ้นชักทั้งสาขาในวันนั้น
create or replace function public.drawer_total(p_branch bigint, p_day date) returns numeric
language sql stable security definer set search_path = public as $$
  select coalesce((select sum(amount) from expenses where branch_id = p_branch and exp_date = p_day and paid_from = 'drawer'), 0)
       + coalesce((select sum(amount) from remits   where branch_id = p_branch and remit_date = p_day and method = 'drawer'), 0)
       + coalesce((select sum(amount) from cash_outs where branch_id = p_branch and out_date = p_day and paid_from = 'drawer'), 0)
$$;
revoke all on function public.drawer_total(bigint, date) from public, anon, authenticated;

revoke all on function public.owner_overview(date, text[]) from public, anon;
grant execute on function public.owner_overview(date, text[]) to authenticated;
