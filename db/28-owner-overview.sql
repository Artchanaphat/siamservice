-- 28-owner-overview.sql : หน้า "ภาพรวมเจ้าของ" ดูทุกสาขาในหน้าเดียว (รันหลัง 27, รันซ้ำได้)
-- วิธีรัน: Supabase › SQL Editor › New query › วางทั้งไฟล์ › Run  (ไม่ลบ/ไม่แก้ข้อมูลเดิม)
-- สิ่งที่เพิ่ม
--   1) owner_overview(วันที่, รายการเงินนำส่ง): ตัวเลขทุกสาขา ใช้ได้เฉพาะเจ้าของร้าน
--      คิดแบบเดียวกับสรุป LINE (daily_summary_text) และสรุปรายเดือน (monthly_stats)
--   2) owner_detail(...): รายการต้นทางของตัวเลขแต่ละช่อง (บิล ทะเบียน วันที่ ผู้รับเงิน)
--   3) ตาราง close_acks + ack_close(): เจ้าของกด "รับทราบ" ส่วนต่างเงินสดพร้อมบันทึก (ติดตามจนจบเรื่อง)
--   4) ระบบสำรองข้อมูลรวมตาราง close_acks

-- ---------- 3) รับทราบส่วนต่างเงินสด ----------
create table if not exists public.close_acks (
  branch_id  bigint not null references public.branches(id),
  close_date date not null,
  ack_by     text not null default '',
  ack_note   text not null default '',
  ack_at     timestamptz not null default now(),
  primary key (branch_id, close_date)
);
alter table public.close_acks enable row level security;
drop policy if exists ca_read on public.close_acks;
create policy ca_read on public.close_acks for select to authenticated using (can_see_branch(branch_id));
grant select on public.close_acks to authenticated;
drop trigger if exists close_acks_audit on public.close_acks;
create trigger close_acks_audit after insert or update or delete on public.close_acks for each row execute function public.audit();

create or replace function public.ack_close(p_branch bigint, p_day date, p_note text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare who text;
begin
  if my_role() is distinct from 'owner' then raise exception 'ใช้ได้เฉพาะเจ้าของร้าน'; end if;
  select full_name into who from staff where user_id = auth.uid();
  insert into close_acks (branch_id, close_date, ack_by, ack_note, ack_at) values (p_branch, p_day, coalesce(who, ''), coalesce(p_note, ''), now())
  on conflict (branch_id, close_date) do update set ack_by = excluded.ack_by, ack_note = excluded.ack_note, ack_at = now();
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.ack_close(bigint, date, text) from public, anon;
grant execute on function public.ack_close(bigint, date, text) to authenticated;

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
                                                                              'diff', case when counted_cash is null then null else counted_cash - cash - float_cash + cash_out end, 'note', coalesce(note, ''))
                                                         order by staff_name) filter (where id is not null), '[]'))
      into j_close from cash_closes where branch_id = b.id and close_date = p_day;
    j_close := j_close || jsonb_build_object('ack', (select jsonb_build_object('by', ack_by, 'note', ack_note, 'at', ack_at) from close_acks where branch_id = b.id and close_date = p_day));
    -- สถานะงานวันนี้ และเวลาข้อมูลล่าสุดของสาขา
    j_today := j_today || jsonb_build_object(
      'q_all', (select count(*) from insp_queue where branch_id = b.id and created_at >= t0 and created_at < t1),
      'q_wait', (select count(*) from insp_queue where branch_id = b.id and created_at >= t0 and created_at < t1 and status = 'wait'),
      'q_check', (select count(*) from insp_queue where branch_id = b.id and created_at >= t0 and created_at < t1 and status = 'check'),
      'docs_wait', (select count(*) from dlt_jobs j join bills bi on bi.id = j.bill_id where bi.branch_id = b.id and bi.status <> 'void'
                     and j.status <> 'done' and bi.bill_at >= now() - interval '400 days'),
      'last', greatest((select max(created_at) from bills where branch_id = b.id and bill_at >= t0 and bill_at < t1),
                       (select max(paid_at) from payments where branch_id = b.id and paid_at >= t0 and paid_at < t1),
                       (select max(coalesce(updated_at, created_at)) from insp_queue where branch_id = b.id and created_at >= t0 and created_at < t1)));
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
                                                               'name', bi.snapshot ->> 'name', 'amt', p.amount, 'by', p.by_name, 'at', p.paid_at, 'note', coalesce(p.note, ''),
                                                               'files', (select count(*) from bill_files f where f.bill_id = p.bill_id)) order by p.paid_at)
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

