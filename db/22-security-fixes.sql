-- 22-security-fixes.sql : ปิดช่องโหว่และแก้จุดเสี่ยงตามผลตรวจระบบ (รันหลัง 01–21, รันซ้ำได้)
-- วิธีรัน: Supabase › SQL Editor › New query › วางทั้งไฟล์ › Run  (ไม่ลบ/ไม่แก้ข้อมูลเดิม)
-- สิ่งที่เปลี่ยน
--   1) กู้คืนข้อมูล (restore_backup): หาคอลัมน์รหัสอัตโนมัติของแต่ละตารางเอง (เดิมพังที่ dlt_jobs/app_settings),
--      อ่านเลขบิลถูกต้องเมื่อเกิน 9999 และกู้ลงโปรเจกต์ใหม่ได้แม้บัญชีผู้ใช้เดิมไม่มีแล้ว (ช่อง "สร้างโดย" จะว่าง)
--   2) เลขบิล: เกิน 9999 ไม่ถูกตัด (…-6910000) เลขเดิมไม่เปลี่ยน; ผู้ใช้กำหนดเลขบิลเองไม่ได้ (ยกเว้นตอนกู้คืน)
--   3) บิล/การรับเงิน: เขียนตรงจากหน้าเว็บไม่ได้แล้ว ต้องผ่านฟังก์ชัน create_bill / add_payments / edit_bill
--      ซึ่งตรวจสิทธิ์และสาขาเอง (security definer)
--   4) เงินโอนใหม่ = รอตรวจเสมอ (ยืนยันได้ทาง verify_payment เท่านั้น)
--   5) อนุมัติยกเลิก/คืนเงิน: ล็อกเดียวกับการรับเงิน, ห้ามอนุมัติถ้ายังมีเงินโอนรอตรวจ, คิดยอดคืนจากเงินที่ยืนยันแล้วเท่านั้น
--   6) edit_bill: แก้ไขบิล+ลูกค้า+รถ ในธุรกรรมเดียว (ล้มเหลว = ไม่มีอะไรถูกบันทึก)
--   7) sms_send: ห้ามระบุสาขาที่ตัวเองไม่มีสิทธิ์
--   8) ปิดยอด: ฐานข้อมูลคำนวณยอดเอง, ผู้ปิดยอด = ผู้ใช้ที่ล็อกอิน, พนักงานแก้ยอดที่ปิดแล้วไม่ได้ (เจ้าของร้าน/หัวหน้าได้)
--   9) schema_status(): ให้หน้า "ตรวจการเชื่อมต่อ" เช็คว่ารัน SQL 19–22 แล้ว (อ่านอย่างเดียว)
-- ย้อนกลับ: ดูท้ายไฟล์

-- ---------- 2) เลขบิล ----------
create or replace function public.set_bill_no()
returns trigger language plpgsql security definer set search_path = public as $$
declare y int := extract(year from (new.bill_at at time zone 'Asia/Bangkok'))::int + 543; n int; c text;
begin
  -- รับเลขบิลที่ส่งมาเฉพาะตอนกู้คืนข้อมูล หรืองานเบื้องหลัง (ไม่มีผู้ใช้ล็อกอิน)
  if new.bill_no is not null and new.bill_no <> ''
     and (current_setting('siam.restoring', true) = '1' or auth.uid() is null) then
    return new;
  end if;
  insert into bill_counters (branch_id, be_year, last_no) values (new.branch_id, y, 1)
    on conflict (branch_id, be_year) do update set last_no = bill_counters.last_no + 1
    returning last_no into n;
  select code into c from branches where id = new.branch_id;
  new.bill_no := c || '-' || lpad((y % 100)::text, 2, '0') || case when n < 10000 then lpad(n::text, 4, '0') else n::text end;
  return new;
end $$;

