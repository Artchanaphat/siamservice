-- ตรอ.สยามเซอร์วิส : ปรับฐานข้อมูลให้ตรงกับหน้าแอป (รันครั้งเดียว หลัง 01-schema.sql)
-- วิธีการชำระเงินในแอปมี เงินสด / โอน / บัตรเครดิต / โอนเข้าบัญชี จึงเลิกล็อกค่าไว้
alter table public.payments drop constraint if exists payments_method_check;
-- เก็บชื่อผู้รับเงิน / ผู้แก้ไข ไว้แสดงในบิล
alter table public.payments   add column if not exists by_name text not null default '';
alter table public.bill_edits add column if not exists by_name text not null default '';
-- เก็บข้อมูลภาษีรถเพิ่ม
alter table public.vehicles add column if not exists prb_company text default '';
