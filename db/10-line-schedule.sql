-- ตรอ.สยามเซอร์วิส : เจ้าของร้านตั้งเวลาส่ง LINE เองจากหน้าตั้งค่า
-- รันครั้งเดียว หลัง 06 และ 07 (รันซ้ำได้)
-- เวลาในแอปเป็นเวลาไทย ระบบแปลงเป็น UTC (ไทย - 7 ชม.) ให้ pg_cron เอง

-- 'HH:MM' เวลาไทย -> 'M H * * *' แบบ UTC
create or replace function public.bkk_cron(p_time text) returns text
language plpgsql immutable as $$
declare h int; m int;
begin
  if p_time !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' then raise exception 'เวลาไม่ถูกต้อง: %', p_time; end if;
  h := split_part(p_time, ':', 1)::int; m := split_part(p_time, ':', 2)::int;
  return m || ' ' || ((h + 17) % 24) || ' * * *';
end $$;

-- 'M H * * *' แบบ UTC -> 'HH:MM' เวลาไทย
create or replace function public.cron_bkk(p_expr text) returns text
language sql immutable as $$
  select lpad(((split_part(p_expr, ' ', 2)::int + 7) % 24)::text, 2, '0') || ':' ||
         lpad(split_part(p_expr, ' ', 1), 2, '0')
$$;

-- เวลาที่ตั้งไว้ตอนนี้
create or replace function public.line_schedule() returns jsonb
language plpgsql security definer set search_path = public as $$
declare d text; r text;
begin
  if coalesce(my_role(), '') <> 'owner' then raise exception 'เฉพาะเจ้าของร้านเท่านั้น'; end if;
  select schedule into d from cron.job where jobname = 'siam-line-daily';
  select schedule into r from cron.job where jobname = 'siam-line-remind';
  return jsonb_build_object(
    'daily',  case when d is null then null else cron_bkk(d) end,
    'remind', case when r is null then null else cron_bkk(r) end);
end $$;

-- ตั้งเวลาใหม่ (สรุปเจ้าของร้าน, เตือนลูกค้า) ค่าว่าง = ไม่เปลี่ยน
-- ถ้าส่งสรุปก่อนเที่ยง จะส่งสรุปของ "เมื่อวาน" เพราะวันนี้ยังไม่จบ
create or replace function public.set_line_schedule(p_daily text, p_remind text) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if coalesce(my_role(), '') <> 'owner' then raise exception 'เฉพาะเจ้าของร้านเท่านั้น'; end if;
  if nullif(trim(p_daily), '') is not null then
    perform cron.schedule('siam-line-daily', bkk_cron(trim(p_daily)),
      case when trim(p_daily) < '12:00'
        then 'select public.send_line_daily((now() at time zone ''Asia/Bangkok'')::date - 1)'
        else 'select public.send_line_daily()' end);
  end if;
  if nullif(trim(p_remind), '') is not null then
    perform cron.schedule('siam-line-remind', bkk_cron(trim(p_remind)), 'select public.send_line_reminders()');
  end if;
  return line_schedule();
end $$;

revoke all on function public.line_schedule() from public, anon;
revoke all on function public.set_line_schedule(text, text) from public, anon;
grant execute on function public.line_schedule() to authenticated;
grant execute on function public.set_line_schedule(text, text) to authenticated;