-- ---------- 1) กู้คืนข้อมูล ----------
create or replace function public.restore_backup(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare t text; n int; out jsonb := '{}'; total int := 0; seq text; cols text; sel text; idc text;
  tabs text[] := array['branches','customers','vehicles','bills','payments','bill_edits','dlt_jobs','bill_files','bill_requests',
                       'insp_queue','cash_closes','expenses','app_settings','news','audit_log'];
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

-- ---------- 3–4) รับเงิน: เงินโอนรอตรวจเสมอ ----------
create or replace function public._insert_pays(p_bill bigint, p_branch bigint, p_pays jsonb, p_key text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare it jsonb; i int := 0; ids jsonb := '[]'; pid bigint; m text; w boolean;
        tot numeric; paid numeric; add numeric := 0; st text; who text;
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
  select full_name into who from staff where user_id = auth.uid();
  for it in select * from jsonb_array_elements(coalesce(p_pays,'[]')) loop
    m := coalesce(nullif(it->>'method',''),'เงินสด');
    w := m ~ 'โอน';   -- เงินโอนทุกรายการต้องรอตรวจ ไม่ขึ้นกับค่าที่หน้าเว็บส่งมา
    insert into payments (bill_id, branch_id, amount, method, by_name, verified, client_key)
    values (p_bill, p_branch, (it->>'amount')::numeric, m, coalesce(nullif(it->>'by_name',''), who, ''), not w,
            case when p_key is null then null else p_key || ':' || i end)
    returning id into pid;
    ids := ids || to_jsonb(pid); i := i + 1;
  end loop;
  return ids;
end $$;
-- เรียกตรงไม่ได้ (เรียกผ่าน create_bill / add_payments เท่านั้น)
revoke all on function public._insert_pays(bigint, bigint, jsonb, text) from public, anon, authenticated;

-- create_bill / add_payments: เปลี่ยนเป็น security definer (ตรวจสิทธิ์/สาขาเองอยู่แล้วในฟังก์ชัน)
alter function public.create_bill(jsonb) security definer;

-- add_payments: security definer + กันกดซ้ำพร้อมกัน (คำขอที่สองรอแล้วได้ผลเดิม ไม่ error)
create or replace function public.add_payments(p_bill bigint, p_pays jsonb, p_key uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare br bigint;
begin
  if my_role() is null then raise exception 'ไม่มีสิทธิ์ใช้งาน'; end if;
  if p_key is null then raise exception 'ไม่มีรหัสอ้างอิงการรับเงิน'; end if;
  select branch_id into br from bills where id = p_bill;
  if br is null or not can_see_branch(br) then raise exception 'ไม่พบบิล หรือไม่มีสิทธิ์รับเงินบิลนี้'; end if;
  perform pg_advisory_xact_lock(hashtext('bill_pay'), p_bill::int);
  if exists (select 1 from payments where client_key like p_key::text || ':%') then
    return jsonb_build_object('dup', true, 'pay_ids',
      (select jsonb_agg(id order by id) from payments where client_key like p_key::text || ':%'));
  end if;
  return jsonb_build_object('dup', false, 'pay_ids', _insert_pays(p_bill, br, p_pays, p_key::text));
end $$;
revoke all on function public.add_payments(bigint, jsonb, uuid) from public, anon;
grant execute on function public.add_payments(bigint, jsonb, uuid) to authenticated;

-- ปิดการเขียนตรงจากหน้าเว็บ (ฟังก์ชันด้านบนยังเขียนได้ตามปกติ)
drop policy if exists bi_ins on public.bills;
drop policy if exists pa_ins on public.payments;
drop policy if exists be_ins on public.bill_edits;
revoke insert, update on public.bills from anon, authenticated;
revoke insert, update on public.payments from anon, authenticated;
revoke insert, update on public.bill_edits from anon, authenticated;

-- ---------- 5) อนุมัติยกเลิกบิล / คืนเงิน ----------
create or replace function public.decide_bill_action(p_id bigint, p_approve boolean, p_note text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r bill_requests; b bills; who text; paid numeric; amt numeric; nw int; sw numeric;
begin
  if my_role() not in ('owner','head') then raise exception 'อนุมัติได้เฉพาะเจ้าของร้าน/หัวหน้าสาขา'; end if;
  select * into r from bill_requests where id = p_id;
  if not found or not can_see_branch(r.branch_id) then raise exception 'ไม่พบคำขอ'; end if;
  -- ล็อกเดียวกับการรับเงิน (กันรับเงินแทรกระหว่างอนุมัติ) แล้วค่อยล็อกคำขอ
  perform pg_advisory_xact_lock(hashtext('bill_pay'), r.bill_id::int);
  select * into r from bill_requests where id = p_id for update;
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
  select count(*), coalesce(sum(amount),0) into nw, sw from payments
   where bill_id = r.bill_id and kind = 'pay' and not verified and not coalesce(rejected,false);
  if nw > 0 then
    raise exception 'บิลนี้ยังมีเงินโอนรอตรวจสอบ % รายการ (% บาท) กรุณายืนยันหรือปฏิเสธก่อนอนุมัติ', nw, to_char(sw,'FM999,999,990.00');
  end if;
  -- เงินที่ยืนยันแล้วสุทธิ (หักที่คืนไปแล้ว)
  select coalesce(sum(case when kind = 'refund' then -amount else amount end), 0) into paid
    from payments where bill_id = r.bill_id and not coalesce(rejected,false) and (kind = 'refund' or verified);
  amt := case when r.kind = 'void' then greatest(paid, 0) else r.amount end;
  if amt > paid + 0.005 then raise exception 'ยอดที่รับไว้ (ยืนยันแล้ว) ตอนนี้ % บาท น้อยกว่ายอดที่ขอคืน', to_char(paid,'FM999,999,990.00'); end if;
  if amt > 0 then
    insert into payments (bill_id, branch_id, amount, method, by_name, verified, verified_by, verified_at, kind, request_id, note)
    values (r.bill_id, r.branch_id, amt, r.method, who, true, who, now(), 'refund', r.id, r.reason);
  end if;
  if r.kind = 'void' then
    update bills set status = 'void', void_reason = r.reason, void_by = r.requested_by, void_approved_by = who, void_at = now() where id = r.bill_id;
    update insp_queue set billed = false, bill_id = null where bill_id = r.bill_id;
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

-- ---------- 6) แก้ไขบิลในธุรกรรมเดียว ----------
-- p = {bill_id, what, snapshot:{...}, note, cust_id, cust:{...}, veh_id, veh:{...}}
create or replace function public.edit_bill(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare bid bigint := nullif(p->>'bill_id','')::bigint; b bills; who text;
        cid bigint := nullif(p->>'cust_id','')::bigint; vid bigint := nullif(p->>'veh_id','')::bigint;
        c jsonb := case when jsonb_typeof(p->'cust') = 'object' then p->'cust' else '{}' end;
        v jsonb := case when jsonb_typeof(p->'veh') = 'object' then p->'veh' else '{}' end; rc customers; rv vehicles;
begin
  if my_role() not in ('owner','head') then raise exception 'บัญชีนี้ไม่มีสิทธิ์แก้ไขบิล (เฉพาะเจ้าของร้าน/หัวหน้าสาขา)'; end if;
  select * into b from bills where id = bid for update;
  if not found or not can_see_branch(b.branch_id) then raise exception 'ไม่พบบิล หรือไม่มีสิทธิ์แก้ไขบิลนี้'; end if;
  if b.status = 'void' then raise exception 'บิลนี้ถูกยกเลิกแล้ว แก้ไขไม่ได้'; end if;
  select full_name into who from staff where user_id = auth.uid(); who := coalesce(who,'');
  update bills set snapshot = coalesce(p->'snapshot', snapshot), note = coalesce(p->>'note', note) where id = bid;
  insert into bill_edits (bill_id, what, after, by_name)
  values (bid, coalesce(nullif(trim(p->>'what'),''),'แก้ไขข้อมูล'), p->'snapshot', who);
  if vid is not null then
    if vid is distinct from b.vehicle_id then raise exception 'รถไม่ตรงกับบิลนี้'; end if;
    select * into rv from vehicles where id = vid for update;
    -- รับเฉพาะคอลัมน์ที่แก้จากหน้าแก้ไขบิลได้
    rv := jsonb_populate_record(rv, (select coalesce(jsonb_object_agg(k, x), '{}') from jsonb_each(v) e(k, x)
            where k in ('plate','province','car_type','brand','model','cc','body','color','chassis_no','engine_no','weight_kg','reg_date')));
    update vehicles set plate = rv.plate, province = rv.province, car_type = rv.car_type, brand = rv.brand, model = rv.model, cc = rv.cc,
      body = rv.body, color = rv.color, chassis_no = rv.chassis_no, engine_no = rv.engine_no, weight_kg = rv.weight_kg, reg_date = rv.reg_date
     where id = vid;
  end if;
  if cid is not null then
    if cid is distinct from b.customer_id and cid is distinct from rv.customer_id
       and cid is distinct from (select customer_id from vehicles where id = b.vehicle_id) then
      raise exception 'ลูกค้าไม่ตรงกับบิลนี้';
    end if;
    select * into rc from customers where id = cid for update;
    rc := jsonb_populate_record(rc, (select coalesce(jsonb_object_agg(k, x), '{}') from jsonb_each(c) e(k, x)
            where k in ('prefix','first_name','last_name','tel','short_note','id_card','address','tumbol','amphoe','province','zipcode')));
    update customers set prefix = rc.prefix, first_name = rc.first_name, last_name = rc.last_name, tel = rc.tel, short_note = rc.short_note,
      id_card = rc.id_card, address = rc.address, tumbol = rc.tumbol, amphoe = rc.amphoe, province = rc.province, zipcode = rc.zipcode
     where id = cid;
  end if;
  return jsonb_build_object('ok', true, 'by', who);
end $$;
revoke all on function public.edit_bill(jsonb) from public, anon;
grant execute on function public.edit_bill(jsonb) to authenticated;

-- ---------- 8) ปิดยอด: คำนวณยอดในฐานข้อมูล + สิทธิ์แก้หลังปิด ----------
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
  select full_name into who from staff where user_id = auth.uid();
  new.closed_by_name := coalesce(who, new.closed_by_name);
  if tg_op = 'UPDATE' then new.updated_at := now(); end if;
  return new;
end $$;
revoke all on function public.cash_close_compute() from public, anon, authenticated;
drop trigger if exists cash_closes_compute on public.cash_closes;
create trigger cash_closes_compute before insert or update on public.cash_closes
  for each row execute function public.cash_close_compute();

-- ---------- 9) สถานะการติดตั้ง (หน้าตรวจการเชื่อมต่อ) ----------
create or replace function public.schema_status() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare cr boolean := false; lb timestamptz;
begin
  if my_role() is null then return null; end if;
  begin execute 'select count(*) > 0 from cron.job where jobname = ''siam-backup-nightly''' into cr; exception when others then cr := false; end;
  begin execute 'select max(created_at) from public.backup_snapshots' into lb; exception when others then lb := null; end;
  return jsonb_build_object(
    's19', exists (select 1 from pg_trigger where tgname = 'cash_closes_pending_guard' and not tgisinternal),
    's20', to_regclass('public.backup_snapshots') is not null and to_regprocedure('public.backup_now()') is not null,
    's20cron', cr,
    's21', exists (select 1 from pg_proc where proname = 'daily_summary_text' and prosrc like '%dlt_late_received%'),
    's22', exists (select 1 from pg_trigger where tgname = 'cash_closes_compute' and not tgisinternal)
           and not has_table_privilege('authenticated', 'public.payments', 'insert'),
    'last_backup', lb);
