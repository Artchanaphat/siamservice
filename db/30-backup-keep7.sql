-- 30-backup-keep7.sql : สำรองอัตโนมัติเก็บ 7 ชุดล่าสุด (เดิม 14) เพื่อประหยัดพื้นที่ฐานข้อมูล (รันหลัง 29, รันซ้ำได้)
-- วิธีรัน: Supabase › SQL Editor › New query › วางทั้งไฟล์ › Run
-- ย้อนกลับ: รัน 28-owner-overview.sql อีกครั้ง (กลับเป็น 14 ชุด)

create or replace function public._backup_make(p_kind text default 'auto') returns bigint
language plpgsql security definer set search_path = public as $$
declare t text; k text; cols text; d jsonb := '{}'; c jsonb := '{}'; sk jsonb := '[]'; arr jsonb; nid bigint;
  tabs text[][] := array[['branches','id','*'],['staff','user_id','user_id,username,full_name,role,branch_id,active,created_at'],
    ['customers','id','*'],['vehicles','id','*'],['bills','id','*'],['payments','id','*'],['bill_edits','id','*'],['dlt_jobs','bill_id','*'],
    ['bill_files','id','*'],['bill_requests','id','*'],['insp_queue','id','*'],['cash_closes','id','*'],['expenses','id','*'],['remits','id','*'],['cash_outs','id','*'],['exp_requests','id','*'],['close_acks','branch_id','*'],
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
  -- เก็บ 7 ชุดล่าสุด
  delete from backup_snapshots where id not in (select id from backup_snapshots order by created_at desc limit 7);
  return nid;
end $$;
revoke all on function public._backup_make(text) from public, anon, authenticated;

-- ลบชุดเก่าที่เกิน 7 ชุดทันที
delete from public.backup_snapshots where id not in (select id from public.backup_snapshots order by created_at desc limit 7);

-- ตรวจผล: select count(*) from backup_snapshots;  -- ต้องได้ไม่เกิน 7
