-- 20-auto-backup.sql : สำรองข้อมูลอัตโนมัติทุกคืน 02:00 น. เก็บไว้ในฐานข้อมูล 14 ชุดล่าสุด (รันหลัง 16, รันซ้ำได้)
-- • ใช้รูปแบบเดียวกับไฟล์สำรองจากหน้า "สำรองข้อมูล" ดาวน์โหลดแล้วกู้คืนด้วย restore_backup (16) ได้เลย
-- • ไม่รวม audit_log (ใหญ่และไม่จำเป็นต่อการกู้งาน), รูป/PDF, รหัสผ่าน และรหัส LINE/SMS
-- • ดู/ดาวน์โหลด/สำรองทันที ได้เฉพาะเจ้าของร้าน (หน้า ตั้งค่าระบบ › สำรองข้อมูล)
-- • ตารางนี้ไม่มี policy ใดๆ เข้าถึงได้ผ่านฟังก์ชันด้านล่างเท่านั้น
-- ย้อนกลับ: select cron.unschedule('siam-backup-nightly'); drop table public.backup_snapshots cascade;

create table if not exists public.backup_snapshots (
  id         bigint generated always as identity primary key,
  created_at timestamptz not null default now(),
  kind       text not null default 'auto' check (kind in ('auto','manual')),
  size_bytes int,
  counts     jsonb not null default '{}',
  skipped    jsonb not null default '[]',
  data       jsonb not null
);
alter table public.backup_snapshots enable row level security;
revoke all on public.backup_snapshots from anon, authenticated;

-- สร้างชุดสำรอง (ไม่เปิดให้เรียกจากหน้าเว็บโดยตรง)
create or replace function public._backup_make(p_kind text default 'auto') returns bigint
language plpgsql security definer set search_path = public as $$
declare t text; k text; cols text; d jsonb := '{}'; c jsonb := '{}'; sk jsonb := '[]'; arr jsonb; nid bigint;
  tabs text[][] := array[['branches','id','*'],['staff','user_id','user_id,username,full_name,role,branch_id,active,created_at'],
    ['customers','id','*'],['vehicles','id','*'],['bills','id','*'],['payments','id','*'],['bill_edits','id','*'],['dlt_jobs','bill_id','*'],
    ['bill_files','id','*'],['bill_requests','id','*'],['insp_queue','id','*'],['cash_closes','id','*'],['expenses','id','*'],
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

-- เจ้าของร้าน: สำรองทันที
create or replace function public.backup_now() returns bigint
language plpgsql security definer set search_path = public as $$
begin
  if my_role() is distinct from 'owner' then raise exception 'เฉพาะเจ้าของร้าน'; end if;
  return _backup_make('manual');
end $$;

-- เจ้าของร้าน: รายการชุดสำรอง
create or replace function public.backup_list() returns table (id bigint, created_at timestamptz, kind text, size_bytes int, counts jsonb, skipped jsonb)
language plpgsql security definer set search_path = public as $$
begin
  if my_role() is distinct from 'owner' then raise exception 'เฉพาะเจ้าของร้าน'; end if;
  return query select b.id, b.created_at, b.kind, b.size_bytes, b.counts, b.skipped from backup_snapshots b order by b.created_at desc;
end $$;

-- เจ้าของร้าน: ดึงข้อมูลชุดสำรอง (หน้าเว็บประกอบเป็นไฟล์ .json แบบเดียวกับที่ดาวน์โหลดเอง)
create or replace function public.backup_get(p_id bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r backup_snapshots;
begin
  if my_role() is distinct from 'owner' then raise exception 'เฉพาะเจ้าของร้าน'; end if;
  select * into r from backup_snapshots where id = p_id;
  if not found then raise exception 'ไม่พบชุดสำรองนี้'; end if;
  return jsonb_build_object('created_at', r.created_at, 'kind', r.kind, 'counts', r.counts, 'skipped', r.skipped, 'data', r.data);
end $$;

revoke all on function public.backup_now(), public.backup_list(), public.backup_get(bigint) from public, anon;
grant execute on function public.backup_now(), public.backup_list(), public.backup_get(bigint) to authenticated;

-- ทุกคืน 02:00 น. เวลาไทย (19:00 UTC)
select cron.unschedule(jobid) from cron.job where jobname = 'siam-backup-nightly';
select cron.schedule('siam-backup-nightly', '0 19 * * *', 'select public._backup_make(''auto'')');

-- ทำชุดแรกทันที
select public._backup_make('auto') as first_backup_id;
