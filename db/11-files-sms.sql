-- ตรอ.สยามเซอร์วิส : ไฟล์แนบบิล (รูปภาพ / PDF) และส่ง SMS จริงผ่าน ThaiBulkSMS
-- รันครั้งเดียว หลังไฟล์ 01–10 (รันซ้ำได้)
-- รหัส API ของ ThaiBulkSMS เก็บใน Supabase Vault (เข้ารหัส) ใส่จากหน้าตั้งค่าระบบในแอปเท่านั้น

-- =========================================================
-- 1) ไฟล์แนบบิล : Storage bucket "bill-files" (ไม่เปิดสาธารณะ)
--    ที่อยู่ไฟล์ = <branch_id>/<bill_id>/<ชื่อไฟล์>
-- =========================================================
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('bill-files', 'bill-files', false, 10485760,
        array['image/jpeg','image/png','image/webp','image/heic','image/heif','application/pdf'])
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

-- สาขาจากโฟลเดอร์แรกของที่อยู่ไฟล์
create or replace function public.bill_file_branch(p_name text) returns bigint
language sql immutable as $$
  select case when split_part(p_name, '/', 1) ~ '^[0-9]+$' then split_part(p_name, '/', 1)::bigint end
$$;

drop policy if exists "bill files read"   on storage.objects;
drop policy if exists "bill files insert" on storage.objects;
drop policy if exists "bill files delete" on storage.objects;
create policy "bill files read" on storage.objects for select to authenticated
  using (bucket_id = 'bill-files' and public.can_see_branch(public.bill_file_branch(name)));
create policy "bill files insert" on storage.objects for insert to authenticated
  with check (bucket_id = 'bill-files' and public.can_see_branch(public.bill_file_branch(name)));
create policy "bill files delete" on storage.objects for delete to authenticated
  using (bucket_id = 'bill-files' and public.my_role() = 'owner');

create table if not exists public.bill_files (
  id          bigint generated always as identity primary key,
  bill_id     bigint not null references public.bills(id) on delete cascade,
  branch_id   bigint not null references public.branches(id),
  kind        text not null check (kind in ('image','pdf')),
  path        text not null unique,
  file_name   text not null default '',
  size_bytes  bigint,
  by_name     text,
  created_at  timestamptz not null default now()
);
create index if not exists bill_files_bill on public.bill_files(bill_id);
alter table public.bill_files enable row level security;
drop policy if exists bf_read on public.bill_files;
drop policy if exists bf_ins  on public.bill_files;
drop policy if exists bf_del  on public.bill_files;
create policy bf_read on public.bill_files for select to authenticated using (can_see_branch(branch_id));
create policy bf_ins  on public.bill_files for insert to authenticated with check (can_see_branch(branch_id));
create policy bf_del  on public.bill_files for delete to authenticated using (my_role() = 'owner');
grant select, insert, delete on public.bill_files to authenticated;

