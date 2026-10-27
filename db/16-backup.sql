-- 16-backup.sql : กู้คืนข้อมูลจากไฟล์สำรอง (JSON) ที่ดาวน์โหลดจากหน้า "สำรองข้อมูล" (รันหลัง 15, รันซ้ำได้)
-- หลักการ: กู้คืนแบบ "เติมส่วนที่หายไป" เท่านั้น
--   • แถวที่มีอยู่แล้วในฐานข้อมูล (รหัสเดียวกัน) จะไม่ถูกแก้หรือทับ
--   • ไม่ลบข้อมูลใดในฐานข้อมูล
--   • ไม่กู้บัญชีผู้ใช้/รหัสผ่าน (staff) และรหัสลับ LINE/SMS (อยู่ใน Vault ไม่อยู่ในไฟล์สำรอง)
--   • รูปภาพ/PDF ในที่เก็บไฟล์ไม่อยู่ในไฟล์สำรอง (มีเฉพาะรายชื่อไฟล์)
-- ใช้ได้เฉพาะเจ้าของร้าน

-- trigger เอกสารแนบ (14) ข้ามการตัดรายการ "เอกสารที่ขาด" ระหว่างกู้คืน (siam.restoring = 1)

create or replace function public.restore_backup(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare t text; n int; out jsonb := '{}'; total int := 0; seq text; cols text;
  -- เรียงตามความสัมพันธ์ของตาราง (ตารางแม่ก่อน)
  tabs text[] := array['branches','customers','vehicles','bills','payments','bill_edits','dlt_jobs','bill_files','bill_requests',
                       'insp_queue','cash_closes','expenses','app_settings','news','audit_log'];
begin
  if my_role() is distinct from 'owner' then raise exception 'กู้คืนข้อมูลได้เฉพาะเจ้าของร้าน'; end if;
  if p is null or p->>'app' is distinct from 'siam-service-backup' then raise exception 'ไฟล์นี้ไม่ใช่ไฟล์สำรองของระบบ'; end if;
  perform set_config('siam.restoring', '1', true);
  foreach t in array tabs loop
    if p->'data' ? t and to_regclass('public.' || t) is not null then
      -- ใส่เฉพาะคอลัมน์ที่มีในไฟล์ (คอลัมน์ที่เพิ่มทีหลังใช้ค่าเริ่มต้น เช่น ไฟล์สำรองก่อนรัน SQL ใหม่)
      select string_agg(quote_ident(c.column_name), ',' order by c.ordinal_position) into cols
        from information_schema.columns c
       where c.table_schema = 'public' and c.table_name = t
         and not exists (select 1 from jsonb_array_elements(p->'data'->t) e where not e ? c.column_name);
      if cols is null then continue; end if;
      execute format('insert into public.%I (%s) overriding system value select %s from jsonb_populate_recordset(null::public.%I, $1) on conflict do nothing', t, cols, cols, t)
        using p->'data'->t;
      get diagnostics n = row_count;
      out := out || jsonb_build_object(t, n); total := total + n;
      seq := pg_get_serial_sequence('public.' || t, 'id');
      if seq is not null then
        execute format('select setval(%L, greatest(coalesce((select max(id) from public.%I), 0), 1))', seq, t);
      end if;
    end if;
  end loop;
  -- เลขบิลถัดไปต้องต่อจากเลขสูงสุดที่มี (กันเลขบิลซ้ำหลังกู้คืน)
  insert into bill_counters (branch_id, be_year, last_no)
  select branch_id, extract(year from (bill_at at time zone 'Asia/Bangkok'))::int + 543, max(nullif(regexp_replace(right(bill_no, 4), '\D', '', 'g'), '')::int)
    from bills group by 1, 2
  on conflict (branch_id, be_year) do update set last_no = greatest(bill_counters.last_no, excluded.last_no);
  perform set_config('siam.restoring', '0', true);
  return jsonb_build_object('inserted', out, 'total', total);
end $$;
revoke all on function public.restore_backup(jsonb) from public, anon;
grant execute on function public.restore_backup(jsonb) to authenticated;
