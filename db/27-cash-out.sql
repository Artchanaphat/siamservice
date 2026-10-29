-- 27-cash-out.sql : เงินสดที่จ่ายออกจากลิ้นชัก · นำเงินสดออก/เบิกล่วงหน้า · ขอเบิกรออนุมัติ · สรุป LINE  (รันหลัง 26, รันซ้ำได้)
-- วิธีรัน: Supabase › SQL Editor › New query › วางทั้งไฟล์ › Run  (ไม่ลบ/ไม่แก้ข้อมูลเดิม)
-- สิ่งที่เพิ่ม
--   1) รายจ่าย/เงินนำส่ง: "จ่ายด้วย" (เงินสดในลิ้นชัก / โอนจากบัญชีร้าน / เจ้าของจ่ายเอง) + ลิ้นชักของใคร + รูปใบเสร็จ
--   2) ตาราง cash_outs: นำเงินสดออก (เจ้าของเก็บเงิน / ฝากธนาคาร / พนักงานเบิกล่วงหน้า / อื่นๆ) และสถานะหักค่าแรงของเงินเบิกล่วงหน้า
--   3) ตาราง exp_requests + ฟังก์ชัน decide_exp_request: พนักงานขอเบิก หัวหน้า/เจ้าของอนุมัติแล้วลงเป็นรายจ่ายให้เอง
--   4) ปิดยอด: บันทึกยอด "จ่ายออกจากลิ้นชัก" (cash_out) ของพนักงานแต่ละคนในวันนั้น
--   5) สรุป LINE: เงินสดขาด/เกิน หักเงินทอนตั้งต้นและเงินที่จ่ายออกแล้ว + บรรทัดรายจ่าย เงินนำส่ง นำเงินสดออก ขอเบิกรออนุมัติ
--   6) ระบบสำรองข้อมูลรวม 2 ตารางใหม่

-- ---------- 1) รายจ่าย / เงินนำส่ง ----------
alter table public.expenses add column if not exists paid_from    text not null default '';
alter table public.expenses add column if not exists drawer_staff text not null default '';
alter table public.expenses add column if not exists photo        text not null default '';
alter table public.remits   add column if not exists drawer_staff text not null default '';
alter table public.remits   add column if not exists photo        text not null default '';
alter table public.expenses drop constraint if exists expenses_photo_len;
alter table public.expenses add constraint expenses_photo_len check (length(photo) <= 600000);
alter table public.remits   drop constraint if exists remits_photo_len;
alter table public.remits   add constraint remits_photo_len check (length(photo) <= 600000);

-- ---------- 2) นำเงินสดออก / เบิกล่วงหน้า ----------
create table if not exists public.cash_outs (
  id           bigint generated always as identity primary key,
  branch_id    bigint not null references public.branches(id),
  out_date     date not null,
  kind         text not null check (kind in ('owner','bank','advance','other')),
  person       text not null default '',          -- ผู้รับเงิน / พนักงานที่เบิกล่วงหน้า
  amount       numeric(12,2) not null check (amount > 0),
  paid_from    text not null default 'drawer',    -- drawer / bank / owner
  drawer_staff text not null default '',          -- ลิ้นชักของพนักงานคนไหน (เมื่อ paid_from = drawer)
  note         text not null default '',
  by_name      text not null default '',
  settled_ym   text not null default '',          -- เบิกล่วงหน้า: เดือนที่หักค่าแรงแล้ว (YYYY-MM)
  settled_by   text not null default '',
  created_at   timestamptz not null default now()
);
create index if not exists cash_outs_branch_date on public.cash_outs (branch_id, out_date);
alter table public.cash_outs enable row level security;
drop policy if exists co_read on public.cash_outs;
drop policy if exists co_ins  on public.cash_outs;
drop policy if exists co_upd  on public.cash_outs;
drop policy if exists co_del  on public.cash_outs;
create policy co_read on public.cash_outs for select to authenticated using (can_see_branch(branch_id));
create policy co_ins  on public.cash_outs for insert to authenticated with check (can_see_branch(branch_id));
create policy co_upd  on public.cash_outs for update to authenticated
  using (can_see_branch(branch_id) and my_role() in ('owner','head')) with check (can_see_branch(branch_id));
