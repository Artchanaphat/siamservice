-- ตรอ.สยามเซอร์วิส : รายจ่ายร้าน / สรุปรายเดือน / เตือนลูกค้าทาง LINE อัตโนมัติ
-- รันครั้งเดียว หลัง 06-line-daily.sql (รันซ้ำได้)

-- ---------- รายจ่ายร้าน ----------
create table if not exists public.expenses (
  id         bigint generated always as identity primary key,
  branch_id  bigint not null references public.branches(id),
  exp_date   date not null,
  category   text not null default 'อื่นๆ',
  amount     numeric(12,2) not null check (amount > 0),
  note       text not null default '',
  by_name    text not null default '',
  created_at timestamptz not null default now()
);
create index if not exists expenses_branch_date on public.expenses (branch_id, exp_date);

alter table public.expenses enable row level security;
-- พนักงานบันทึกรายจ่ายของสาขาตัวเองได้ แก้/ลบได้เฉพาะเจ้าของร้านและหัวหน้าสาขา
drop policy if exists ex_read on public.expenses;
drop policy if exists ex_ins  on public.expenses;
drop policy if exists ex_upd  on public.expenses;
drop policy if exists ex_del  on public.expenses;
create policy ex_read on public.expenses for select to authenticated using (can_see_branch(branch_id));
create policy ex_ins  on public.expenses for insert to authenticated with check (can_see_branch(branch_id));
create policy ex_upd  on public.expenses for update to authenticated
  using (can_see_branch(branch_id) and my_role() in ('owner','head')) with check (can_see_branch(branch_id));
create policy ex_del  on public.expenses for delete to authenticated
  using (can_see_branch(branch_id) and my_role() in ('owner','head'));
grant select, insert, update, delete on public.expenses to authenticated;

