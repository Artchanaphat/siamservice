-- 14-safe-bills.sql : บันทึกบิลให้ปลอดภัย (รันหลัง 01–13, รันซ้ำได้)
-- 1) เปิดบิล = ลูกค้า + รถ + บิล + เงิน บันทึกในธุรกรรมเดียว (สำเร็จทั้งหมด หรือไม่บันทึกเลย)
-- 2) กันบิลซ้ำ / รับเงินซ้ำ ด้วยรหัสอ้างอิงจากเครื่อง (client_key) กดซ้ำหรือเน็ตหลุดแล้วส่งใหม่ ได้บิลเดิม
-- 3) เงินโอน: รอตรวจสอบ / ยืนยันแล้ว / ปฏิเสธ (เก็บชื่อผู้ตรวจและเวลา)
-- 4) กันรับเงินเกินยอดบิล
-- 5) เอกสารแนบที่ยังขาด (files_pending) ลดลงเองเมื่ออัปโหลดสำเร็จ
-- 6) คิวตรวจสภาพผูกกับบิลด้วยรหัส (insp_queue.bill_id) กันเปิดบิลซ้ำจากคิวเดิม
-- 7) เปิด Realtime ให้ทุกเครื่องเห็นข้อมูลตรงกัน
-- ไม่ลบหรือแก้ข้อมูลเดิม: คอลัมน์ใหม่ทั้งหมดมีค่าเริ่มต้นที่ไม่กระทบบิลเก่า

-- ---------- คอลัมน์ใหม่ ----------
alter table public.bills    add column if not exists client_key    uuid;
alter table public.bills    add column if not exists files_pending jsonb not null default '[]';
alter table public.payments add column if not exists client_key    text;
alter table public.payments add column if not exists rejected      boolean not null default false;
alter table public.payments add column if not exists reject_reason text;
alter table public.payments add column if not exists rejected_by   text;
alter table public.payments add column if not exists rejected_at   timestamptz;
alter table public.insp_queue add column if not exists bill_id     bigint references public.bills(id);
create unique index if not exists bills_client_key    on public.bills (client_key);
create unique index if not exists payments_client_key on public.payments (client_key);
create unique index if not exists insp_queue_bill     on public.insp_queue (bill_id);
create index if not exists bills_open on public.bills (branch_id, status) where status = 'open';
create index if not exists bills_vehicle_at on public.bills (vehicle_id, bill_at desc);

-- ---------- คอลัมน์สำหรับคืนเงิน (ใช้ใน 15) เพิ่มไว้ก่อน เพื่อให้รัน 14 ซ้ำภายหลังได้โดยไม่ทับการคิดยอดคืนเงิน ----------
alter table public.payments add column if not exists kind text not null default 'pay';
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'payments_kind_check') then
    alter table public.payments add constraint payments_kind_check check (kind in ('pay','refund'));
  end if;
end $$;
alter table public.bills add column if not exists refund_total numeric(12,2) not null default 0;

-- ---------- ยอดที่รับสุทธิ / สถานะบิล (ไม่นับเงินที่ถูกปฏิเสธ, หักเงินที่คืน) ----------
create or replace function public.bill_net_paid(p_bill bigint) returns numeric
language sql stable security definer set search_path = public as $$
  select coalesce(sum(case when kind = 'refund' then -amount else amount end), 0)
    from payments where bill_id = p_bill and not rejected
$$;
revoke all on function public.bill_net_paid(bigint) from public, anon;
grant execute on function public.bill_net_paid(bigint) to authenticated;

create or replace function public.refresh_bill_status() returns trigger
language plpgsql security definer set search_path = public as $$
declare bid bigint := coalesce(new.bill_id, old.bill_id); paid numeric := bill_net_paid(bid);
begin
  update bills set status = case when status = 'void' then 'void'
                                 when paid >= total - refund_total then 'paid' else 'open' end
   where id = bid;
  return null;
end $$;