create policy co_del  on public.cash_outs for delete to authenticated
  using (can_see_branch(branch_id) and my_role() in ('owner','head'));
grant select, insert, update, delete on public.cash_outs to authenticated;
drop trigger if exists cash_outs_audit on public.cash_outs;
create trigger cash_outs_audit after insert or update or delete on public.cash_outs for each row execute function public.audit();

-- ---------- 3) ขอเบิกรออนุมัติ ----------
create table if not exists public.exp_requests (
  id          bigint generated always as identity primary key,
  branch_id   bigint not null references public.branches(id),
  req_date    date not null default ((now() at time zone 'Asia/Bangkok')::date),
  category    text not null default '',
  amount      numeric(12,2) not null check (amount > 0),
  note        text not null default '',
  photo       text not null default '' check (length(photo) <= 600000),
  req_by      text not null default '',
  req_uid     uuid default auth.uid(),
  status      text not null default 'pending' check (status in ('pending','approved','rejected')),
  decided_by  text not null default '',
  decided_at  timestamptz,
  decide_note text not null default '',
  expense_id  bigint,
  created_at  timestamptz not null default now()
);
create index if not exists exp_requests_branch on public.exp_requests (branch_id, status);
alter table public.exp_requests enable row level security;
drop policy if exists er_read on public.exp_requests;
drop policy if exists er_ins  on public.exp_requests;
drop policy if exists er_del  on public.exp_requests;
create policy er_read on public.exp_requests for select to authenticated using (can_see_branch(branch_id));
-- ยื่นคำขอได้เฉพาะสถานะรออนุมัติ ในนามตัวเอง · ผลอนุมัติเปลี่ยนได้ทางฟังก์ชัน decide_exp_request เท่านั้น
create policy er_ins  on public.exp_requests for insert to authenticated
  with check (can_see_branch(branch_id) and status = 'pending' and req_uid = auth.uid() and expense_id is null);
-- ผู้ขอยกเลิกคำขอของตัวเองที่ยังรออนุมัติได้ · เจ้าของร้าน/หัวหน้าลบได้
create policy er_del  on public.exp_requests for delete to authenticated
  using (can_see_branch(branch_id) and ((status = 'pending' and req_uid = auth.uid()) or my_role() in ('owner','head')));
grant select, insert, delete on public.exp_requests to authenticated;
drop trigger if exists exp_requests_audit on public.exp_requests;
create trigger exp_requests_audit after insert or update or delete on public.exp_requests for each row execute function public.audit();

create or replace function public.decide_exp_request(p_id bigint, p_approve boolean, p_paid_from text default 'drawer',
                                                     p_drawer text default '', p_note text default '')
returns jsonb language plpgsql security definer set search_path = public as $$
declare r exp_requests; rl text := my_role(); who text; eid bigint;
begin
  select * into r from exp_requests where id = p_id for update;
  if not found then raise exception 'ไม่พบคำขอเบิก'; end if;
  if rl is null or rl not in ('owner','head') or not can_see_branch(r.branch_id) then raise exception 'อนุมัติได้เฉพาะเจ้าของร้าน/หัวหน้าสาขา'; end if;
  if r.status <> 'pending' then raise exception 'คำขอนี้ถูกพิจารณาไปแล้ว'; end if;
  if rl = 'head' and r.req_uid = auth.uid() then raise exception 'หัวหน้าสาขาอนุมัติคำขอของตัวเองไม่ได้ ให้เจ้าของร้านอนุมัติ'; end if;
  if coalesce(p_paid_from,'') not in ('drawer','bank','owner') then raise exception 'กรุณาเลือกว่าจ่ายด้วยอะไร'; end if;
  select full_name into who from staff where user_id = auth.uid();
  if p_approve then
    insert into expenses (branch_id, exp_date, category, amount, note, by_name, paid_from, drawer_staff, photo)
    values (r.branch_id, (now() at time zone 'Asia/Bangkok')::date, r.category, r.amount,
            trim(both ' ' from r.note || case when r.req_by <> '' then ' (ขอเบิกโดย ' || r.req_by || ')' else '' end),
            coalesce(who, ''), p_paid_from, case when p_paid_from = 'drawer' then coalesce(nullif(p_drawer,''), who, '') else '' end, r.photo)
    returning id into eid;
  end if;
  update exp_requests set status = case when p_approve then 'approved' else 'rejected' end,
         decided_by = coalesce(who, ''), decided_at = now(), decide_note = coalesce(p_note, ''), expense_id = eid
   where id = p_id;
  return jsonb_build_object('status', case when p_approve then 'approved' else 'rejected' end, 'expense_id', eid);
