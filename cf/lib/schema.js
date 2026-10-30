// โครงฐานข้อมูล D1 — สร้างให้อัตโนมัติตอนเรียก API ครั้งแรก (ไม่ต้องรัน SQL เอง)
// เพิ่มตาราง/ช่องใหม่: เพิ่มคำสั่งท้ายรายการ MIGRATIONS แล้วเพิ่มเลข VERSION
export const VERSION=1;
export const SCHEMA=`-- cf/schema.sql : โครงฐานข้อมูล Cloudflare D1 (SQLite) แปลงจาก Supabase SQL 01–30
-- ชนิดข้อมูล: jsonb -> TEXT (JSON), boolean -> INTEGER 0/1, timestamptz -> TEXT ISO (UTC, ลงท้าย Z), date -> TEXT YYYY-MM-DD, numeric -> REAL
-- รันซ้ำได้ (create if not exists)

create table if not exists branches (
  id integer primary key autoincrement, code text not null unique, name text not null, address text not null default '', phone text not null default '',
  line_id text not null default '', sms_credit integer not null default 0, active integer not null default 1, promptpay text not null default '',
  created_at text not null default (strftime('%Y-%m-%dT%H:%M:%fZ','now')));

create table if not exists staff (
  user_id text primary key, username text not null unique, full_name text not null default '', role text not null default 'staff' check (role in ('owner','head','staff')),
  branch_id integer references branches(id), active integer not null default 1, avatar_path text, pw_hash text,
  created_at text not null default (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  check (role = 'owner' or branch_id is not null));

-- ล็อกอิน: เก็บเฉพาะค่าแฮชของโทเคน
create table if not exists sessions (
  token_hash text primary key, user_id text not null references staff(user_id) on delete cascade,
  created_at text not null default (strftime('%Y-%m-%dT%H:%M:%fZ','now')), expires_at text not null, last_seen text);
create index if not exists sessions_user on sessions(user_id);

-- รหัสลับ LINE/SMS (อ่านได้เฉพาะฝั่งเซิร์ฟเวอร์ ไม่มีทางอ่านผ่าน API)
create table if not exists secrets (name text primary key, value text not null default '', updated_at text not null default (strftime('%Y-%m-%dT%H:%M:%fZ','now')));

create table if not exists customers (
  id integer primary key autoincrement, prefix text not null default '', first_name text not null, last_name text not null default '', tel text not null default '',
  id_card text not null default '', address text not null default '', tumbol text not null default '', amphoe text not null default '', province text not null default '',
  zipcode text not null default '', short_note text not null default '', note text not null default '',
  created_at text not null default (strftime('%Y-%m-%dT%H:%M:%fZ','now')), updated_at text not null default (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  line_user_id text, line_code text unique, line_linked_at text);
create index if not exists customers_tel on customers(tel);

create table if not exists vehicles (
  id integer primary key autoincrement, customer_id integer references customers(id), plate text not null, province text not null default '', car_type text not null default '',
  body text not null default '', brand text not null default '', model text not null default '', color text not null default '', chassis_no text not null default '',
  engine_no text not null default '', cc integer, weight_kg integer, reg_date text, tax_exp text, prb_exp text, ins_exp text, ins_company text not null default '',
  k_exp text, note text not null default '', prb_company text not null default '',
  created_at text not null default (strftime('%Y-%m-%dT%H:%M:%fZ','now')), updated_at text not null default (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  unique (plate, province));
create index if not exists vehicles_customer on vehicles(customer_id);

create table if not exists bill_counters (branch_id integer not null, be_year integer not null, last_no integer not null default 0, primary key (branch_id, be_year));

create table if not exists bills (
  id integer primary key autoincrement, branch_id integer not null references branches(id), bill_no text unique,
  bill_at text not null default (strftime('%Y-%m-%dT%H:%M:%fZ','now')), customer_id integer references customers(id), vehicle_id integer references vehicles(id),
  snapshot text not null default '{}', items text not null default '[]', ins_premium real not null default 0, discount real not null default 0, total real not null default 0,
  pick_date text, note text not null default '', status text not null default 'open' check (status in ('open','paid','void')), created_by text,
  created_at text not null default (strftime('%Y-%m-%dT%H:%M:%fZ','now')), client_key text unique, files_pending text not null default '[]', refund_total real not null default 0,
  void_reason text, void_by text, void_approved_by text, void_at text, delivered_at text, delivered_by text,
  insp_result text check (insp_result in ('pass','fail')), insp_at text, insp_by text, insp_reason text, insp_retest text, insp_note text);
create index if not exists bills_branch_at on bills(branch_id, bill_at);
create index if not exists bills_vehicle on bills(vehicle_id);
create index if not exists bills_status on bills(branch_id, status);

create table if not exists payments (
  id integer primary key autoincrement, bill_id integer not null references bills(id), branch_id integer not null, paid_at text not null default (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  amount real not null check (amount > 0), method text not null default 'เงินสด', note text not null default '', created_by text, by_name text not null default '',
  verified integer not null default 1, verified_by text, verified_at text, client_key text unique, rejected integer not null default 0, reject_reason text, rejected_by text, rejected_at text,
  kind text not null default 'pay' check (kind in ('pay','refund')), request_id integer);
create index if not exists payments_bill on payments(bill_id);
create index if not exists payments_branch_at on payments(branch_id, paid_at);

create table if not exists bill_edits (
  id integer primary key autoincrement, bill_id integer not null references bills(id), edited_at text not null default (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  what text, before text, after text, edited_by text, by_name text not null default '');
create index if not exists bill_edits_bill on bill_edits(bill_id);

create table if not exists dlt_jobs (
  bill_id integer primary key references bills(id), branch_id integer not null, status text not null default 'received' check (status in ('received','submitted','plate','done')),
  cert_no text not null default '', receipt_no text not null default '', note text not null default '', submitted_at text, plate_at text, done_at text,
  updated_by_name text not null default '', updated_at text not null default (strftime('%Y-%m-%dT%H:%M:%fZ','now')));

create table if not exists bill_files (
  id integer primary key autoincrement, bill_id integer not null references bills(id), branch_id integer not null, kind text check (kind in ('image','pdf')), path text not null unique,
  file_name text not null default '', size_bytes integer, by_name text, created_at text not null default (strftime('%Y-%m-%dT%H:%M:%fZ','now')));
create index if not exists bill_files_bill on bill_files(bill_id);

create table if not exists bill_requests (
  id integer primary key autoincrement, bill_id integer not null references bills(id), branch_id integer not null, kind text not null check (kind in ('void','refund')),
  amount real not null default 0, method text not null default 'เงินสด', reason text, requested_by text not null default '', requested_uid text,
  requested_at text not null default (strftime('%Y-%m-%dT%H:%M:%fZ','now')), status text not null default 'pending' check (status in ('pending','approved','rejected')),
  decided_by text, decided_at text, decide_note text);
create unique index if not exists bill_requests_one_pending on bill_requests(bill_id) where status = 'pending';

create table if not exists insp_queue (
  id integer primary key autoincrement, branch_id integer not null, plate text not null, province text not null default '', car_type text not null default '',
  cust_name text not null default '', tel text not null default '', status text not null default 'wait' check (status in ('wait','check','pass','fail')),
  note text not null default '', billed integer not null default 0, created_at text not null default (strftime('%Y-%m-%dT%H:%M:%fZ','now')), started_at text, finished_at text,
  updated_by_name text not null default '', updated_at text not null default (strftime('%Y-%m-%dT%H:%M:%fZ','now')), bill_id integer unique, retest_date text);
create index if not exists insp_queue_branch on insp_queue(branch_id, created_at);

create table if not exists cash_closes (
  id integer primary key autoincrement, branch_id integer not null, close_date text not null, staff_name text not null, cash real not null default 0, transfer real not null default 0,
  card real not null default 0, other real not null default 0, counted_cash real, note text not null default '', closed_by_name text not null default '',
  created_at text not null default (strftime('%Y-%m-%dT%H:%M:%fZ','now')), updated_at text not null default (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  float_cash real not null default 0, cash_out real not null default 0, unique (branch_id, close_date, staff_name));

create table if not exists close_acks (branch_id integer not null, close_date text not null, ack_by text not null default '', ack_note text not null default '',
  ack_at text not null default (strftime('%Y-%m-%dT%H:%M:%fZ','now')), primary key (branch_id, close_date));

create table if not exists expenses (
  id integer primary key autoincrement, branch_id integer not null, exp_date text not null, category text not null default 'อื่นๆ', amount real not null check (amount > 0),
  note text not null default '', by_name text not null default '', created_at text not null default (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  paid_from text not null default '', drawer_staff text not null default '', photo text not null default '' check (length(photo) <= 600000));
create index if not exists expenses_branch_date on expenses(branch_id, exp_date);

create table if not exists remits (
  id integer primary key autoincrement, branch_id integer not null, remit_date text not null, kind text not null default 'tax' check (kind in ('tax','prb','ins','other')),
  payee text not null default '', amount real not null check (amount > 0), method text not null default '', note text not null default '', by_name text not null default '',
  created_at text not null default (strftime('%Y-%m-%dT%H:%M:%fZ','now')), drawer_staff text not null default '', photo text not null default '' check (length(photo) <= 600000));
create index if not exists remits_branch_date on remits(branch_id, remit_date);

create table if not exists cash_outs (
  id integer primary key autoincrement, branch_id integer not null, out_date text not null, kind text not null check (kind in ('owner','bank','advance','other')),
  person text not null default '', amount real not null check (amount > 0), paid_from text not null default 'drawer', drawer_staff text not null default '',
  note text not null default '', by_name text not null default '', settled_ym text not null default '', settled_by text not null default '',
  created_at text not null default (strftime('%Y-%m-%dT%H:%M:%fZ','now')));
create index if not exists cash_outs_branch_date on cash_outs(branch_id, out_date);

create table if not exists exp_requests (
  id integer primary key autoincrement, branch_id integer not null, req_date text not null default (date('now','+7 hours')), category text not null default '',
  amount real not null check (amount > 0), note text not null default '', photo text not null default '' check (length(photo) <= 600000), req_by text not null default '',
  req_uid text, status text not null default 'pending' check (status in ('pending','approved','rejected')), decided_by text not null default '', decided_at text,
  decide_note text not null default '', expense_id integer, created_at text not null default (strftime('%Y-%m-%dT%H:%M:%fZ','now')));

create table if not exists app_settings (key text primary key, value text not null default '{}', updated_by_name text not null default '',
  updated_at text not null default (strftime('%Y-%m-%dT%H:%M:%fZ','now')));

create table if not exists news (id integer primary key autoincrement, title text not null, body text not null default '', posted_by text,
  posted_at text not null default (strftime('%Y-%m-%dT%H:%M:%fZ','now')));

create table if not exists audit_log (
  id integer primary key autoincrement, at text not null default (strftime('%Y-%m-%dT%H:%M:%fZ','now')), user_id text, user_name text not null default '',
  branch_id integer, tbl text, action text, row_id text, old_data text, new_data text);
create index if not exists audit_log_at on audit_log(at);

create table if not exists line_reminders (vehicle_id integer not null, kind text not null, exp_date text not null, days integer not null,
  sent_at text not null default (strftime('%Y-%m-%dT%H:%M:%fZ','now')), primary key (vehicle_id, kind, exp_date, days));

create table if not exists sms_sent (
  id integer primary key autoincrement, branch_id integer, vehicle_id integer, kind text not null default 'other', msisdn text, message text, ok integer, credit real,
  detail text, by_name text, sent_at text not null default (strftime('%Y-%m-%dT%H:%M:%fZ','now')));

-- ซิงก์ข้ามเครื่อง (แทน Supabase Realtime): ทุกการเขียนเพิ่มแถวที่นี่ หน้าเว็บถามทุก ~10 วินาที
create table if not exists changes (seq integer primary key autoincrement, at text not null default (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  tbl text not null, row_id text, branch_id integer, bill_id integer);

-- สำรองอัตโนมัติ: ตัวไฟล์เก็บใน R2 (siam-files/backups/) ตารางนี้เก็บแค่รายการ
create table if not exists backup_snapshots (id integer primary key autoincrement, created_at text not null default (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  kind text not null default 'auto' check (kind in ('auto','manual')), size_bytes integer, counts text not null default '{}', skipped text not null default '[]', r2_key text);
`;
export const MIGRATIONS=[];
const stmts=s=>s.split('\n').filter(l=>!/^\s*--/.test(l)).join('\n').split(/;\s*\n/).map(x=>x.trim().replace(/;$/,'')).filter(Boolean);
let ready=false;
export async function migrate(env){if(ready)return;
  let v=0;try{v=+(await env.DB.prepare(`select value from secrets where name='schema_v'`).first('value'))||0}catch(_){}
  if(v<VERSION){if(v<1)await env.DB.batch(stmts(SCHEMA).map(x=>env.DB.prepare(x)));
    for(let i=Math.max(v,1);i<VERSION;i++)await env.DB.batch(stmts(MIGRATIONS[i-1]).map(x=>env.DB.prepare(x)));
    await env.DB.prepare(`insert into secrets (name,value) values ('schema_v',?) on conflict(name) do update set value=excluded.value`).bind(String(VERSION)).run()}
  ready=true}