-- รับเงิน: คิดยอดค้างจาก total - refund_total และหักเงินที่คืนแล้ว
create or replace function public._insert_pays(p_bill bigint, p_branch bigint, p_pays jsonb, p_key text)
returns jsonb language plpgsql security invoker set search_path = public as $$
declare it jsonb; i int := 0; ids jsonb := '[]'; pid bigint; m text; w boolean;
        tot numeric; paid numeric; add numeric := 0; st text;
begin
  perform pg_advisory_xact_lock(hashtext('bill_pay'), p_bill::int);
  select total - refund_total, status into tot, st from bills where id = p_bill;
  if not found then raise exception 'ไม่พบบิล'; end if;
  if st = 'void' then raise exception 'บิลนี้ถูกยกเลิกแล้ว รับเงินไม่ได้'; end if;
  paid := bill_net_paid(p_bill);
  for it in select * from jsonb_array_elements(coalesce(p_pays,'[]')) loop
    if coalesce((it->>'amount')::numeric,0) <= 0 then raise exception 'จำนวนเงินต้องมากกว่า 0'; end if;
    add := add + (it->>'amount')::numeric;
  end loop;
  if paid + add > tot + 0.005 then
    raise exception 'ยอดรับเงิน % บาท เกินยอดค้างชำระ % บาท', add, greatest(tot - paid, 0);
  end if;
  for it in select * from jsonb_array_elements(coalesce(p_pays,'[]')) loop
    m := coalesce(nullif(it->>'method',''),'เงินสด');
    w := coalesce((it->>'wait')::boolean, false) and m = 'โอน';
    insert into payments (bill_id, branch_id, amount, method, by_name, verified, client_key)
    values (p_bill, p_branch, (it->>'amount')::numeric, m, coalesce(it->>'by_name',''), not w,
            case when p_key is null then null else p_key || ':' || i end)
    returning id into pid;
    ids := ids || to_jsonb(pid); i := i + 1;
  end loop;
  return ids;
end $$;

revoke all on function public._insert_pays(bigint, bigint, jsonb, text) from public, anon;
grant execute on function public._insert_pays(bigint, bigint, jsonb, text) to authenticated;

-- ---------- เปิดบิลใหม่ (ธุรกรรมเดียว) ----------
-- p = {client_key, branch_id, cust_id, cust:{...}, veh:{...}, bill:{...}, pays:[...], queue_id}
create or replace function public.create_bill(p jsonb) returns jsonb
language plpgsql security invoker set search_path = public as $$
declare k uuid := (p->>'client_key')::uuid; br bigint := (p->>'branch_id')::bigint;
        c jsonb := coalesce(p->'cust','{}'); v jsonb := coalesce(p->'veh','{}'); b jsonb := coalesce(p->'bill','{}');
        cid bigint := nullif(p->>'cust_id','')::bigint; vid bigint; bid bigint; bno text; pays jsonb;
        qid bigint := nullif(p->>'queue_id','')::bigint; qb bigint; ex record;