end $$;
revoke all on function public.decide_exp_request(bigint, boolean, text, text, text) from public, anon;
grant execute on function public.decide_exp_request(bigint, boolean, text, text, text) to authenticated;

-- ---------- 4) ปิดยอด: เงินที่จ่ายออกจากลิ้นชัก ----------
alter table public.cash_closes add column if not exists cash_out numeric(12,2) not null default 0;

create or replace function public.drawer_out(p_branch bigint, p_day date, p_staff text) returns numeric
language sql stable security definer set search_path = public as $$
  select coalesce((select sum(amount) from expenses where branch_id = p_branch and exp_date = p_day and paid_from = 'drawer' and drawer_staff = p_staff), 0)
       + coalesce((select sum(amount) from remits   where branch_id = p_branch and remit_date = p_day and method = 'drawer' and drawer_staff = p_staff), 0)
       + coalesce((select sum(amount) from cash_outs where branch_id = p_branch and out_date = p_day and paid_from = 'drawer' and drawer_staff = p_staff), 0)
$$;
revoke all on function public.drawer_out(bigint, date, text) from public, anon, authenticated;

create or replace function public.cash_close_compute()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  t0 timestamptz := (new.close_date::timestamp at time zone 'Asia/Bangkok');
  t1 timestamptz := ((new.close_date + 1)::timestamp at time zone 'Asia/Bangkok');
  rl text := my_role(); who text;
begin
  if auth.uid() is null then return new; end if;   -- งานเบื้องหลัง / กู้คืน
  if rl is null or not can_see_branch(new.branch_id) then raise exception 'ไม่มีสิทธิ์ปิดยอดของสาขานี้'; end if;
  if rl not in ('owner','head') then
    if tg_op = 'UPDATE' or exists (select 1 from cash_closes where branch_id = new.branch_id and close_date = new.close_date and created_at < now()) then
      raise exception 'วันนี้ปิดยอดไปแล้ว การแก้ไขยอดปิดทำได้เฉพาะเจ้าของร้าน/หัวหน้าสาขา';
    end if;
  end if;
  -- ยอดของพนักงานคนนั้นในวันนั้น: เงินที่ยืนยันแล้ว + คืนเงิน (ติดลบ) ไม่นับเงินโอนรอตรวจ/ที่ถูกปฏิเสธ
  select coalesce(sum(a) filter (where method ~ 'สด'), 0),
         coalesce(sum(a) filter (where method !~ 'สด' and method ~ 'โอน'), 0),
         coalesce(sum(a) filter (where method !~ 'สด' and method !~ 'โอน' and method ~ 'บัตร'), 0),
         coalesce(sum(a) filter (where method !~ 'สด' and method !~ 'โอน' and method !~ 'บัตร'), 0)
    into new.cash, new.transfer, new.card, new.other
    from (select coalesce(method,'') method, case when kind = 'refund' then -amount else amount end a
            from payments
           where branch_id = new.branch_id and paid_at >= t0 and paid_at < t1
             and not coalesce(rejected,false) and (kind = 'refund' or verified)
             and coalesce(nullif(by_name,''),'ไม่ระบุ') = new.staff_name) x;
  -- เงินสดที่จ่ายออกจากลิ้นชักของพนักงานคนนั้นในวันนั้น (รายจ่าย เงินนำส่ง นำเงินสดออก/เบิกล่วงหน้า)
  new.cash_out := drawer_out(new.branch_id, new.close_date, new.staff_name);
  select full_name into who from staff where user_id = auth.uid();
  new.closed_by_name := coalesce(who, new.closed_by_name);
  if tg_op = 'UPDATE' then new.updated_at := now(); end if;
  return new;
end $$;
revoke all on function public.cash_close_compute() from public, anon, authenticated;