-- ---------- 2) รายการต้นทางของตัวเลข ----------
-- p_kind: pay / pend / bills / exp / remit / cashout / drawer / debt / docs / queue / adv · p_sub: ตัวกรองย่อย · p_branch null = ทุกสาขา
create or replace function public.owner_detail(p_kind text, p_sub text, p_branch bigint, p_from date, p_to date, p_pass text[]) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare t0 timestamptz := (p_from::timestamp at time zone 'Asia/Bangkok'); t1 timestamptz := ((p_to + 1)::timestamp at time zone 'Asia/Bangkok'); r jsonb;
begin
  if my_role() is distinct from 'owner' then raise exception 'ใช้ได้เฉพาะเจ้าของร้าน'; end if;
  if p_kind = 'pay' then
    select jsonb_agg(x order by x->>'at') into r from (select jsonb_build_object('br', br.name, 'at', p.paid_at, 'no', bi.bill_no, 'plate', bi.snapshot ->> 'plate', 'name', bi.snapshot ->> 'name',
             'by', p.by_name, 'how', p.method || case when p.kind = 'refund' then ' (คืนเงิน)' else '' end, 'amt', case when p.kind = 'refund' then -p.amount else p.amount end,
             'note', concat_ws(' · ', nullif(p.note, ''), case when p.verified_by is not null and p.method ~ 'โอน' then 'ตรวจโดย ' || p.verified_by end)) x
        from payments p join bills bi on bi.id = p.bill_id join branches br on br.id = p.branch_id
       where (p_branch is null or p.branch_id = p_branch) and p.paid_at >= t0 and p.paid_at < t1 and not coalesce(p.rejected, false) and (p.verified or p.kind = 'refund')
         and (coalesce(p_sub, 'all') = 'all' or (p_sub = 'cash' and p.method ~ 'สด') or (p_sub = 'tr' and p.method !~ 'สด' and p.method ~ 'โอน')
              or (p_sub = 'card' and p.method !~ 'สด' and p.method !~ 'โอน')) limit 500) q;
  elsif p_kind = 'pend' then
    select jsonb_agg(x order by x->>'at') into r from (select jsonb_build_object('br', br.name, 'at', p.paid_at, 'no', bi.bill_no, 'plate', bi.snapshot ->> 'plate', 'name', bi.snapshot ->> 'name',
             'by', p.by_name, 'how', p.method, 'amt', p.amount, 'note', coalesce(p.note, '')) x
        from payments p join bills bi on bi.id = p.bill_id join branches br on br.id = p.branch_id
       where (p_branch is null or p.branch_id = p_branch) and p.kind = 'pay' and not p.verified and not coalesce(p.rejected, false)
         and (p_sub = 'all' or (p.paid_at >= t0 and p.paid_at < t1)) limit 500) q;
  elsif p_kind = 'bills' then
    select jsonb_agg(x order by x->>'at') into r from (select jsonb_build_object('br', br.name, 'at', bi.bill_at, 'no', bi.bill_no, 'plate', bi.snapshot ->> 'plate', 'name', bi.snapshot ->> 'name',
             'by', coalesce(s.full_name, ''), 'amt', bi.total - bi.refund_total,
             'pass', (select coalesce(sum((it ->> 1)::numeric), 0) from jsonb_array_elements(bi.items) it where it ->> 0 = any (p_pass)),
             'note', (select string_agg(it ->> 0, ', ') from jsonb_array_elements(bi.items) it)) x
        from bills bi join branches br on br.id = bi.branch_id left join staff s on s.user_id = bi.created_by
       where (p_branch is null or bi.branch_id = p_branch) and bi.status <> 'void' and bi.bill_at >= t0 and bi.bill_at < t1
         and (coalesce(p_sub, 'all') = 'all' or (p_sub = 'insp' and exists (select 1 from jsonb_array_elements(bi.items) it where it ->> 0 = 'ค่าตรวจสภาพ'))) limit 500) q;
  elsif p_kind = 'exp' then
    select jsonb_agg(x order by x->>'at') into r from (select jsonb_build_object('br', br.name, 'at', e.exp_date, 'name', e.category, 'by', e.by_name, 'amt', e.amount,
             'how', case e.paid_from when 'drawer' then 'เงินสดในลิ้นชัก ' || e.drawer_staff when 'bank' then 'โอนจากบัญชีร้าน' when 'owner' then 'เจ้าของจ่ายเอง' else '' end, 'note', e.note) x
        from expenses e join branches br on br.id = e.branch_id where (p_branch is null or e.branch_id = p_branch) and e.exp_date between p_from and p_to limit 500) q;
  elsif p_kind = 'remit' then
    select jsonb_agg(x order by x->>'at') into r from (select jsonb_build_object('br', br.name, 'at', m.remit_date, 'name', m.payee, 'by', m.by_name, 'amt', m.amount,
             'how', case m.method when 'drawer' then 'เงินสดในลิ้นชัก ' || m.drawer_staff when 'bank' then 'โอนจากบัญชีร้าน' when 'owner' then 'เจ้าของจ่ายเอง' else m.method end, 'note', m.note) x
        from remits m join branches br on br.id = m.branch_id where (p_branch is null or m.branch_id = p_branch) and m.remit_date between p_from and p_to limit 500) q;
  elsif p_kind in ('cashout', 'adv') then
    select jsonb_agg(x order by x->>'at') into r from (select jsonb_build_object('br', br.name, 'at', o.out_date, 'name', o.person,
             'by', o.by_name, 'amt', o.amount, 'how', case o.kind when 'owner' then 'เจ้าของเก็บเงินสด' when 'bank' then 'ฝากธนาคาร' when 'advance' then 'เบิกล่วงหน้า' else 'อื่นๆ' end
               || case when o.paid_from = 'drawer' then ' (ลิ้นชัก ' || o.drawer_staff || ')' else '' end, 'note', o.note) x
        from cash_outs o join branches br on br.id = o.branch_id
       where (p_branch is null or o.branch_id = p_branch)
         and (case when p_kind = 'adv' then o.kind = 'advance' and o.settled_ym = '' else o.out_date between p_from and p_to and (coalesce(p_sub, 'all') = 'all' or o.kind = p_sub) end) limit 500) q;
  elsif p_kind = 'drawer' then
    select jsonb_agg(x order by x->>'at') into r from (
      select jsonb_build_object('br', br.name, 'at', e.exp_date, 'name', 'รายจ่าย: ' || e.category, 'by', e.drawer_staff, 'amt', e.amount, 'note', e.note) x
        from expenses e join branches br on br.id = e.branch_id where (p_branch is null or e.branch_id = p_branch) and e.exp_date between p_from and p_to and e.paid_from = 'drawer'
      union all select jsonb_build_object('br', br.name, 'at', m.remit_date, 'name', 'เงินนำส่ง: ' || m.payee, 'by', m.drawer_staff, 'amt', m.amount, 'note', m.note)
        from remits m join branches br on br.id = m.branch_id where (p_branch is null or m.branch_id = p_branch) and m.remit_date between p_from and p_to and m.method = 'drawer'
      union all select jsonb_build_object('br', br.name, 'at', o.out_date, 'name', 'นำเงินสดออก: ' || o.person, 'by', o.drawer_staff, 'amt', o.amount, 'note', o.note)
        from cash_outs o join branches br on br.id = o.branch_id where (p_branch is null or o.branch_id = p_branch) and o.out_date between p_from and p_to and o.paid_from = 'drawer') q;
  elsif p_kind = 'debt' then
    select jsonb_agg(x order by x->>'at') into r from (select jsonb_build_object('br', br.name, 'at', bi.bill_at, 'no', bi.bill_no, 'plate', bi.snapshot ->> 'plate', 'name', bi.snapshot ->> 'name',
             'by', coalesce(s.full_name, ''), 'amt', bi.total - bi.refund_total - coalesce(p.paid, 0), 'note', 'ยอดบิล ' || to_char(bi.total - bi.refund_total, 'FM999,999,990.00')) x
        from bills bi join branches br on br.id = bi.branch_id left join staff s on s.user_id = bi.created_by
        left join (select bill_id, sum(case when kind = 'refund' then -amount when verified and not coalesce(rejected, false) then amount else 0 end) paid from payments group by bill_id) p on p.bill_id = bi.id
       where (p_branch is null or bi.branch_id = p_branch) and bi.status <> 'void' and bi.bill_at >= now() - interval '400 days'
         and bi.total - bi.refund_total - coalesce(p.paid, 0) > 0.004 and (coalesce(p_sub, 'all') = 'all' or (p_sub = 'old' and bi.bill_at < now() - interval '30 days')) limit 500) q;
  elsif p_kind = 'docs' then
    select jsonb_agg(x order by x->>'at') into r from (select jsonb_build_object('br', br.name, 'at', bi.bill_at, 'no', bi.bill_no, 'plate', bi.snapshot ->> 'plate', 'name', bi.snapshot ->> 'name',
             'by', coalesce(j.updated_by_name, ''), 'how', case j.status when 'received' then 'รอยื่นขนส่ง' when 'submitted' then 'ยื่นแล้ว รอป้าย/เล่ม' when 'plate' then 'ได้แล้ว รอลูกค้ารับ' else j.status end,
             'note', coalesce(j.note, '')) x
        from dlt_jobs j join bills bi on bi.id = j.bill_id join branches br on br.id = bi.branch_id
       where (p_branch is null or bi.branch_id = p_branch) and bi.status <> 'void' and j.status <> 'done' and bi.bill_at >= now() - interval '400 days'
         and (coalesce(p_sub, 'all') = 'all' or j.status = p_sub) limit 500) q;
  elsif p_kind = 'queue' then
    select jsonb_agg(x order by x->>'at') into r from (select jsonb_build_object('br', br.name, 'at', q.created_at, 'plate', q.plate, 'name', q.cust_name, 'by', coalesce(q.updated_by_name, ''),
             'how', case q.status when 'wait' then 'รอตรวจ' when 'check' then 'กำลังตรวจ' when 'pass' then 'ผ่าน' when 'fail' then 'ไม่ผ่าน' else q.status end, 'note', coalesce(q.note, '')) x
        from insp_queue q join branches br on br.id = q.branch_id
       where (p_branch is null or q.branch_id = p_branch) and q.created_at >= t0 and q.created_at < t1
         and (coalesce(p_sub, 'all') = 'all' or q.status = p_sub or (p_sub = 'done' and q.status in ('pass','fail'))) limit 500) q;
  else raise exception 'ไม่รู้จักรายการ %', p_kind;
  end if;
  return coalesce(r, '[]');
