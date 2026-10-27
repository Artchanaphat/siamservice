-- 15-void-refund.sql : ยกเลิกบิล / คืนเงิน แบบขออนุมัติ + ส่งมอบเอกสาร (รันหลัง 14, รันซ้ำได้)
-- ขั้นตอน: พนักงานยื่นคำขอ (ระบุเหตุผล) -> เจ้าของร้าน/หัวหน้าสาขาอนุมัติหรือไม่อนุมัติ
--   อนุมัติคืนเงิน   = เพิ่มรายการ "คืนเงิน" (ไม่ลบรายการรับเงินเดิม) และลดยอดบิลเท่ากับที่คืน
--   อนุมัติยกเลิกบิล = คืนเงินที่รับไว้ทั้งหมด แล้วตั้งสถานะบิลเป็น "ยกเลิก" (บิลยังอยู่ ไม่ถูกลบ)
-- หัวหน้าสาขาอนุมัติคำขอของตัวเองไม่ได้ (เจ้าของร้านอนุมัติได้)
-- รายงาน: ยอดบิล = total - refund_total, เงินรับ = รับ - คืน, บิลยกเลิกไม่นับยอด

-- ---------- คอลัมน์ใหม่ ----------
alter table public.payments add column if not exists kind text not null default 'pay';
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'payments_kind_check') then
    alter table public.payments add constraint payments_kind_check check (kind in ('pay','refund'));
  end if;
end $$;
alter table public.payments add column if not exists request_id bigint;
alter table public.bills add column if not exists refund_total     numeric(12,2) not null default 0;
alter table public.bills add column if not exists void_reason      text;
alter table public.bills add column if not exists void_by          text;
alter table public.bills add column if not exists void_approved_by text;
alter table public.bills add column if not exists void_at          timestamptz;
alter table public.bills add column if not exists delivered_at     timestamptz;
alter table public.bills add column if not exists delivered_by     text;

-- ---------- คำขอยกเลิก / คืนเงิน ----------
create table if not exists public.bill_requests (
  id            bigint generated always as identity primary key,
  bill_id       bigint not null references public.bills(id),
  branch_id     bigint not null references public.branches(id),
  kind          text not null check (kind in ('void','refund')),
  amount        numeric(12,2) not null default 0,
  method        text not null default 'เงินสด',
  reason        text not null,
  requested_by  text not null default '',
  requested_uid uuid default auth.uid(),
  requested_at  timestamptz not null default now(),
  status        text not null default 'pending' check (status in ('pending','approved','rejected')),
  decided_by    text,
  decided_at    timestamptz,
  decide_note   text
);
create index if not exists bill_requests_bill on public.bill_requests (bill_id);
create index if not exists bill_requests_pending on public.bill_requests (branch_id) where status = 'pending';
create unique index if not exists bill_requests_one_pending on public.bill_requests (bill_id) where status = 'pending';
alter table public.bill_requests enable row level security;
drop policy if exists br_req_read on public.bill_requests;
create policy br_req_read on public.bill_requests for select to authenticated using (can_see_branch(branch_id));
grant select on public.bill_requests to authenticated;   -- เพิ่ม/แก้ผ่านฟังก์ชันด้านล่างเท่านั้น

-- รายการคืนเงินสร้างได้ผ่านการอนุมัติเท่านั้น (พนักงานเพิ่มเองโดยตรงไม่ได้)
drop policy if exists pa_ins on public.payments;
create policy pa_ins on public.payments for insert to authenticated
  with check (can_see_branch(branch_id) and kind = 'pay'
              and exists (select 1 from bills b where b.id = bill_id and b.branch_id = payments.branch_id));

-- ยอดสุทธิ / สถานะบิล / การรับเงิน ที่หักคืนเงิน อยู่ใน 14-safe-bills.sql แล้ว