begin
  if my_role() is null then raise exception 'ไม่มีสิทธิ์ใช้งาน'; end if;
  if k is null then raise exception 'ไม่มีรหัสอ้างอิงบิล'; end if;
  if not can_see_branch(br) then raise exception 'ไม่มีสิทธิ์เปิดบิลของสาขานี้'; end if;
  -- ส่งซ้ำ (กดซ้ำ / เน็ตหลุดแล้วส่งใหม่) = คืนบิลเดิม ไม่สร้างใหม่
  select id, bill_no, customer_id, vehicle_id into ex from bills where client_key = k;
  if found then
    return jsonb_build_object('id', ex.id, 'bill_no', ex.bill_no, 'customer_id', ex.customer_id, 'vehicle_id', ex.vehicle_id, 'dup', true,
      'pay_ids', coalesce((select jsonb_agg(id order by id) from payments where bill_id = ex.id), '[]'));
  end if;
  if qid is not null then
    select bill_id into qb from insp_queue where id = qid for update;
    if qb is not null then
      raise exception 'คิวนี้เปิดบิลไปแล้ว (เลขที่ %)', (select bill_no from bills where id = qb);
    end if;
  end if;
  if coalesce(trim(c->>'first_name'),'') = '' then raise exception 'กรุณาระบุชื่อลูกค้า'; end if;
  if coalesce(trim(v->>'plate'),'') = '' then raise exception 'กรุณาระบุทะเบียนรถ'; end if;
  if coalesce((b->>'total')::numeric,0) < 0 then raise exception 'ยอดรวมบิลติดลบ กรุณาตรวจส่วนลด'; end if;
  if coalesce((b->>'discount')::numeric,0) < 0 then raise exception 'ส่วนลดต้องไม่ติดลบ'; end if;

  if cid is not null then
    update customers set prefix = coalesce(c->>'prefix',''), first_name = c->>'first_name', last_name = coalesce(c->>'last_name',''),
      tel = coalesce(c->>'tel',''), id_card = coalesce(c->>'id_card',''), address = coalesce(c->>'address',''), tumbol = coalesce(c->>'tumbol',''),
      amphoe = coalesce(c->>'amphoe',''), province = coalesce(c->>'province',''), zipcode = coalesce(c->>'zipcode',''),
      short_note = coalesce(c->>'short_note',''), note = coalesce(c->>'note','')
    where id = cid;
    if not found then cid := null; end if;
  end if;
  if cid is null then
    insert into customers (prefix, first_name, last_name, tel, id_card, address, tumbol, amphoe, province, zipcode, short_note, note)
    values (coalesce(c->>'prefix',''), c->>'first_name', coalesce(c->>'last_name',''), coalesce(c->>'tel',''), coalesce(c->>'id_card',''),
            coalesce(c->>'address',''), coalesce(c->>'tumbol',''), coalesce(c->>'amphoe',''), coalesce(c->>'province',''),
            coalesce(c->>'zipcode',''), coalesce(c->>'short_note',''), coalesce(c->>'note',''))
    returning id into cid;
  end if;

  insert into vehicles as t (customer_id, plate, province, car_type, body, brand, model, color, chassis_no, engine_no, cc, weight_kg,
                             reg_date, tax_exp, prb_exp, ins_exp, ins_company, prb_company, k_exp)
  values (cid, v->>'plate', coalesce(v->>'province',''), coalesce(v->>'car_type',''), coalesce(v->>'body',''), coalesce(v->>'brand',''),
          coalesce(v->>'model',''), coalesce(v->>'color',''), coalesce(v->>'chassis_no',''), coalesce(v->>'engine_no',''),
          nullif(v->>'cc','')::numeric::int, nullif(v->>'weight_kg','')::numeric::int, nullif(v->>'reg_date','')::date,
          nullif(v->>'tax_exp','')::date, nullif(v->>'prb_exp','')::date, nullif(v->>'ins_exp','')::date,
          coalesce(v->>'ins_company',''), coalesce(v->>'prb_company',''), nullif(v->>'k_exp','')::date)
  on conflict (plate, province) do update set
    customer_id = excluded.customer_id, car_type = excluded.car_type, body = excluded.body, brand = excluded.brand, model = excluded.model,
    color = excluded.color, chassis_no = excluded.chassis_no, engine_no = excluded.engine_no, cc = excluded.cc, weight_kg = excluded.weight_kg,
    reg_date = excluded.reg_date, tax_exp = excluded.tax_exp, prb_exp = excluded.prb_exp, ins_exp = excluded.ins_exp,
    ins_company = excluded.ins_company, prb_company = excluded.prb_company, k_exp = excluded.k_exp
  returning id into vid;

  begin
    insert into bills (branch_id, customer_id, vehicle_id, snapshot, items, ins_premium, discount, total, pick_date, note, client_key, files_pending)
    values (br, cid, vid, coalesce(b->'snapshot','{}'), coalesce(b->'items','[]'), coalesce((b->>'ins_premium')::numeric,0),
            coalesce((b->>'discount')::numeric,0), coalesce((b->>'total')::numeric,0), nullif(b->>'pick_date','')::date,
            coalesce(b->>'note',''), k, coalesce(b->'files_pending','[]'))
    returning id, bill_no into bid, bno;
  exception when unique_violation then
    -- อีกคำขอที่ส่งพร้อมกันบันทึกไปก่อนแล้ว
    select id, bill_no into bid, bno from bills where client_key = k;
    if bid is null then raise; end if;
    return jsonb_build_object('id', bid, 'bill_no', bno, 'customer_id', cid, 'vehicle_id', vid, 'dup', true,
      'pay_ids', coalesce((select jsonb_agg(id order by id) from payments where bill_id = bid), '[]'));
  end;
  pays := _insert_pays(bid, br, p->'pays', k::text);
  if qid is not null then
    update insp_queue set bill_id = bid, billed = true, updated_by_name = coalesce((select full_name from staff where user_id = auth.uid()),'')
     where id = qid and can_see_branch(branch_id);
  end if;
  return jsonb_build_object('id', bid, 'bill_no', bno, 'customer_id', cid, 'vehicle_id', vid, 'dup', false, 'pay_ids', pays);
