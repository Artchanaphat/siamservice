-- ตรอ.สยามเซอร์วิส : โครงสร้างฐานข้อมูล (Supabase / PostgreSQL)
-- วิธีใช้: Supabase > SQL Editor > New query > วางทั้งไฟล์ > Run (รันครั้งเดียว)
-- ลูกค้าและรถใช้ร่วมกันทุกสาขา ส่วนบิล การรับเงิน และ SMS แยกตามสาขา

-- ---------- สาขา ----------
create table public.branches (
  id         bigint generated always as identity primary key,
  code       text not null unique,              -- รหัสสั้น ใช้นำหน้าเลขบิล เช่น A, B
  name       text not null,
  address    text default '',
  phone      text default '',
  line_id    text default '',
  sms_credit integer not null default 0,
  active     boolean not null default true,
  created_at timestamptz not null default now()
);

-- ---------- ผู้ใช้ (ผูกกับ auth.users ของ Supabase) ----------
create table public.staff (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  username   text not null unique,
  full_name  text not null default '',
  role       text not null default 'staff' check (role in ('owner','head','staff')),
  branch_id  bigint references public.branches(id),   -- owner ไม่ต้องมีสาขา
  active     boolean not null default true,
  created_at timestamptz not null default now(),
  check (role = 'owner' or branch_id is not null)
);

-- ตัวช่วยเช็คสิทธิ์ (ใช้ใน RLS)
create or replace function public.my_role() returns text
language sql stable security definer set search_path = public as
$$ select role from staff where user_id = auth.uid() and active $$;

create or replace function public.my_branch() returns bigint
language sql stable security definer set search_path = public as
$$ select branch_id from staff where user_id = auth.uid() and active $$;

create or replace function public.can_see_branch(b bigint) returns boolean
language sql stable security definer set search_path = public as
$$ select coalesce(my_role() = 'owner' or my_branch() = b, false) $$;