-- ---------- ยื่นคำขอ ----------
create or replace function public.request_bill_action(p_bill bigint, p_kind text, p_amount numeric, p_method text, p_reason text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare b bills; who text; paid numeric; rid bigint;
begin
  if my_role() is null then raise exception 'ไม่มีสิทธิ์ใช้งาน'; end if;
  if p_kind not in ('void','refund') then raise exception 'ประเภทคำขอไม่ถูกต้อง'; end if;
  if coalesce(trim(p_reason),'') = '' then raise exception 'กรุณาระบุเหตุผล'; end if;
  select * into b from bills where id = p_bill for update;
  if not found or not can_see_branch(b.branch_id) then raise exception 'ไม่พบบิล หรือไม่มีสิทธิ์'; end if;
  if b.status = 'void' then raise exception 'บิลนี้ถูกยกเลิกไปแล้ว'; end if;
  if exists (select 1 from bill_requests where bill_id = p_bill and status = 'pending') then
    raise exception 'บิลนี้มีคำขอที่รออนุมัติอยู่แล้ว';
  end if;
  if exists (select 1 from payments where bill_id = p_bill and kind = 'pay' and not verified and not rejected) then
    raise exception 'บิลนี้มีเงินโอนรอตรวจสอบ กรุณายืนยันหรือปฏิเสธเงินโอนก่อน';
  end if;
  paid := bill_net_paid(p_bill);
  if p_kind = 'refund' then
    if coalesce(p_amount,0) <= 0 then raise exception 'จำนวนเงินที่คืนต้องมากกว่า 0'; end if;
    if p_amount > paid + 0.005 then raise exception 'คืนเงินได้ไม่เกินยอดที่รับไว้ % บาท', paid; end if;
  end if;
  select full_name into who from staff where user_id = auth.uid();
  insert into bill_requests (bill_id, branch_id, kind, amount, method, reason, requested_by)
  values (p_bill, b.branch_id, p_kind, case when p_kind = 'void' then paid else p_amount end,
          coalesce(nullif(p_method,''),'เงินสด'), trim(p_reason), coalesce(who,''))
  returning id into rid;
  insert into bill_edits (bill_id, what, by_name)
  values (p_bill, case when p_kind = 'void' then 'ขอยกเลิกบิล' else 'ขอคืนเงิน ' || to_char(p_amount,'FM999,999,990.00') || ' บาท' end
                  || ' เหตุผล: ' || trim(p_reason), coalesce(who,''));
  return jsonb_build_object('id', rid, 'status', 'pending');
end $$;
revoke all on function public.request_bill_action(bigint, text, numeric, text, text) from public, anon;
grant execute on function public.request_bill_action(bigint, text, numeric, text, text) to authenticated;

-- ---------- อนุมัติ / ไม่อนุมัติ ----------
create or replace function public.decide_bill_action(p_id bigint, p_approve boolean, p_note text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r bill_requests; b bills; who text; paid numeric; amt numeric;
begin
  if my_role() not in ('owner','head') then raise exception 'อนุมัติได้เฉพาะเจ้าของร้าน/หัวหน้าสาขา'; end if;
  select * into r from bill_requests where id = p_id for update;
  if not found or not can_see_branch(r.branch_id) then raise exception 'ไม่พบคำขอ'; end if;
  if r.status <> 'pending' then raise exception 'คำขอนี้ดำเนินการไปแล้ว (%)', r.status; end if;
  if my_role() = 'head' and r.requested_uid = auth.uid() then raise exception 'หัวหน้าสาขาอนุมัติคำขอของตัวเองไม่ได้ ให้ผู้อื่นอนุมัติ'; end if;
  select full_name into who from staff where user_id = auth.uid(); who := coalesce(who,'');
  if not p_approve then
    update bill_requests set status = 'rejected', decided_by = who, decided_at = now(), decide_note = nullif(trim(coalesce(p_note,'')),'') where id = p_id;
    insert into bill_edits (bill_id, what, by_name) values (r.bill_id, 'ไม่อนุมัติคำขอ' || case when r.kind='void' then 'ยกเลิกบิล' else 'คืนเงิน' end
      || coalesce(' : ' || nullif(trim(coalesce(p_note,'')),''), ''), who);
    return jsonb_build_object('id', p_id, 'status', 'rejected');
  end if;
  select * into b from bills where id = r.bill_id for update;
  if b.status = 'void' then raise exception 'บิลนี้ถูกยกเลิกไปแล้ว'; end if;
  paid := bill_net_paid(r.bill_id);
  amt := case when r.kind = 'void' then paid else r.amount end;
  if amt > paid + 0.005 then raise exception 'ยอดที่รับไว้ตอนนี้ % บาท น้อยกว่ายอดที่ขอคืน', paid; end if;
  if amt > 0 then
    insert into payments (bill_id, branch_id, amount, method, by_name, verified, verified_by, verified_at, kind, request_id, note)
    values (r.bill_id, r.branch_id, amt, r.method, who, true, who, now(), 'refund', r.id, r.reason);
  end if;
  if r.kind = 'void' then
    update bills set status = 'void', void_reason = r.reason, void_by = r.requested_by, void_approved_by = who, void_at = now() where id = r.bill_id;
    update insp_queue set billed = false, bill_id = null where bill_id = r.bill_id;   -- คิวกลับมาเปิดบิลใหม่ได้
  else
    update bills set refund_total = refund_total + amt where id = r.bill_id;
    update bills set status = case when bill_net_paid(id) >= total - refund_total then 'paid' else 'open' end where id = r.bill_id;
  end if;
  update bill_requests set status = 'approved', amount = amt, decided_by = who, decided_at = now(), decide_note = nullif(trim(coalesce(p_note,'')),'') where id = p_id;
  insert into bill_edits (bill_id, what, by_name) values (r.bill_id,
    case when r.kind = 'void' then 'อนุมัติยกเลิกบิล' || case when amt > 0 then ' คืนเงิน ' || to_char(amt,'FM999,999,990.00') || ' บาท' else '' end
         else 'อนุมัติคืนเงิน ' || to_char(amt,'FM999,999,990.00') || ' บาท' end || ' (ขอโดย ' || r.requested_by || ')', who);
  return jsonb_build_object('id', p_id, 'status', 'approved', 'amount', amt);
end $$;
revoke all on function public.decide_bill_action(bigint, boolean, text) from public, anon;
grant execute on function public.decide_bill_action(bigint, boolean, text) to authenticated;

-- ---------- ส่งมอบเอกสารให้ลูกค้า ----------
create or replace function public.mark_delivered(p_bill bigint, p_undo boolean default false) returns jsonb
language plpgsql security definer set search_path = public as $$
declare br bigint; who text;
begin
  if my_role() is null then raise exception 'ไม่มีสิทธิ์ใช้งาน'; end if;
  select branch_id into br from bills where id = p_bill;
  if br is null or not can_see_branch(br) then raise exception 'ไม่พบบิล'; end if;
  select full_name into who from staff where user_id = auth.uid();
  if p_undo then
    if my_role() not in ('owner','head') then raise exception 'ยกเลิกการส่งมอบได้เฉพาะเจ้าของร้าน/หัวหน้าสาขา'; end if;
    update bills set delivered_at = null, delivered_by = null where id = p_bill;
    insert into bill_edits (bill_id, what, by_name) values (p_bill, 'ยกเลิกสถานะส่งมอบเอกสาร', coalesce(who,''));
    return jsonb_build_object('delivered_at', null);
  end if;
  update bills set delivered_at = coalesce(delivered_at, now()), delivered_by = coalesce(delivered_by, who) where id = p_bill;
  insert into bill_edits (bill_id, what, by_name) values (p_bill, 'ส่งมอบเอกสารให้ลูกค้าแล้ว', coalesce(who,''));
  return (select jsonb_build_object('delivered_at', delivered_at, 'delivered_by', delivered_by) from bills where id = p_bill);
end $$;
revoke all on function public.mark_delivered(bigint, boolean) from public, anon;
grant execute on function public.mark_delivered(bigint, boolean) to authenticated;

-- ---------- รายงานรายเดือน: หักยอดคืนเงิน (บิลยกเลิกไม่นับอยู่แล้ว) ----------
create or replace function public.monthly_stats(p_from date, p_pass text[])
returns table (branch_id bigint, ym text, bills int, cars int, total numeric, passthru numeric, expense numeric)
language sql stable security invoker set search_path = public as $$
  with b as (
    select bi.branch_id, to_char(bi.bill_at at time zone 'Asia/Bangkok', 'YYYY-MM') ym, bi.id, bi.total - bi.refund_total total,
           coalesce(bi.snapshot ->> 'plate', '') || '|' || coalesce(bi.snapshot ->> 'prov', '') car,
           (select coalesce(sum((it ->> 1)::numeric), 0) from jsonb_array_elements(bi.items) it where it ->> 0 = any (p_pass)) pass
      from bills bi
     where bi.status <> 'void' and bi.bill_at >= (p_from::timestamp at time zone 'Asia/Bangkok')),
  bm as (select b.branch_id, b.ym, count(*)::int bills, count(distinct car)::int cars, sum(b.total) total, sum(pass) passthru
           from b group by 1, 2),
  em as (select e.branch_id, to_char(e.exp_date, 'YYYY-MM') ym, sum(e.amount) expense
           from expenses e where e.exp_date >= p_from group by 1, 2)
  select coalesce(bm.branch_id, em.branch_id), coalesce(bm.ym, em.ym), coalesce(bm.bills, 0), coalesce(bm.cars, 0),
         coalesce(bm.total, 0), coalesce(bm.passthru, 0), coalesce(em.expense, 0)
    from bm full join em on em.branch_id = bm.branch_id and em.ym = bm.ym
   order by 2, 1
$$;
grant execute on function public.monthly_stats(date, text[]) to authenticated;

-- ---------- Realtime ----------
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'bill_requests') then
    alter publication supabase_realtime add table public.bill_requests;
  end if;
end $$;