-- ---------- สรุปรายเดือน (ทุกสาขาที่ผู้ใช้มีสิทธิ์เห็น ตาม RLS) ----------
-- p_pass = ชื่อรายการที่เป็นเงินนำส่ง (ภาษี พ.ร.บ. ประกัน) ไม่นับเป็นรายได้ร้าน
create or replace function public.monthly_stats(p_from date, p_pass text[])
returns table (branch_id bigint, ym text, bills int, cars int, total numeric, passthru numeric, expense numeric)
language sql stable security invoker set search_path = public as $$
  with b as (
    select bi.branch_id, to_char(bi.bill_at at time zone 'Asia/Bangkok', 'YYYY-MM') ym, bi.id, bi.total,
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

-- ---------- ผูก LINE ของลูกค้า ----------
alter table public.customers add column if not exists line_user_id   text;
alter table public.customers add column if not exists line_code      text unique;
alter table public.customers add column if not exists line_linked_at timestamptz;

-- รหัส 6 หลักของลูกค้า (พิมพ์เป็น QR บนใบเสร็จ) สร้างครั้งแรกที่ขอ
create or replace function public.line_code_for(p_customer bigint) returns text
language plpgsql security definer set search_path = public as $$
declare c text;
begin
  if my_role() is null then raise exception 'ไม่มีสิทธิ์'; end if;
  select line_code into c from customers where id = p_customer;
  if not found then raise exception 'ไม่พบลูกค้า'; end if;
  while c is null loop
    c := lpad((floor(random() * 1000000))::int::text, 6, '0');
    if exists (select 1 from customers where line_code = c) then c := null;
    else update customers set line_code = c where id = p_customer; end if;
  end loop;
  return c;
end $$;
revoke all on function public.line_code_for(bigint) from public, anon;
grant execute on function public.line_code_for(bigint) to authenticated;

-- ส่งข้อความตอบกลับ / ส่งหา 1 คน ผ่าน LINE (ใช้ token ใน Vault ชุดเดียวกับ 06)
create or replace function public.line_send(p_to text, p_text text, p_reply_token text default null) returns void
language plpgsql security definer set search_path = public as $$
declare tok text;
begin
  select decrypted_secret into tok from vault.decrypted_secrets where name = 'line_token';
  if coalesce(tok, '') = '' then raise exception 'ยังไม่ได้ใส่ line_token ใน Vault'; end if;
  perform net.http_post(
    url     := case when p_reply_token is null then 'https://api.line.me/v2/bot/message/push'
                    else 'https://api.line.me/v2/bot/message/reply' end,
    headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer ' || tok),
    body    := case when p_reply_token is null then jsonb_build_object('to', p_to) else jsonb_build_object('replyToken', p_reply_token) end
               || jsonb_build_object('messages', jsonb_build_array(jsonb_build_object('type', 'text', 'text', left(p_text, 4900)))));
end $$;
revoke all on function public.line_send(text, text, text) from public, anon, authenticated;

-- รับข้อความจาก LINE (Edge Function line-webhook เรียกใช้ หลังตรวจลายเซ็นแล้ว)
create or replace function public.line_event(p_user text, p_type text, p_text text, p_reply text) returns void
language plpgsql security definer set search_path = public as $$
declare code text := substring(coalesce(p_text, '') from '(?:^|\D)(\d{6})(?:\D|$)'); n int; cars text;
  linked boolean := exists (select 1 from customers where line_user_id = p_user);
begin
  if p_type = 'unfollow' then
    update customers set line_user_id = null, line_linked_at = null where line_user_id = p_user; return;
  end if;
  if p_type = 'follow' then
    perform line_send(p_user, 'ขอบคุณที่เพิ่มเพื่อน ตรอ.สยามเซอร์วิส ครับ' || E'\n' ||
      'ถ้าต้องการให้ร้านแจ้งเตือนก่อนภาษี / พ.ร.บ. หมดอายุ พิมพ์รหัส 6 หลักที่อยู่ใต้ QR บนใบเสร็จ ส่งมาในแชตนี้ได้เลยครับ', p_reply);
    return;
  end if;
  if p_type <> 'message' then return; end if;
  if code is null then
    if linked then return; end if;  -- ลูกค้าที่ผูกแล้วคุยกับแอดมินตามปกติ
    perform line_send(p_user, 'พิมพ์รหัส 6 หลักจากใบเสร็จ เพื่อรับการแจ้งเตือนก่อนภาษี / พ.ร.บ. หมดอายุ ครับ', p_reply);
    return;
  end if;
  update customers set line_user_id = p_user, line_linked_at = now() where line_code = code;
  get diagnostics n = row_count;
  if n = 0 then
    if linked then return; end if;
    perform line_send(p_user, 'ไม่พบรหัส ' || code || ' กรุณาตรวจรหัสบนใบเสร็จอีกครั้ง หรือโทรสอบถามร้านครับ', p_reply);
    return;
  end if;
  select string_agg(v.plate || ' ' || v.province, ', ') into cars
    from vehicles v join customers c on c.id = v.customer_id where c.line_code = code;
  perform line_send(p_user, '✅ ผูกบัญชีเรียบร้อย ร้านจะแจ้งเตือนก่อนภาษี / พ.ร.บ. หมดอายุ' ||
    coalesce(E'\nรถของคุณ: ' || cars, '') || E'\n(อย่าบล็อกหรือลบเพื่อน ไม่อย่างนั้นจะไม่ได้รับข้อความ)', p_reply);
end $$;
revoke all on function public.line_event(text, text, text, text) from public, anon, authenticated;
grant execute on function public.line_event(text, text, text, text) to service_role;

-- ---------- เตือนลูกค้าอัตโนมัติ ทุกวัน 09:00 น. ----------
create table if not exists public.line_reminders (
  vehicle_id bigint not null references public.vehicles(id) on delete cascade,
  kind       text not null,          -- tax / prb / ins
  exp_date   date not null,
  days       int not null,
  sent_at    timestamptz not null default now(),
  primary key (vehicle_id, kind, exp_date, days)
);
alter table public.line_reminders enable row level security;
drop policy if exists lr_read on public.line_reminders;
create policy lr_read on public.line_reminders for select to authenticated using (my_role() is not null);
grant select on public.line_reminders to authenticated;

create or replace function public.send_line_reminders(p_day date default (now() at time zone 'Asia/Bangkok')::date)
returns int language plpgsql security definer set search_path = public as $$
declare r record; dd int[]; n int := 0; br record; msg text;
begin
  select coalesce(array(select jsonb_array_elements_text(value -> 'line_days')::int), '{30,7}')
    into dd from app_settings where key = 'main';
  if dd is null or cardinality(dd) = 0 then dd := '{30,7}'; end if;
  for r in
    select v.id, v.plate, v.province, c.first_name, c.line_user_id, k.kind, k.exp, (k.exp - p_day) left_days
      from vehicles v join customers c on c.id = v.customer_id
      cross join lateral (values ('tax', v.tax_exp), ('prb', v.prb_exp), ('ins', v.ins_exp)) k(kind, exp)
     where c.line_user_id is not null and k.exp is not null and (k.exp - p_day) = any (dd)
  loop
    insert into line_reminders (vehicle_id, kind, exp_date, days) values (r.id, r.kind, r.exp, r.left_days)
      on conflict do nothing;
    continue when not found;
    -- ใช้ชื่อ/เบอร์ของสาขาที่ลูกค้ามาใช้บริการล่าสุด
    select b.name, b.phone into br from branches b
     where b.id = coalesce((select x.branch_id from bills x where x.vehicle_id = r.id order by x.bill_at desc limit 1),
                           (select min(id) from branches where active));
    msg := 'เรียนคุณ' || r.first_name || E'\n' ||
           case r.kind when 'tax' then 'ภาษีรถ' when 'prb' then 'พ.ร.บ. ของรถ' else 'ประกันภัยรถ' end ||
           ' ทะเบียน ' || r.plate || ' ' || r.province || ' จะหมดอายุวันที่ ' ||
           to_char(r.exp, 'DD/MM/') || (extract(year from r.exp)::int + 543) || ' (อีก ' || r.left_days || ' วัน)' || E'\n' ||
           'ต่อได้ที่ ตรอ.' || coalesce(br.name, 'สยามเซอร์วิส') || coalesce(' โทร ' || nullif(br.phone, ''), '') || ' ขอบคุณครับ';
    perform line_send(r.line_user_id, msg);
    n := n + 1;
  end loop;
  return n;
end $$;
revoke all on function public.send_line_reminders(date) from public, anon, authenticated;

select cron.schedule('siam-line-remind', '0 2 * * *', 'select public.send_line_reminders()');  -- 09:00 เวลาไทย

-- ---------- ประวัติการใช้งาน (ใครทำอะไร ที่สาขาไหน เมื่อไร) ----------
-- บันทึกโดย trigger ในฐานข้อมูล แก้หรือลบผ่านแอปไม่ได้ เจ้าของร้านดูได้คนเดียว
create table if not exists public.audit_log (
  id        bigint generated always as identity primary key,
  at        timestamptz not null default now(),
  user_id   uuid,
  user_name text not null default '',
  branch_id bigint,
  tbl       text not null,
  action    text not null,          -- insert / update / delete
  row_id    text,
  old_data  jsonb,
  new_data  jsonb
);
create index if not exists audit_log_at on public.audit_log (at desc);

create or replace function public.audit() returns trigger
language plpgsql security definer set search_path = public as $$
declare o jsonb; n jsonb; k text; oc jsonb := '{}'; nc jsonb := '{}'; who text; br bigint;
begin
  if tg_op <> 'INSERT' then o := to_jsonb(old); end if;
  if tg_op <> 'DELETE' then n := to_jsonb(new); end if;
  br := nullif(coalesce(n ->> 'branch_id', o ->> 'branch_id'), '')::bigint;
  if tg_op = 'UPDATE' then
    -- เก็บเฉพาะช่องที่เปลี่ยน
    for k in select jsonb_object_keys(n) loop
      if k not in ('updated_at') and (o -> k) is distinct from (n -> k) then
        oc := oc || jsonb_build_object(k, o -> k); nc := nc || jsonb_build_object(k, n -> k);
      end if;
    end loop;
    if nc = '{}' then return null; end if;
    o := oc; n := nc;
  end if;
  select full_name into who from staff where user_id = auth.uid();
  insert into audit_log (user_id, user_name, branch_id, tbl, action, row_id, old_data, new_data)
  values (auth.uid(), coalesce(who, case when auth.uid() is null then 'ระบบอัตโนมัติ' else '' end),
          br, tg_table_name, lower(tg_op),
          coalesce(to_jsonb(coalesce(new, old)) ->> 'id', to_jsonb(coalesce(new, old)) ->> 'bill_id', to_jsonb(coalesce(new, old)) ->> 'key', to_jsonb(coalesce(new, old)) ->> 'user_id'), o, n);
  return null;
end $$;

do $$
declare t text;
begin
  foreach t in array array['bills','payments','customers','vehicles','expenses','cash_closes','dlt_jobs','insp_queue','staff','branches','app_settings'] loop
    if to_regclass('public.' || t) is not null then
      execute format('drop trigger if exists %I on public.%I', t || '_audit', t);
      execute format('create trigger %I after insert or update or delete on public.%I for each row execute function public.audit()', t || '_audit', t);
    end if;
  end loop;
end $$;

alter table public.audit_log enable row level security;
drop policy if exists al_read on public.audit_log;
create policy al_read on public.audit_log for select to authenticated using (my_role() = 'owner');
revoke all on public.audit_log from anon, authenticated;
grant select on public.audit_log to authenticated;
