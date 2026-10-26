-- ตรอ.สยามเซอร์วิส : ให้เจ้าของร้านใส่รหัส LINE ในหน้าตั้งค่าของแอปได้เอง
-- รันครั้งเดียว หลัง 07-expense-line.sql (รันซ้ำได้)
-- รหัสเก็บใน Supabase Vault (เข้ารหัส) แอปอ่านกลับได้แค่ 4 ตัวท้าย ไม่เคยส่งรหัสเต็มกลับไป

-- เก็บ/แก้ค่าใน Vault ตามชื่อ
create or replace function public.vault_put(p_name text, p_value text) returns void
language plpgsql security definer set search_path = public as $$
declare sid uuid;
begin
  select id into sid from vault.secrets where name = p_name;
  if sid is null then perform vault.create_secret(p_value, p_name);
  else perform vault.update_secret(sid, p_value); end if;
end $$;
revoke all on function public.vault_put(text, text) from public, anon, authenticated;

-- บันทึกจากหน้าตั้งค่า (ช่องที่เว้นว่าง = ไม่เปลี่ยน)
create or replace function public.set_line_secrets(p_token text, p_to text, p_secret text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if coalesce(my_role(), '') <> 'owner' then raise exception 'เฉพาะเจ้าของร้านเท่านั้น'; end if;
  if nullif(trim(p_token), '') is not null then
    if length(trim(p_token)) < 100 then raise exception 'Channel access token สั้นเกินไป ตรวจว่าคัดลอกมาครบ'; end if;
    perform vault_put('line_token', trim(p_token));
  end if;
  if p_to is not null then
    if trim(p_to) <> '' and exists (select 1 from regexp_split_to_table(trim(p_to), '\s*,\s*') u where u !~ '^U[0-9a-f]{32}$') then
      raise exception 'User ID ต้องขึ้นต้นด้วย U ตามด้วยตัวอักษร 32 ตัว (หลายคนคั่นด้วย ,)';
    end if;
    perform vault_put('line_to', trim(p_to));
  end if;
  if nullif(trim(p_secret), '') is not null then
    if trim(p_secret) !~ '^[0-9a-f]{32}$' then raise exception 'Channel secret ต้องเป็นตัวอักษร 32 ตัว'; end if;
    perform vault_put('line_channel_secret', trim(p_secret));
  end if;
end $$;

-- สถานะสำหรับแสดงในหน้าตั้งค่า (ไม่ส่งรหัสเต็ม)
create or replace function public.line_secret_status() returns jsonb
language plpgsql security definer set search_path = public as $$
declare t text; u text; s text;
begin
  if coalesce(my_role(), '') <> 'owner' then raise exception 'เฉพาะเจ้าของร้านเท่านั้น'; end if;
  select decrypted_secret into t from vault.decrypted_secrets where name = 'line_token';
  select decrypted_secret into u from vault.decrypted_secrets where name = 'line_to';
  select decrypted_secret into s from vault.decrypted_secrets where name = 'line_channel_secret';
  return jsonb_build_object(
    'token', case when coalesce(t, '') = '' then null else '••••' || right(t, 4) end,
    'to', coalesce(u, ''),
    'secret', case when coalesce(s, '') = '' then null else '••••' || right(s, 4) end);
end $$;

revoke all on function public.set_line_secrets(text, text, text) from public, anon;
revoke all on function public.line_secret_status() from public, anon;
grant execute on function public.set_line_secrets(text, text, text) to authenticated;
grant execute on function public.line_secret_status() to authenticated;

-- Edge Function line-webhook อ่าน Channel secret จากที่นี่ (เฉพาะ service_role)
create or replace function public.line_channel_secret() returns text
language sql stable security definer set search_path = public as $$
  select decrypted_secret from vault.decrypted_secrets where name = 'line_channel_secret'
$$;
revoke all on function public.line_channel_secret() from public, anon, authenticated;
grant execute on function public.line_channel_secret() to service_role;