end $$;
revoke all on function public.schema_status() from public, anon;
grant execute on function public.schema_status() to authenticated;

-- ---------- 7) SMS: ตรวจสิทธิ์สาขา ----------
-- (sms_send ด้านล่างเหมือนไฟล์ 11 ทุกอย่าง เพิ่มแค่บรรทัดตรวจ brx)
create or replace function public.sms_send(p_items jsonb) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare it jsonb; num text; msg text; snd text; frc text; st int; bd text; j jsonb; e text;
        okc int := 0; bad int := 0; res jsonb := '[]'; rem jsonb; who text; br bigint; brx bigint;
begin
  if my_role() is null then raise exception 'ไม่มีสิทธิ์ใช้งาน'; end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then raise exception 'ไม่มีรายการที่จะส่ง'; end if;
  if jsonb_array_length(p_items) > 100 then raise exception 'ส่งได้ครั้งละไม่เกิน 100 รายการ'; end if;
  select value ->> 'sms_sender', coalesce(nullif(value ->> 'sms_force', ''), 'standard')
    into snd, frc from app_settings where key = 'main';
  if coalesce(trim(snd), '') = '' then raise exception 'ยังไม่ได้ตั้งชื่อผู้ส่ง (Sender name) ในหน้าตั้งค่าระบบ'; end if;
  select full_name, branch_id into who, br from staff where user_id = auth.uid();
  for it in select * from jsonb_array_elements(p_items) loop
    num := regexp_replace(coalesce(it ->> 'to', ''), '[^0-9]', '', 'g');
    msg := left(trim(coalesce(it ->> 'message', '')), 670);
    brx := coalesce(nullif(it ->> 'branch_id', '')::bigint, br);
    if brx is not null and not can_see_branch(brx) then raise exception 'ไม่มีสิทธิ์ส่ง SMS ในนามสาขานี้'; end if;
    if num ~ '^0[689][0-9]{8}$' then num := '+66' || substr(num, 2);
    elsif num ~ '^66[689][0-9]{8}$' then num := '+' || num;
    else num := null; end if;
    if num is null or msg = '' then
      e := case when msg = '' then 'ไม่มีข้อความ' else 'เบอร์มือถือไม่ถูกต้อง' end;
      bad := bad + 1;
      insert into sms_sent(branch_id, vehicle_id, kind, msisdn, message, ok, detail, by_name)
        values (brx, nullif(it ->> 'vehicle_id', '')::bigint, coalesce(it ->> 'kind', 'other'), coalesce(it ->> 'to', ''), msg, false, e, who);
      res := res || jsonb_build_object('to', it ->> 'to', 'vehicle_id', it -> 'vehicle_id', 'ok', false, 'error', e);
      continue;
    end if;
    begin
      select c.status, c.body into st, bd from sms_call('POST', '/sms',
        'msisdn=' || urlencode(num) || '&message=' || urlencode(msg) || '&sender=' || urlencode(trim(snd)) || '&force=' || urlencode(frc)) c;
    exception when others then st := 0; bd := sqlerrm; end;
    begin j := bd::jsonb; exception when others then j := null; end;
    if st between 200 and 299 then
      okc := okc + 1; rem := coalesce(j -> 'remaining_credit', rem);
      insert into sms_sent(branch_id, vehicle_id, kind, msisdn, message, ok, credit, detail, by_name)
        values (brx, nullif(it ->> 'vehicle_id', '')::bigint, coalesce(it ->> 'kind', 'other'), num, msg, true,
                nullif(j ->> 'total_use_credit', '')::numeric, j #>> '{phone_number_list,0,message_id}', who);
      res := res || jsonb_build_object('to', it ->> 'to', 'vehicle_id', it -> 'vehicle_id', 'ok', true);
    else
      e := sms_err(st, bd); bad := bad + 1;
      insert into sms_sent(branch_id, vehicle_id, kind, msisdn, message, ok, detail, by_name)
        values (brx, nullif(it ->> 'vehicle_id', '')::bigint, coalesce(it ->> 'kind', 'other'), num, msg, false, e, who);
      res := res || jsonb_build_object('to', it ->> 'to', 'vehicle_id', it -> 'vehicle_id', 'ok', false, 'error', e);
      if st in (0, 401, 403) then exit; end if;   -- รหัสผิด / เชื่อมต่อไม่ได้ : หยุดส่งรายการที่เหลือ
    end if;
  end loop;
  return jsonb_build_object('sent', okc, 'failed', bad, 'remaining', rem, 'results', res);
end $$;
revoke all on function public.sms_send(jsonb) from public, anon;
grant execute on function public.sms_send(jsonb) to authenticated;

-- ---------- ตรวจผล (อ่านอย่างเดียว) ----------
-- select public.schema_status();   -- ต้องได้ "s22": true (ต้องล็อกอินในแอป; ใน SQL Editor จะได้ null ซึ่งปกติ)
-- select tgname from pg_trigger where tgrelid = 'public.cash_closes'::regclass and not tgisinternal;  -- ต้องมี cash_closes_compute

-- ---------- ย้อนกลับ (ถ้าจำเป็น) ----------
-- 1) รัน 14-safe-bills.sql, 15-void-refund.sql, 16-backup.sql และ 11-files-sms.sql ซ้ำ (คืนฟังก์ชันเดิม)
--    และรันส่วน set_bill_no จาก 01-schema.sql ซ้ำ
-- 2) แล้วรันคำสั่งนี้:
-- grant insert, update on public.bills, public.payments, public.bill_edits to authenticated;
-- create policy bi_ins on public.bills for insert to authenticated with check (can_see_branch(branch_id));
-- create policy pa_ins on public.payments for insert to authenticated with check (can_see_branch(branch_id) and kind = 'pay'
--   and exists (select 1 from bills b where b.id = payments.bill_id and b.branch_id = payments.branch_id));
-- create policy be_ins on public.bill_edits for insert to authenticated with check (exists (select 1 from bills b where b.id = bill_edits.bill_id and can_see_branch(b.branch_id)));
-- drop trigger if exists cash_closes_compute on public.cash_closes; drop function if exists public.cash_close_compute();
-- drop function if exists public.edit_bill(jsonb); drop function if exists public.schema_status();
-- หมายเหตุ: หน้าเว็บเวอร์ชันใหม่ใช้ edit_bill ถ้าย้อนกลับ หน้าเว็บจะกลับไปแก้บิลแบบเดิมเอง
