-- ตรอ.สยามเซอร์วิส : ให้เจ้าของร้านสร้างบัญชีพนักงานได้เองในแอป (รันครั้งเดียว หลัง 02-app.sql)
-- ชื่อผู้ใช้ "somchai" จะถูกเก็บเป็นอีเมล somchai@siam.app (ไม่ใช่อีเมลจริง)

create or replace function public.create_staff(p_username text, p_password text, p_full_name text, p_role text, p_branch bigint)
returns uuid language plpgsql security definer set search_path = public, extensions, auth as $$
declare uid uuid := gen_random_uuid(); em text := lower(trim(p_username)) || '@siam.app';
begin
  if coalesce(my_role(), '') <> 'owner' then raise exception 'เฉพาะเจ้าของร้านเท่านั้นที่สร้างบัญชีได้'; end if;
  if lower(trim(p_username)) !~ '^[a-z0-9._-]{3,30}$' then raise exception 'ชื่อผู้ใช้ต้องเป็นภาษาอังกฤษหรือตัวเลข 3-30 ตัว'; end if;
  if length(p_password) < 6 then raise exception 'รหัสผ่านต้องมีอย่างน้อย 6 ตัว'; end if;
  if p_role not in ('owner','head','staff') then raise exception 'ตำแหน่งไม่ถูกต้อง'; end if;
  if p_role <> 'owner' and p_branch is null then raise exception 'กรุณาเลือกสาขา'; end if;
  if exists (select 1 from auth.users where email = em) then raise exception 'ชื่อผู้ใช้นี้มีอยู่แล้ว'; end if;

  insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
                          raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                          confirmation_token, recovery_token, email_change_token_new, email_change)
  values ('00000000-0000-0000-0000-000000000000', uid, 'authenticated', 'authenticated', em,
          crypt(p_password, gen_salt('bf')), now(),
          '{"provider":"email","providers":["email"]}', jsonb_build_object('full_name', p_full_name), now(), now(),
          '', '', '', '');
  insert into auth.identities (id, user_id, provider_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
  values (gen_random_uuid(), uid, uid::text, jsonb_build_object('sub', uid::text, 'email', em, 'email_verified', true),
          'email', now(), now(), now());
  insert into public.staff (user_id, username, full_name, role, branch_id)
  values (uid, lower(trim(p_username)), coalesce(nullif(trim(p_full_name), ''), lower(trim(p_username))), p_role,
          case when p_role = 'owner' then null else p_branch end);
  return uid;
end $$;

-- ตั้งรหัสผ่านใหม่ให้พนักงาน (กรณีลืมรหัส)
create or replace function public.reset_staff_password(p_user uuid, p_password text)
returns void language plpgsql security definer set search_path = public, extensions, auth as $$
begin
  if coalesce(my_role(), '') <> 'owner' then raise exception 'เฉพาะเจ้าของร้านเท่านั้นที่ตั้งรหัสให้คนอื่นได้'; end if;
  if length(p_password) < 6 then raise exception 'รหัสผ่านต้องมีอย่างน้อย 6 ตัว'; end if;
  update auth.users set encrypted_password = crypt(p_password, gen_salt('bf')), updated_at = now() where id = p_user;
  if not found then raise exception 'ไม่พบบัญชีนี้'; end if;
end $$;

revoke all on function public.create_staff(text, text, text, text, bigint) from public, anon;
revoke all on function public.reset_staff_password(uuid, text) from public, anon;
grant execute on function public.create_staff(text, text, text, text, bigint) to authenticated;
grant execute on function public.reset_staff_password(uuid, text) to authenticated;

-- กันเจ้าของร้านปิดบัญชีหรือลดตำแหน่งตัวเองจนเข้าระบบไม่ได้
create or replace function public.guard_self() returns trigger language plpgsql as $$
begin
  if old.user_id = auth.uid() and (new.active is distinct from old.active or new.role is distinct from old.role) then
    raise exception 'แก้ตำแหน่งหรือปิดบัญชีของตัวเองไม่ได้';
  end if;
  return new;
end $$;
drop trigger if exists staff_guard_self on public.staff;
create trigger staff_guard_self before update on public.staff for each row execute function public.guard_self();