-- ---------- 5) สรุป LINE (ต่อจาก 21) ----------
create or replace function public.daily_summary_text(p_day date default (now() at time zone 'Asia/Bangkok')::date)
returns text language plpgsql stable security definer set search_path = public as $$
declare
  t0 timestamptz := (p_day::timestamp at time zone 'Asia/Bangkok');
  t1 timestamptz := ((p_day + 1)::timestamp at time zone 'Asia/Bangkok');
  b record; txt text; n_bill int; s_bill numeric; s_cash numeric; s_tr numeric; s_other numeric; s_debt numeric;
  n_car int; n_moto int;
  n_close int; n_staff int; d_close numeric; s_close numeric; n_late int; n_pass int; n_fail int; n_tax int; n_prb int;
  n_ref int; s_ref numeric; n_insp int; n_old int; s_old numeric; l_rec int := 2; l_sub int := 7; l_pl int := 14; v_items jsonb; st jsonb; n_pend int; s_pend numeric; n_pend_all int; s_pend_all numeric;
  n_exp int; s_exp numeric; s_exp_dr numeric; n_rm int; s_rm numeric; s_out_owner numeric; s_out_bank numeric; s_out_adv numeric; s_out_oth numeric; n_req int; s_req numeric;
begin
  select value into st from app_settings where key = 'main';
  l_rec := nullif(st ->> 'dlt_late_received', '')::int; l_sub := nullif(st ->> 'dlt_late_submitted', '')::int; l_pl := nullif(st ->> 'dlt_late_plate', '')::int;
  v_items := coalesce(st -> 'dlt_items_tax', '["ค่าภาษีรถ","ค่าฝากต่อภาษี"]'::jsonb)
          || coalesce(st -> 'dlt_items_tr', '["ค่าโอน","ค่าย้าย","ค่าโอนย้าย","ค่าเปลี่ยนสี","ค่าตรวจสภาพโอน","ค่าเรื่อง"]'::jsonb);
  l_rec := coalesce(l_rec, 2); l_sub := coalesce(l_sub, 7); l_pl := coalesce(l_pl, 14);
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
    -- เงินสดที่ควรมี = เงินทอนตั้งต้น + เงินสดที่รับ − เงินที่จ่ายออกจากลิ้นชัก
    select count(*), coalesce(sum(counted_cash - cash - float_cash + cash_out) filter (where counted_cash is not null), 0),
           coalesce(sum(coalesce(cash, 0) + coalesce(transfer, 0) + coalesce(card, 0) + coalesce(other, 0)), 0)
      into n_close, d_close, s_close from cash_closes where branch_id = b.id and close_date = p_day;
    -- รายจ่าย เงินนำส่ง นำเงินสดออก คำขอเบิก ของวันนี้
    select count(*), coalesce(sum(amount), 0), coalesce(sum(amount) filter (where paid_from = 'drawer'), 0)
      into n_exp, s_exp, s_exp_dr from expenses where branch_id = b.id and exp_date = p_day;
    select count(*), coalesce(sum(amount), 0) into n_rm, s_rm from remits where branch_id = b.id and remit_date = p_day;
    select coalesce(sum(amount) filter (where kind = 'owner'), 0), coalesce(sum(amount) filter (where kind = 'bank'), 0),
           coalesce(sum(amount) filter (where kind = 'advance'), 0), coalesce(sum(amount) filter (where kind = 'other'), 0)
      into s_out_owner, s_out_bank, s_out_adv, s_out_oth from cash_outs where branch_id = b.id and out_date = p_day;
    select count(*), coalesce(sum(amount), 0) into n_req, s_req from exp_requests where branch_id = b.id and status = 'pending';
    -- ตรวจสภาพ: บิลวันนี้ที่มีค่าตรวจสภาพ
    select count(*) into n_insp from bills bi
     where bi.branch_id = b.id and bi.status <> 'void' and bi.bill_at >= t0 and bi.bill_at < t1
       and exists (select 1 from jsonb_array_elements(bi.items) it where it ->> 0 = 'ค่าตรวจสภาพ');
    -- รับชำระบิลวันก่อน (ตรวจแล้ว ไม่นับคืนเงิน)
    select count(distinct p.bill_id), coalesce(sum(p.amount), 0) into n_old, s_old
      from payments p join bills bi on bi.id = p.bill_id
     where p.branch_id = b.id and p.paid_at >= t0 and p.paid_at < t1 and p.kind = 'pay'
       and p.verified and not coalesce(p.rejected, false) and bi.bill_at < t0;
    -- คิวตรวจ
    select count(*) filter (where status = 'pass'), count(*) filter (where status = 'fail') into n_pass, n_fail
      from insp_queue where branch_id = b.id and created_at >= t0 and created_at < t1;
    -- งานขนส่งเกินกำหนด (ตามที่ตั้งไว้ ค่าเริ่มต้น รอยื่น 2 วัน / ยื่นแล้ว 7 วัน / ได้ป้าย 14 วัน)
    select count(*) into n_late
      from bills bi left join dlt_jobs j on j.bill_id = bi.id
     where bi.branch_id = b.id and bi.status <> 'void' and bi.bill_at >= now() - interval '400 days'
       and exists (select 1 from jsonb_array_elements(bi.items) it
                    where it ->> 0 in (select jsonb_array_elements_text(v_items)))
       and coalesce(j.status, 'received') <> 'done'
       and now() - case coalesce(j.status, 'received')
                     when 'received'  then bi.bill_at
                     when 'submitted' then coalesce(j.submitted_at, bi.bill_at)
                     else coalesce(j.plate_at, bi.bill_at) end
           > case coalesce(j.status, 'received') when 'received' then make_interval(days => l_rec)
                                                 when 'submitted' then make_interval(days => l_sub) else make_interval(days => l_pl) end;

    txt := txt || E'\n\n🏢 ' || b.name
      || E'\n• รถเข้าวันนี้ ' || (n_car + n_moto) || ' คัน (รถยนต์ ' || n_car || ' / มอเตอร์ไซค์ ' || n_moto || ')'
      || E'\n• บิลวันนี้ ' || n_bill || ' ใบ ยอด ' || to_char(s_bill, 'FM999,999,990.00') || ' บาท'
      || E'\n• รับเงิน (ตรวจแล้ว): สด ' || to_char(s_cash, 'FM999,999,990.00') || ' / โอน ' || to_char(s_tr, 'FM999,999,990.00')
      || case when s_other <> 0 then ' / อื่นๆ ' || to_char(s_other, 'FM999,999,990.00') else '' end
      || E'\n• รวมรับ ' || to_char(s_cash + s_tr + s_other, 'FM999,999,990.00') || ' บาท'
      || case when n_ref > 0 then ' (หักคืนเงินแล้ว ' || to_char(s_ref, 'FM999,999,990.00') || ' บาท ' || n_ref || ' รายการ)' else '' end
      || case when n_old > 0 then E'\n• รับชำระบิลวันก่อน ' || n_old || ' ใบ ' || to_char(s_old, 'FM999,999,990.00') || ' บาท (รวมในยอดรับแล้ว)' else '' end
      || case when n_pend > 0 then E'\n• ⏳ เงินโอนรอตรวจ ' || n_pend || ' รายการ ' || to_char(s_pend, 'FM999,999,990.00') || ' บาท (ยังไม่นับในยอดรับ)' else '' end
      || case when n_pend_all > n_pend then E'\n• ⏳ เงินโอนค้างตรวจจากวันก่อน ' || (n_pend_all - n_pend) || ' รายการ ' || to_char(s_pend_all - s_pend, 'FM999,999,990.00') || ' บาท' else '' end
      || E'\n• ยอดค้างชำระทั้งหมด ' || to_char(s_debt, 'FM999,999,990.00') || ' บาท'
      || case when n_exp > 0 then E'\n• รายจ่ายร้าน ' || n_exp || ' รายการ ' || to_char(s_exp, 'FM999,999,990.00') || ' บาท'
              || case when s_exp_dr > 0 then ' (จ่ายจากลิ้นชัก ' || to_char(s_exp_dr, 'FM999,999,990.00') || ')' else '' end else '' end
      || case when n_rm > 0 then E'\n• เงินนำส่ง ' || n_rm || ' รายการ ' || to_char(s_rm, 'FM999,999,990.00') || ' บาท' else '' end
      || case when s_out_owner > 0 then E'\n• เจ้าของเก็บเงินสด ' || to_char(s_out_owner, 'FM999,999,990.00') || ' บาท' else '' end
      || case when s_out_bank > 0 then E'\n• นำเงินสดฝากธนาคาร ' || to_char(s_out_bank, 'FM999,999,990.00') || ' บาท' else '' end
      || case when s_out_adv > 0 then E'\n• พนักงานเบิกล่วงหน้า ' || to_char(s_out_adv, 'FM999,999,990.00') || ' บาท' else '' end
      || case when s_out_oth > 0 then E'\n• นำเงินสดออกอื่นๆ ' || to_char(s_out_oth, 'FM999,999,990.00') || ' บาท' else '' end
      || case when n_req > 0 then E'\n• 📝 คำขอเบิกรออนุมัติ ' || n_req || ' รายการ ' || to_char(s_req, 'FM999,999,990.00') || ' บาท' else '' end
      || E'\n• ปิดยอด: ' || case when n_staff = 0 and n_close = 0 then 'ไม่มีการรับเงิน'
                               when n_close = 0 then '⚠️ ยังไม่ปิดยอด'
                               when n_close < n_staff then '⚠️ ปิดแล้ว ' || n_close || '/' || n_staff || ' คน'
                               else 'ปิดแล้ว' end
      || case when n_close > 0 and d_close < 0 then ' (เงินสดขาด ' || to_char(-d_close, 'FM999,999,990.00') || ')'
              when n_close > 0 and d_close > 0 then ' (เงินสดเกิน ' || to_char(d_close, 'FM999,999,990.00') || ')'
              when n_close > 0 then ' (เงินสดตรง)' else '' end
      || case when n_close > 0 and abs(s_close - (s_cash + s_tr + s_other)) > 0.004
              then E'\n• ⚠️ ยอดเปลี่ยนหลังปิดยอด (ตอนปิด ' || to_char(s_close, 'FM999,999,990.00') || ' / ตอนนี้ ' || to_char(s_cash + s_tr + s_other, 'FM999,999,990.00') || ') กรุณาตรวจในหน้าปิดยอด' else '' end
      || case when n_insp + n_pass + n_fail > 0 then E'\n• ตรวจสภาพ ' || n_insp || ' คัน'
              || case when n_pass + n_fail > 0 then ' (ลงผลในคิว: ผ่าน ' || n_pass || ' / ไม่ผ่าน ' || n_fail || ')' else '' end else '' end
      || case when n_late > 0 then E'\n• ⚠️ งานขนส่งเกินกำหนด ' || n_late || ' งาน' else '' end;
  end loop;

  select count(*) filter (where tax_exp between p_day + 1 and p_day + 7),
         count(*) filter (where prb_exp between p_day + 1 and p_day + 7)
    into n_tax, n_prb from vehicles;
  txt := txt || E'\n\n📅 อีก 7 วันข้างหน้า: ภาษีหมด ' || n_tax || ' คัน · พ.ร.บ.หมด ' || n_prb || ' คัน';
  return txt;
end $$;

revoke all on function public.daily_summary_text(date) from public, anon, authenticated;

-- ---------- 6) สำรองข้อมูล (ต่อจาก 26) ----------
create or replace function public._backup_make(p_kind text default 'auto') returns bigint
language plpgsql security definer set search_path = public as $$
declare t text; k text; cols text; d jsonb := '{}'; c jsonb := '{}'; sk jsonb := '[]'; arr jsonb; nid bigint;
  tabs text[][] := array[['branches','id','*'],['staff','user_id','user_id,username,full_name,role,branch_id,active,created_at'],
    ['customers','id','*'],['vehicles','id','*'],['bills','id','*'],['payments','id','*'],['bill_edits','id','*'],['dlt_jobs','bill_id','*'],
    ['bill_files','id','*'],['bill_requests','id','*'],['insp_queue','id','*'],['cash_closes','id','*'],['expenses','id','*'],['remits','id','*'],['cash_outs','id','*'],['exp_requests','id','*'],
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
                       'insp_queue','cash_closes','expenses','remits','cash_outs','exp_requests','app_settings','news','audit_log'];
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