end $$;
revoke all on function public.create_bill(jsonb) from public, anon;
grant execute on function public.create_bill(jsonb) to authenticated;

-- ---------- รับเงินเพิ่ม / ชำระยอดค้าง (กันกดซ้ำ + กันเกินยอด) ----------
create or replace function public.add_payments(p_bill bigint, p_pays jsonb, p_key uuid) returns jsonb
language plpgsql security invoker set search_path = public as $$
declare br bigint;
begin
  if my_role() is null then raise exception 'ไม่มีสิทธิ์ใช้งาน'; end if;
  if p_key is null then raise exception 'ไม่มีรหัสอ้างอิงการรับเงิน'; end if;
  if exists (select 1 from payments where client_key like p_key::text || ':%') then
    return jsonb_build_object('dup', true, 'pay_ids',
      (select jsonb_agg(id order by id) from payments where client_key like p_key::text || ':%'));
  end if;
  select branch_id into br from bills where id = p_bill;
  if br is null or not can_see_branch(br) then raise exception 'ไม่พบบิล หรือไม่มีสิทธิ์รับเงินบิลนี้'; end if;
  return jsonb_build_object('dup', false, 'pay_ids', _insert_pays(p_bill, br, p_pays, p_key::text));
end $$;
revoke all on function public.add_payments(bigint, jsonb, uuid) from public, anon;
grant execute on function public.add_payments(bigint, jsonb, uuid) to authenticated;