-- ---------- ลูกค้า (ใช้ร่วมทุกสาขา) ----------
create table public.customers (
  id         bigint generated always as identity primary key,
  prefix     text default '',
  first_name text not null,
  last_name  text default '',
  tel        text default '',
  id_card    text default '',
  address    text default '',
  tumbol     text default '',
  amphoe     text default '',
  province   text default '',
  zipcode    text default '',
  short_note text default '',
  note       text default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index on public.customers (tel);
create index on public.customers (first_name, last_name);

-- ---------- รถ (ใช้ร่วมทุกสาขา) ----------
create table public.vehicles (
  id            bigint generated always as identity primary key,
  customer_id   bigint references public.customers(id),
  plate         text not null,                 -- เช่น 1กข 1234
  province      text not null default '',
  car_type      text not null default '',      -- รย.1, รย.3, รย.12 ...
  body          text default '',
  brand         text default '',
  model         text default '',
  color         text default '',
  chassis_no    text default '',
  engine_no     text default '',
  cc            integer,
  weight_kg     integer,
  reg_date      date,                          -- วันจดทะเบียน
  tax_exp       date,                          -- วันหมดอายุภาษี
  prb_exp       date,                          -- วันหมด พ.ร.บ.
  ins_exp       date,                          -- วันหมดประกันภาคสมัครใจ
  ins_company   text default '',
  k_exp         date,                          -- วันหมด พ.ร.บ.ขนส่ง
  note          text default '',
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  unique (plate, province)
);
create index on public.vehicles (tax_exp);
create index on public.vehicles (ins_exp);

-- ---------- บิล (แยกสาขา) ----------
create table public.bills (
  id          bigint generated always as identity primary key,
  branch_id   bigint not null references public.branches(id),
  bill_no     text not null unique,            -- เช่น A-690001 (สาขา-ปีพ.ศ.2หลัก-ลำดับ)
  bill_at     timestamptz not null default now(),
  customer_id bigint references public.customers(id),
  vehicle_id  bigint references public.vehicles(id),
  snapshot    jsonb not null default '{}',     -- ข้อมูลลูกค้า/รถ ณ วันออกบิล (ไว้พิมพ์ซ้ำ)
  items       jsonb not null default '[]',     -- [{name, amount, note}]
  ins_premium numeric(12,2) not null default 0,
  discount    numeric(12,2) not null default 0,
  total       numeric(12,2) not null default 0,
  pick_date   date,                            -- วันนัดรับ
  note        text default '',
  status      text not null default 'open' check (status in ('open','paid','void')),
  created_by  uuid references auth.users(id) default auth.uid(),
  created_at  timestamptz not null default now()
);
create index on public.bills (branch_id, bill_at desc);
create index on public.bills (vehicle_id);

-- รับเงิน (หนึ่งบิลรับได้หลายครั้ง เช่น ผ่อนประกัน)
create table public.payments (
  id         bigint generated always as identity primary key,
  bill_id    bigint not null references public.bills(id) on delete cascade,
  branch_id  bigint not null references public.branches(id),
  paid_at    timestamptz not null default now(),
  amount     numeric(12,2) not null check (amount > 0),
  method     text not null default 'เงินสด' check (method in ('เงินสด','โอน','บัตร','อื่นๆ')),
  note       text default '',
  created_by uuid references auth.users(id) default auth.uid()
);
create index on public.payments (branch_id, paid_at desc);
create index on public.payments (bill_id);

-- ประวัติการแก้ไขบิล
create table public.bill_edits (
  id         bigint generated always as identity primary key,
  bill_id    bigint not null references public.bills(id) on delete cascade,
  edited_at  timestamptz not null default now(),
  what       text not null,
  before     jsonb,
  after      jsonb,
  edited_by  uuid references auth.users(id) default auth.uid()
);

-- SMS ที่ส่ง
create table public.sms_log (
  id         bigint generated always as identity primary key,
  branch_id  bigint not null references public.branches(id),
  vehicle_id bigint references public.vehicles(id),
  kind       text not null check (kind in ('tax','ins','prb','k','other')),
  tel        text not null,
  message    text not null,
  status     text not null default 'queued',
  sent_by    uuid references auth.users(id) default auth.uid(),
  sent_at    timestamptz not null default now()
);

-- ข่าวสาร (owner โพสต์ ทุกคนอ่าน)
create table public.news (
  id         bigint generated always as identity primary key,
  title      text not null,
  body       text not null default '',
  posted_by  uuid references auth.users(id) default auth.uid(),
  posted_at  timestamptz not null default now()
);

-- ---------- เลขบิลอัตโนมัติ: <รหัสสาขา>-<ปีพ.ศ. 2 หลัก><ลำดับ 4 หลัก> ----------
create table public.bill_counters (
  branch_id bigint not null references public.branches(id),
  be_year   integer not null,
  last_no   integer not null default 0,
  primary key (branch_id, be_year)
);

create or replace function public.set_bill_no() returns trigger
language plpgsql security definer set search_path = public as $$
declare y int := extract(year from (new.bill_at at time zone 'Asia/Bangkok'))::int + 543; n int; c text;
begin
  if new.bill_no is not null and new.bill_no <> '' then return new; end if;
  insert into bill_counters (branch_id, be_year, last_no) values (new.branch_id, y, 1)
    on conflict (branch_id, be_year) do update set last_no = bill_counters.last_no + 1
    returning last_no into n;
  select code into c from branches where id = new.branch_id;
  new.bill_no := c || '-' || lpad((y % 100)::text, 2, '0') || lpad(n::text, 4, '0');
  return new;
end $$;
create trigger bills_set_no before insert on public.bills
  for each row execute function public.set_bill_no();

-- อัปเดตสถานะบิลเมื่อรับเงินครบ
create or replace function public.refresh_bill_status() returns trigger
language plpgsql security definer set search_path = public as $$
declare bid bigint := coalesce(new.bill_id, old.bill_id); paid numeric;
begin
  select coalesce(sum(amount),0) into paid from payments where bill_id = bid;
  update bills set status = case when status = 'void' then 'void'
                                 when paid >= total then 'paid' else 'open' end
   where id = bid;
  return null;
end $$;
create trigger payments_refresh after insert or update or delete on public.payments
  for each row execute function public.refresh_bill_status();

-- updated_at อัตโนมัติ
create or replace function public.touch() returns trigger language plpgsql as
$$ begin new.updated_at := now(); return new; end $$;
create trigger customers_touch before update on public.customers for each row execute function public.touch();
create trigger vehicles_touch  before update on public.vehicles  for each row execute function public.touch();

-- ---------- สิทธิ์ (Row Level Security) ----------
alter table public.branches      enable row level security;
alter table public.staff         enable row level security;
alter table public.customers     enable row level security;
alter table public.vehicles      enable row level security;
alter table public.bills         enable row level security;
alter table public.payments      enable row level security;
alter table public.bill_edits    enable row level security;
alter table public.sms_log       enable row level security;
alter table public.news          enable row level security;
alter table public.bill_counters enable row level security;  -- ไม่มี policy = ไม่มีใครเข้าตรงได้

-- สาขา: ทุกคนที่ล็อกอินเห็นรายชื่อสาขา, owner แก้ได้
create policy br_read  on public.branches for select to authenticated using (my_role() is not null);
create policy br_write on public.branches for all    to authenticated using (my_role() = 'owner') with check (my_role() = 'owner');

-- พนักงาน: เห็นตัวเอง, หัวหน้าเห็นคนในสาขา, owner จัดการได้ทั้งหมด
create policy st_read on public.staff for select to authenticated
  using (user_id = auth.uid() or my_role() = 'owner' or (my_role() = 'head' and branch_id = my_branch()));
create policy st_write on public.staff for all to authenticated
  using (my_role() = 'owner') with check (my_role() = 'owner');

-- ลูกค้า / รถ: ใช้ร่วมทุกสาขา, พนักงานเพิ่ม/แก้ได้, ลบได้เฉพาะ owner
create policy cu_read  on public.customers for select to authenticated using (my_role() is not null);
create policy cu_ins   on public.customers for insert to authenticated with check (my_role() is not null);
create policy cu_upd   on public.customers for update to authenticated using (my_role() is not null);
create policy cu_del   on public.customers for delete to authenticated using (my_role() = 'owner');
create policy ve_read  on public.vehicles  for select to authenticated using (my_role() is not null);
create policy ve_ins   on public.vehicles  for insert to authenticated with check (my_role() is not null);
create policy ve_upd   on public.vehicles  for update to authenticated using (my_role() is not null);
create policy ve_del   on public.vehicles  for delete to authenticated using (my_role() = 'owner');

-- บิล: เห็น/เปิดบิลได้เฉพาะสาขาตัวเอง (owner ทุกสาขา), แก้ได้ head/owner, ลบได้เฉพาะ owner
create policy bi_read on public.bills for select to authenticated using (can_see_branch(branch_id));
create policy bi_ins  on public.bills for insert to authenticated with check (can_see_branch(branch_id));
create policy bi_upd  on public.bills for update to authenticated
  using (can_see_branch(branch_id) and my_role() in ('owner','head'))
  with check (can_see_branch(branch_id));
create policy bi_del  on public.bills for delete to authenticated using (my_role() = 'owner');

-- รับเงิน: พนักงานรับเงินได้ในสาขาตัวเอง, แก้/ลบเฉพาะ owner
create policy pa_read on public.payments for select to authenticated using (can_see_branch(branch_id));
create policy pa_ins  on public.payments for insert to authenticated
  with check (can_see_branch(branch_id)
              and exists (select 1 from bills b where b.id = bill_id and b.branch_id = payments.branch_id));
create policy pa_upd  on public.payments for update to authenticated using (my_role() = 'owner');
create policy pa_del  on public.payments for delete to authenticated using (my_role() = 'owner');

-- ประวัติแก้ไข: เห็นตามสาขาของบิล, เพิ่มได้, ห้ามแก้/ลบ
create policy be_read on public.bill_edits for select to authenticated
  using (exists (select 1 from bills b where b.id = bill_id and can_see_branch(b.branch_id)));
create policy be_ins  on public.bill_edits for insert to authenticated
  with check (exists (select 1 from bills b where b.id = bill_id and can_see_branch(b.branch_id)));

-- SMS: ตามสาขา
create policy sm_read on public.sms_log for select to authenticated using (can_see_branch(branch_id));
create policy sm_ins  on public.sms_log for insert to authenticated with check (can_see_branch(branch_id));

-- ข่าวสาร: ทุกคนอ่าน, owner เขียน
create policy nw_read  on public.news for select to authenticated using (my_role() is not null);
create policy nw_write on public.news for all    to authenticated using (my_role() = 'owner') with check (my_role() = 'owner');

-- ---------- ข้อมูลเริ่มต้น: 2 สาขา (แก้ชื่อทีหลังได้) ----------
insert into public.branches (code, name) values ('A', 'สาขา 1'), ('B', 'สาขา 2');
