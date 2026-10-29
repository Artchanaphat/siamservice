-- 25: เงินนำส่ง (บันทึกการนำส่งเงินให้ขนส่ง/บริษัทประกัน) + เงินทอนตั้งต้นในหน้าปิดยอด
-- รันซ้ำได้
create table if not exists public.remits (
  id          bigint generated always as identity primary key,
  branch_id   bigint not null references public.branches(id),
  remit_date  date not null,
  kind        text not null default 'tax' check (kind in ('tax','prb','ins','other')),
  payee       text not null default '',
  amount      numeric(12,2) not null check (amount > 0),
  method      text not null default '',
  note        text not null default '',
  by_name     text not null default '',
  created_at  timestamptz not null default now()
);
create index if not exists remits_branch_date on public.remits (branch_id, remit_date);

alter table public.remits enable row level security;
-- พนักงานบันทึกของสาขาตัวเองได้ · ลบ/แก้ได้เฉพาะเจ้าของร้านและหัวหน้าสาขา (เหมือนรายจ่าย)
drop policy if exists rm_read on public.remits;
drop policy if exists rm_ins  on public.remits;
drop policy if exists rm_upd  on public.remits;
drop policy if exists rm_del  on public.remits;
create policy rm_read on public.remits for select to authenticated using (can_see_branch(branch_id));
create policy rm_ins  on public.remits for insert to authenticated with check (can_see_branch(branch_id));
create policy rm_upd  on public.remits for update to authenticated
  using (can_see_branch(branch_id) and my_role() in ('owner','head')) with check (can_see_branch(branch_id));
create policy rm_del  on public.remits for delete to authenticated
  using (can_see_branch(branch_id) and my_role() in ('owner','head'));
grant select, insert, update, delete on public.remits to authenticated;

-- บันทึกประวัติการใช้งาน (audit_log) เหมือนตารางอื่น
drop trigger if exists remits_audit on public.remits;
create trigger remits_audit after insert or update or delete on public.remits for each row execute function public.audit();

-- เงินทอนตั้งต้นในลิ้นชัก (ต่อพนักงานต่อวัน)
alter table public.cash_closes add column if not exists float_cash numeric(12,2) not null default 0;