-- ---------- ตรวจเงินโอน: ยืนยัน / ปฏิเสธ ----------
create or replace function public.verify_payment(p_id bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r payments; who text;
begin
  if my_role() is null then raise exception 'ไม่มีสิทธิ์ใช้งาน'; end if;
  select * into r from payments where id = p_id for update;
  if not found then raise exception 'ไม่พบรายการรับเงิน'; end if;
  if not can_see_branch(r.branch_id) then raise exception 'ไม่มีสิทธิ์ยืนยันรายการของสาขาอื่น'; end if;
  if r.rejected then raise exception 'รายการนี้ถูกปฏิเสธไปแล้ว โดย % ยืนยันซ้ำไม่ได้', coalesce(r.rejected_by,'-'); end if;
  if r.verified then
    return jsonb_build_object('id', r.id, 'verified', true, 'verified_by', r.verified_by, 'verified_at', r.verified_at);
  end if;
  select full_name into who from staff where user_id = auth.uid();
  update payments set verified = true, verified_by = coalesce(who, ''), verified_at = now() where id = p_id
    returning * into r;
  return jsonb_build_object('id', r.id, 'verified', true, 'verified_by', r.verified_by, 'verified_at', r.verified_at);
end $$;

-- ปฏิเสธ = ตรวจแล้วเงินไม่เข้า: รายการยังอยู่ (มีร่องรอย) แต่ไม่นับเป็นยอดรับ บิลกลับเป็นค้างชำระ
create or replace function public.reject_payment(p_id bigint, p_reason text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r payments; who text;
begin
  if my_role() is null then raise exception 'ไม่มีสิทธิ์ใช้งาน'; end if;
  if coalesce(trim(p_reason),'') = '' then raise exception 'กรุณาระบุเหตุผลที่ปฏิเสธ'; end if;
  select * into r from payments where id = p_id for update;
  if not found then raise exception 'ไม่พบรายการรับเงิน'; end if;
  if not can_see_branch(r.branch_id) then raise exception 'ไม่มีสิทธิ์ตรวจรายการของสาขาอื่น'; end if;
  if r.verified then raise exception 'รายการนี้ยืนยันแล้ว ปฏิเสธไม่ได้ (ถ้าผิดให้ทำรายการคืนเงิน)'; end if;
  if r.rejected then return jsonb_build_object('id', r.id, 'rejected', true, 'rejected_by', r.rejected_by, 'rejected_at', r.rejected_at); end if;
  select full_name into who from staff where user_id = auth.uid();
  update payments set rejected = true, reject_reason = trim(p_reason), rejected_by = coalesce(who,''), rejected_at = now()
   where id = p_id returning * into r;
  return jsonb_build_object('id', r.id, 'rejected', true, 'rejected_by', r.rejected_by, 'rejected_at', r.rejected_at);
end $$;
revoke all on function public.reject_payment(bigint, text) from public, anon;
grant execute on function public.reject_payment(bigint, text) to authenticated;

-- ---------- เอกสารที่ยังขาด ----------
-- อัปโหลดสำเร็จ 1 ไฟล์ = ตัดชื่อไฟล์นั้นออกจากรายการที่ขาด (ถ้าชื่อไม่ตรง ตัดรายการแรก)
create or replace function public.bill_files_done() returns trigger
language plpgsql security definer set search_path = public as $$
declare L jsonb; i int;
begin
  if current_setting('siam.restoring', true) = '1' then return null; end if;  -- ระหว่างกู้คืนจากไฟล์สำรอง (16) ไม่ต้องตัด
  select files_pending into L from bills where id = new.bill_id for update;  -- trigger นี้เป็น security definer จึงล็อกได้
  if L is null or jsonb_array_length(L) = 0 then return null; end if;
  select coalesce(min(ord) - 1, 0) into i from jsonb_array_elements_text(L) with ordinality as x(n, ord) where n = new.file_name;
  update bills set files_pending = L - i where id = new.bill_id;
  return null;
end $$;
drop trigger if exists bill_files_done on public.bill_files;
create trigger bill_files_done after insert on public.bill_files for each row execute function public.bill_files_done();

-- เจ้าของ/หัวหน้า กด "ไม่ต้องแนบแล้ว" ได้ (เก็บร่องรอยใน bill_edits)
create or replace function public.clear_files_pending(p_bill bigint) returns void
language plpgsql security definer set search_path = public as $$
declare br bigint; who text;
begin
  if my_role() not in ('owner','head') then raise exception 'เฉพาะเจ้าของร้าน/หัวหน้าสาขา'; end if;
  select branch_id into br from bills where id = p_bill;
  if br is null or not can_see_branch(br) then raise exception 'ไม่พบบิล'; end if;
  select full_name into who from staff where user_id = auth.uid();
  update bills set files_pending = '[]' where id = p_bill;
  insert into bill_edits (bill_id, what, by_name) values (p_bill, 'ยืนยันว่าเอกสารครบ ไม่ต้องแนบเพิ่ม', coalesce(who,''));
end $$;
revoke all on function public.clear_files_pending(bigint) from public, anon;
grant execute on function public.clear_files_pending(bigint) to authenticated;

-- ---------- Realtime: ทุกเครื่องเห็นการเปลี่ยนแปลง (สิทธิ์ตาม RLS เดิม) ----------
do $$
declare t text;
begin
  if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    raise notice 'ไม่พบ publication supabase_realtime (ข้ามได้ถ้าไม่ได้รันบน Supabase)'; return;
  end if;
  foreach t in array array['bills','payments','bill_edits','vehicles','customers','insp_queue','dlt_jobs','bill_files'] loop
    if exists (select 1 from information_schema.tables where table_schema = 'public' and table_name = t)
       and not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;
