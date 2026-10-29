-- 26-backup-remits.sql : ให้ระบบสำรองข้อมูล (อัตโนมัติตี 2 + กู้คืน) รวมตาราง "เงินนำส่ง" (remits) ด้วย  (รันหลัง 25, รันซ้ำได้)
-- วิธีรัน: Supabase › SQL Editor › New query › วางทั้งไฟล์ › Run  (ไม่ลบ/ไม่แก้ข้อมูลเดิม)
-- หมายเหตุ: เงินทอนตั้งต้น (cash_closes.float_cash) ถูกสำรองอยู่แล้วเพราะสำรองทุกคอลัมน์ของตารางปิดยอด

create or replace function public._backup_make(p_kind text default 'auto') returns bigint
language plpgsql security definer set search_path = public as $$
declare t text; k text; cols text; d jsonb := '{}'; c jsonb := '{}'; sk jsonb := '[]'; arr jsonb; nid bigint;
  tabs text[][] := array[['branches','id','*'],['staff','user_id','user_id,username,full_name,role,branch_id,active,created_at'],
    ['customers','id','*'],['vehicles','id','*'],['bills','id','*'],['payments','id','*'],['bill_edits','id','*'],['dlt_jobs','bill_id','*'],
    ['bill_files','id','*'],['bill_requests','id','*'],['insp_queue','id','*'],['cash_closes','id','*'],['expenses','id','*'],['remits','id','*'],
    ['app_settings','key','*'],['news','id','*']];
  i int;
begin
  for i in 1..array_length(tabs,1) loop
    t := tabs[i][1]; k := tabs[i][2]; cols := tabs[i][3];
    if to_regclass('public.' || t) is null then sk := sk || to_jsonb(t); continue; end if;
    begin
      execute format('select coalesce(jsonb_agg(to_jsonb(x) order by x.%I), ''[]'') from (select %s from public.%I) x', k, cols, t) into arr;
    exception when others then sk := sk || to_jsonb(t); continue;
    end;
    d := d || jsonb_build_object(t, arr); c := c || jsonb_build_object(t, jsonb_array_length(arr));
  end loop;
  insert into backup_snapshots (kind, size_bytes, counts, skipped, data)
  values (coalesce(p_kind,'auto'), octet_length(d::text), c, sk, d) returning id into nid;
  -- เก็บ 14 ชุดล่าสุด
  delete from backup_snapshots where id not in (select id from backup_snapshots order by created_at desc limit 14);
  return nid;
end $$;
revoke all on function public._backup_make(text) from public, anon, authenticated;

create or replace function public.restore_backup(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare t text; n int; out jsonb := '{}'; total int := 0; seq text; cols text; sel text; idc text;
  tabs text[] := array['branches','customers','vehicles','bills','payments','bill_edits','dlt_jobs','bill_files','bill_requests',
                       'insp_queue','cash_closes','expenses','remits','app_settings','news','audit_log'];
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