-- =========================================================
-- 2) SMS ผ่าน ThaiBulkSMS (API v2 : https://api-v2.thaibulksms.com)
-- =========================================================
create extension if not exists http with schema extensions;

create table if not exists public.sms_sent (
  id          bigint generated always as identity primary key,
  branch_id   bigint references public.branches(id),
  vehicle_id  bigint,
  kind        text not null default 'other',      -- reg = ภาษี, ins = ประกัน, test = ทดสอบ
  msisdn      text not null,
  message     text not null,
  ok          boolean not null,
  credit      numeric,
  detail      text,
  by_name     text,
  sent_at     timestamptz not null default now()
);
create index if not exists sms_sent_at on public.sms_sent(sent_at desc);
alter table public.sms_sent enable row level security;
drop policy if exists sl_read on public.sms_sent;
create policy sl_read on public.sms_sent for select to authenticated
  using (my_role() = 'owner' or branch_id = my_branch());
grant select on public.sms_sent to authenticated;

-- บันทึกรหัสจากหน้าตั้งค่า (ช่องที่เว้นว่าง = ไม่เปลี่ยน)
create or replace function public.set_sms_secrets(p_key text, p_secret text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if coalesce(my_role(), '') <> 'owner' then raise exception 'เฉพาะเจ้าของร้านเท่านั้น'; end if;
  if nullif(trim(p_key), '') is not null then
    if length(trim(p_key)) < 8 then raise exception 'API Key สั้นเกินไป ตรวจว่าคัดลอกมาครบ'; end if;
    perform vault_put('sms_api_key', trim(p_key));
  end if;
  if nullif(trim(p_secret), '') is not null then
    if length(trim(p_secret)) < 8 then raise exception 'API Secret สั้นเกินไป ตรวจว่าคัดลอกมาครบ'; end if;
    perform vault_put('sms_api_secret', trim(p_secret));
  end if;
end $$;

-- สถานะรหัส (แสดงแค่ 4 ตัวท้าย)
create or replace function public.sms_secret_status() returns jsonb
language plpgsql security definer set search_path = public as $$
declare k text; s text;
begin
  if coalesce(my_role(), '') <> 'owner' then raise exception 'เฉพาะเจ้าของร้านเท่านั้น'; end if;
  select decrypted_secret into k from vault.decrypted_secrets where name = 'sms_api_key';
  select decrypted_secret into s from vault.decrypted_secrets where name = 'sms_api_secret';
  return jsonb_build_object(
    'key',    case when coalesce(k, '') = '' then null else '••••' || right(k, 4) end,
    'secret', case when coalesce(s, '') = '' then null else '••••' || right(s, 4) end);
end $$;

-- เรียก API ของ ThaiBulkSMS (ใช้ภายในเท่านั้น)
create or replace function public.sms_call(p_method text, p_path text, p_form text default null)
returns table(status int, body text)
language plpgsql security definer set search_path = public, extensions as $$
declare k text; s text; req extensions.http_request; r extensions.http_response;
begin
  select decrypted_secret into k from vault.decrypted_secrets where name = 'sms_api_key';
  select decrypted_secret into s from vault.decrypted_secrets where name = 'sms_api_secret';
  if coalesce(k, '') = '' or coalesce(s, '') = '' then
    raise exception 'ยังไม่ได้ใส่ API Key และ API Secret ของ ThaiBulkSMS ในหน้าตั้งค่าระบบ';
  end if;
  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT', '20');
  req.method := p_method::extensions.http_method;
  req.uri := 'https://api-v2.thaibulksms.com' || p_path;
  req.headers := array[
    extensions.http_header('Authorization', 'Basic ' || replace(encode(convert_to(k || ':' || s, 'UTF8'), 'base64'), E'\n', '')),
    extensions.http_header('Accept', 'application/json')];
  req.content_type := case when p_form is null then null else 'application/x-www-form-urlencoded' end;
  req.content := p_form;
  r := extensions.http(req);
  return query select r.status, r.content::text;
end $$;
revoke all on function public.sms_call(text, text, text) from public, anon, authenticated;

-- ข้อความผิดพลาดจาก API ให้อ่านง่าย
create or replace function public.sms_err(p_status int, p_body text) returns text
language plpgsql immutable as $$
declare j jsonb; m text;
begin
  begin j := p_body::jsonb; exception when others then j := null; end;
  m := coalesce(j #>> '{error,description}', j #>> '{error,name}', j ->> 'message', j ->> 'error', left(p_body, 200));
  return case
    when p_status in (401, 403) then 'API Key / Secret ไม่ถูกต้อง (' || coalesce(m, '') || ')'
    when p_status = 0 then 'เชื่อมต่อ ThaiBulkSMS ไม่ได้: ' || coalesce(m, '')
    else coalesce(m, 'HTTP ' || p_status) end;
end $$;

-- ส่ง SMS : p_items = [{to, message, kind, vehicle_id, branch_id}]
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

-- เครดิตคงเหลือ
create or replace function public.sms_credit() returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare st int; bd text; j jsonb;
begin
  if my_role() is null then raise exception 'ไม่มีสิทธิ์ใช้งาน'; end if;
  begin select c.status, c.body into st, bd from sms_call('GET', '/credit') c;
  exception when others then return jsonb_build_object('ok', false, 'error', sqlerrm); end;
  if st not between 200 and 299 then return jsonb_build_object('ok', false, 'error', sms_err(st, bd)); end if;
  begin j := bd::jsonb; exception when others then j := to_jsonb(bd); end;
  return jsonb_build_object('ok', true, 'credit', j);
end $$;

-- จำนวนที่ส่งแล้ว (สำเร็จ) ของรถแต่ละคัน ในรอบ 45 วันล่าสุด ใช้กันส่งซ้ำ
create or replace function public.sms_recent() returns table(vehicle_id bigint, kind text, sent_at timestamptz)
language sql stable security definer set search_path = public as $$
  select l.vehicle_id, l.kind, max(l.sent_at) from sms_sent l
  where l.ok and l.vehicle_id is not null and l.sent_at > now() - interval '45 days'
    and (my_role() = 'owner' or l.branch_id = my_branch())
  group by l.vehicle_id, l.kind
$$;

revoke all on function public.set_sms_secrets(text, text) from public, anon;
revoke all on function public.sms_secret_status() from public, anon;
revoke all on function public.sms_send(jsonb) from public, anon;
revoke all on function public.sms_credit() from public, anon;
revoke all on function public.sms_recent() from public, anon;
grant execute on function public.set_sms_secrets(text, text) to authenticated;
grant execute on function public.sms_secret_status() to authenticated;
grant execute on function public.sms_send(jsonb) to authenticated;
grant execute on function public.sms_credit() to authenticated;
grant execute on function public.sms_recent() to authenticated;
