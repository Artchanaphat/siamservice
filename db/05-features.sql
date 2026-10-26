-- ตรอ.สยามเซอร์วิส : ปิดยอดประจำวัน / คิวตรวจสภาพ / ตั้งค่าระบบ / พร้อมเพย์ + ข้อมูลร้าน
-- รันครั้งเดียว หลัง 04-dlt.sql (รันซ้ำได้ ไม่เสียข้อมูล)

-- ---------- ข้อมูลร้าน 2 สาขา + เลขพร้อมเพย์ ----------
alter table public.branches add column if not exists promptpay text not null default '';
update public.branches set name = 'สยามเซอร์วิส',
       address = '60 ซอยพนาสณฑ์ ต.บางนาค อ.เมืองนราธิวาส จ.นราธิวาส 96000', phone = '098-672-1018'
 where code = 'A';
update public.branches set name = 'สยามเซอร์วิส 2',
       address = '98 ต.ลำภู อ.เมืองนราธิวาส จ.นราธิวาส 96000', phone = '098-106-1655'
 where code = 'B';

-- ---------- ปิดยอดเงินประจำวัน (1 แถว ต่อ สาขา / วัน / พนักงานที่รับเงิน) ----------
create table if not exists public.cash_closes (
  id             bigint generated always as identity primary key,
  branch_id      bigint not null references public.branches(id),
  close_date     date not null,
  staff_name     text not null,
  cash           numeric(12,2) not null default 0,   -- ยอดเงินสดตามระบบ
  transfer       numeric(12,2) not null default 0,
  card           numeric(12,2) not null default 0,
  other          numeric(12,2) not null default 0,
  counted_cash   numeric(12,2),                      -- เงินสดที่นับได้จริง (ว่าง = ยังไม่นับ)
  note           text not null default '',
  closed_by_name text not null default '',
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  unique (branch_id, close_date, staff_name)
);
drop trigger if exists cash_closes_touch on public.cash_closes;
create trigger cash_closes_touch before update on public.cash_closes for each row execute function public.touch();

alter table public.cash_closes enable row level security;
drop policy if exists cc_read on public.cash_closes;
drop policy if exists cc_ins  on public.cash_closes;
drop policy if exists cc_upd  on public.cash_closes;
drop policy if exists cc_del  on public.cash_closes;
create policy cc_read on public.cash_closes for select to authenticated using (can_see_branch(branch_id));
create policy cc_ins  on public.cash_closes for insert to authenticated with check (can_see_branch(branch_id));
create policy cc_upd  on public.cash_closes for update to authenticated
  using (can_see_branch(branch_id)) with check (can_see_branch(branch_id));
create policy cc_del  on public.cash_closes for delete to authenticated using (my_role() = 'owner');
grant select, insert, update, delete on public.cash_closes to authenticated;

-- ---------- คิวตรวจสภาพหน้าลาน ----------
create table if not exists public.insp_queue (
  id              bigint generated always as identity primary key,
  branch_id       bigint not null references public.branches(id),
  plate           text not null,
  province        text not null default '',
  car_type        text not null default '',
  cust_name       text not null default '',
  tel             text not null default '',
  status          text not null default 'wait'
                  check (status in ('wait','check','pass','fail')),  -- รอตรวจ / กำลังตรวจ / ผ่าน / ไม่ผ่าน
  note            text not null default '',
  billed          boolean not null default false,
  created_at      timestamptz not null default now(),
  started_at      timestamptz,
  finished_at     timestamptz,
  updated_by_name text not null default '',
  updated_at      timestamptz not null default now()
);
create index if not exists insp_queue_branch_created on public.insp_queue (branch_id, created_at);
drop trigger if exists insp_queue_touch on public.insp_queue;
create trigger insp_queue_touch before update on public.insp_queue for each row execute function public.touch();

alter table public.insp_queue enable row level security;
drop policy if exists iq_read on public.insp_queue;
drop policy if exists iq_ins  on public.insp_queue;
drop policy if exists iq_upd  on public.insp_queue;
drop policy if exists iq_del  on public.insp_queue;
create policy iq_read on public.insp_queue for select to authenticated using (can_see_branch(branch_id));
create policy iq_ins  on public.insp_queue for insert to authenticated with check (can_see_branch(branch_id));
create policy iq_upd  on public.insp_queue for update to authenticated
  using (can_see_branch(branch_id)) with check (can_see_branch(branch_id));
create policy iq_del  on public.insp_queue for delete to authenticated using (can_see_branch(branch_id));
grant select, insert, update, delete on public.insp_queue to authenticated;

-- ---------- ตั้งค่าระบบ (ค่าบริการ ยี่ห้อรถ บริษัทประกัน ฯลฯ) ----------
-- พนักงานทุกคนอ่านได้ แก้ได้เฉพาะเจ้าของร้าน
create table if not exists public.app_settings (
  key             text primary key,
  value           jsonb not null default '{}'::jsonb,
  updated_by_name text not null default '',
  updated_at      timestamptz not null default now()
);
drop trigger if exists app_settings_touch on public.app_settings;
create trigger app_settings_touch before update on public.app_settings for each row execute function public.touch();

alter table public.app_settings enable row level security;
drop policy if exists as_read on public.app_settings;
drop policy if exists as_ins  on public.app_settings;
drop policy if exists as_upd  on public.app_settings;
drop policy if exists as_del  on public.app_settings;
create policy as_read on public.app_settings for select to authenticated using (my_role() is not null);
create policy as_ins  on public.app_settings for insert to authenticated with check (my_role() = 'owner');
create policy as_upd  on public.app_settings for update to authenticated
  using (my_role() = 'owner') with check (my_role() = 'owner');
create policy as_del  on public.app_settings for delete to authenticated using (my_role() = 'owner');
grant select, insert, update, delete on public.app_settings to authenticated;