end $$;
revoke all on function public.owner_detail(text, text, bigint, date, date, text[]) from public, anon;
grant execute on function public.owner_detail(text, text, bigint, date, date, text[]) to authenticated;

-- ---------- 4) สำรองข้อมูล (ต่อจาก 27) ----------
create or replace function public._backup_make(p_kind text default 'auto') returns bigint
language plpgsql security definer set search_path = public as $$
declare t text; k text; cols text; d jsonb := '{}'; c jsonb := '{}'; sk jsonb := '[]'; arr jsonb; nid bigint;
  tabs text[][] := array[['branches','id','*'],['staff','user_id','user_id,username,full_name,role,branch_id,active,created_at'],
    ['customers','id','*'],['vehicles','id','*'],['bills','id','*'],['payments','id','*'],['bill_edits','id','*'],['dlt_jobs','bill_id','*'],
    ['bill_files','id','*'],['bill_requests','id','*'],['insp_queue','id','*'],['cash_closes','id','*'],['expenses','id','*'],['remits','id','*'],['cash_outs','id','*'],['exp_requests','id','*'],['close_acks','branch_id','*'],
    ['app_settings','key','*'],['news','id','*']];
  i int;
begin
  for i in 1..array_length(tabs,1) loop
    t := tabs[i][1]; k := tabs[i][2]; cols := tabs[i][3];
    if to_regclass('public.' || t) is null then sk := sk || to_jsonb(t); continue; end if;
    begin
      execute format('select coalesce(jsonb_agg(to_jsonb(x) order by x.%I), ''[]'') from (select %s from public.%I) x', k, cols, t) into arr;
    exception when others then sk := sk || to_jsonb(t); continue;
    end;
    d := d || jsonb_build_object(t, arr); c := c || jsonb_build_object(t, jsonb_array_length(arr));
  end loop;
  insert into backup_snapshots (kind, size_bytes, counts, skipped, data)
  values (coalesce(p_kind,'auto'), octet_length(d::text), c, sk, d) returning id into nid;
  -- เก็บ 14 ชุดล่าสุด
  delete from backup_snapshots where id not in (select id from backup_snapshots order by created_at desc limit 14);
  return nid;
end $$;
revoke all on function public._backup_make(text) from public, anon, authenticated;

create or replace function public.restore_backup(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare t text; n int; out jsonb := '{}'; total int := 0; seq text; cols text; sel text; idc text;
  tabs text[] := array['branches','customers','vehicles','bills','payments','bill_edits','dlt_jobs','bill_files','bill_requests',
                       'insp_queue','cash_closes','expenses','remits','cash_outs','exp_requests','close_acks','app_settings','news','audit_log'];
begin
  if my_role() is distinct from 'owner' then raise exception 'กู้คืนข้อมูลได้เฉพาะเจ้าของร้าน'; end if;
  if p is null or p->>'app' is distinct from 'siam-service-backup' then raise exception 'ไฟล์นี้ไม่ใช่ไฟล์สำรองของระบบ'; end if;
  perform set_config('siam.restoring', '1', true);
  foreach t in array tabs loop
    if p->'data' ? t and to_regclass('public.' || t) is not null then
      select string_agg(quote_ident(c.column_name), ',' order by c.ordinal_position) into cols
        from information_schema.columns c
       where c.table_schema = 'public' and c.table_name = t
         and not exists (select 1 from jsonb_array_elements(p->'data'->t) e where not e ? c.column_name);
      if cols is null then continue; end if;
      -- คอลัมน์ที่อ้างถึงบัญชีผู้ใช้ (created_by ฯลฯ): ถ้าบัญชีนั้นไม่มีแล้ว (เช่น กู้ลงโปรเจกต์ใหม่) ใส่ว่างแทน ไม่ให้กู้ล้มทั้งชุด
      select string_agg(case when exists (select 1 from pg_constraint k join pg_attribute a on a.attrelid = k.conrelid and a.attnum = k.conkey[1]
                                           where k.conrelid = ('public.' || quote_ident(t))::regclass and k.confrelid = 'auth.users'::regclass
                                             and a.attname = c.column_name and not a.attnotnull)
                              then format('(case when exists (select 1 from auth.users u where u.id = r.%1$I) then r.%1$I end)', c.column_name)
                              else 'r.' || quote_ident(c.column_name) end, ',' order by c.ordinal_position) into sel
        from information_schema.columns c
       where c.table_schema = 'public' and c.table_name = t
         and not exists (select 1 from jsonb_array_elements(p->'data'->t) e where not e ? c.column_name);
      execute format('insert into public.%I (%s) overriding system value select %s from jsonb_populate_recordset(null::public.%I, $1) r on conflict do nothing', t, cols, sel, t)
        using p->'data'->t;
      get diagnostics n = row_count;
      out := out || jsonb_build_object(t, n); total := total + n;
      -- ตั้งตัวนับรหัสอัตโนมัติ เฉพาะตารางที่มีคอลัมน์แบบนี้ (dlt_jobs / app_settings ไม่มี)
      for idc in select c.column_name from information_schema.columns c
                  where c.table_schema = 'public' and c.table_name = t
                    and (c.is_identity = 'YES' or c.column_default like 'nextval(%') loop
        seq := pg_get_serial_sequence('public.' || quote_ident(t), idc);
        if seq is not null then
          execute format('select setval(%L, greatest(coalesce((select max(%I) from public.%I), 0), 1))', seq, idc, t);
        end if;
      end loop;
    end if;
  end loop;
  -- เลขบิลถัดไปต่อจากเลขสูงสุดที่มี (รูปแบบ รหัสสาขา-ปีสองหลัก+เลขลำดับ เลขลำดับ 4 หลักขึ้นไป)
  insert into bill_counters (branch_id, be_year, last_no)
  select branch_id, extract(year from (bill_at at time zone 'Asia/Bangkok'))::int + 543,
         max(substring(bill_no from '-[0-9]{2}([0-9]+)$')::int)
    from bills where bill_no ~ '-[0-9]{2}[0-9]+$' group by 1, 2
  on conflict (branch_id, be_year) do update set last_no = greatest(bill_counters.last_no, excluded.last_no);
  perform set_config('siam.restoring', '0', true);
  return jsonb_build_object('inserted', out, 'total', total);
end $$;
revoke all on function public.restore_backup(jsonb) from public, anon;
grant execute on function public.restore_backup(jsonb) to authenticated;
