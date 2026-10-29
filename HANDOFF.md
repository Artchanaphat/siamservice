# HANDOFF: ระบบหลังร้าน ตรอ.สยามเซอร์วิส

อัปเดต 28 ต.ค. 2569 · เวอร์ชันล่าสุด **v79** (commit 0736008)

> ไฟล์นี้ไม่มี secret ใดๆ (ไม่มี service_role key, รหัสผ่าน, LINE token/secret, SMS API key) บอกแค่ว่าแต่ละอย่างเก็บไว้ที่ไหน

## 1. ร้าน
- สาขา 1: ตรอ.สยามเซอร์วิส, 60 ซ.พนาสณฑ์ ต.บางนาค อ.เมืองนราธิวาส จ.นราธิวาส 96000, โทร 098-672-1018
- สาขา 2: ตรอ.สยามเซอร์วิส 2, 98 ต.ลำภู อ.เมือง จ.นราธิวาส 96000, โทร 098-106-1655
- จะเพิ่มสาขาในอนาคต ระบบออกแบบเป็นหลายสาขา: ลูกค้า/รถใช้ร่วมกัน ส่วนบิล การรับเงิน ปิดยอด และเครดิต SMS แยกตามสาขา
- สิทธิ์ผู้ใช้: owner (ทุกสาขา), head (หัวหน้าสาขา), staff บังคับด้วย RLS ในฐานข้อมูล
- ต้นแบบหน้าตา: easyth (pro.easyth.com) แถบฟ้า #00adef, Tahoma

## 2. บริการที่เชื่อมต่อ

| บริการ | รายละเอียด | secret เก็บที่ไหน |
|---|---|---|
| GitHub | repo `Artchanaphat/siamservice` (public) branch `main` = เว็บจริง | บัญชี GitHub ของอาร์ท |
| Cloudflare Pages | https://siamservice.pages.dev deploy อัตโนมัติทุกครั้งที่ push `main` (ไม่มี build step เสิร์ฟ `index.html` ตรงๆ) | บัญชี Cloudflare ของอาร์ท |
| GitHub Pages (เก่า) | https://artchanaphat.github.io/siamservice/ ยังเปิดอยู่ รอปิด | – |
| Supabase | https://plilxmgripxmebvjafmj.supabase.co · Free plan · region Singapore · project "SiamService" (project เก่าที่ Tokyo ไม่ใช้แล้ว) | publishable key (public) อยู่ใน `index.html` ได้ · service_role key และรหัส DB อยู่ใน Supabase Dashboard เท่านั้น |
| Supabase Auth | ปิดการสมัครเองแล้ว ผู้ใช้ล็อกอินด้วย username → `username@siam.app` · owner = `admin@siam.app` · owner สร้างพนักงานในแอป (RPC `create_staff`) | รหัสผ่าน owner อาร์ทเก็บเอง |
| Supabase Storage | bucket ส่วนตัว `bill-files` (ไฟล์แนบบิล รูป/PDF ≤10MB) และ `staff-avatars` (รูปพนักงาน) | – |
| LINE OA | @199rtjci · Messaging API · webhook = Supabase Edge Function `line-webhook` (โค้ดใน `supabase/functions/line-webhook/index.ts`, Verify JWT ปิด) · Use webhook เปิด, Auto-reply ปิด | Channel access token / user id ปลายทาง / channel secret อยู่ใน **Supabase Vault** (owner กรอกที่หน้า ตั้งค่าระบบ ผ่าน RPC `set_line_secrets`) · Edge Function ใช้ secret `LINE_CHANNEL_SECRET` ใน Edge Function Secrets |
| LINE cron | pg_cron + pg_net: `siam-line-daily` (สรุปประจำวันเข้า LINE เจ้าของ, ค่าเริ่ม 20:00 น.) และ `siam-line-remind` (เตือนลูกค้าภาษีใกล้หมด, ค่าเริ่ม 09:00 น.) เปลี่ยนเวลาได้ที่หน้าตั้งค่า (RPC `set_line_schedule`) · พิมพ์ "ไอดี" ใน LINE OA ระบบตอบ User ID · ลูกค้าผูก LINE ผ่าน QR + รหัส 6 หลักบนใบเสร็จ | Vault |
| SMS ThaiBulkSMS | SQL 11 รันแล้ว (RPC `sms_send`, `sms_credit`, `sms_recent`, ตาราง `sms_sent`) **แต่ยังไม่ได้ตั้ง API key และชื่อผู้ส่ง** คู่มือ: `SMS-setup.md` ในโฟลเดอร์โปรเจกต์ | API key/secret จะเก็บใน Vault (owner กรอกที่หน้าตั้งค่า ผ่าน `set_sms_secrets`) |
| PromptPay QR | สร้างในเบราว์เซอร์ เบอร์/เลข PromptPay อยู่ใน `branches.promptpay` | – |

## 3. ฐานข้อมูล (SQL ใน `db/` รันใน Supabase SQL Editor ตามลำดับ)
รันแล้วครบ **01–19** (อาร์ทรันเอง):

| ไฟล์ | เนื้อหา |
|---|---|
| 01-schema | ตารางหลัก (branches, staff, customers, vehicles, bills, payments ฯลฯ), RLS, เลขบิลแบบ A-690001 ต่อสาขา/ปี พ.ศ. |
| 02-app | ปรับคอลัมน์ payments / by_name |
| 03-staff | `create_staff`, `reset_staff_password`, trigger `guard_self` |
| 04-dlt | `dlt_jobs` งานขนส่ง |
| 05-features | `cash_closes`, `insp_queue`, `app_settings` (key 'main' = ค่าตั้งค่าทั้งหมด), ข้อมูลร้านจริง |
| 06-line-daily | สรุปประจำวัน `daily_summary_text`, `send_line_daily`, cron |
| 07-expense-line | `expenses`, `monthly_stats`, ผูก LINE ลูกค้า, เตือนลูกค้า, `audit_log` |
| 08 / 09 / 10 | ตั้งค่า LINE ในแอป / คำสั่ง "ไอดี" / ตั้งเวลา cron |
| 11-files-sms | `bill_files` + bucket, SMS ThaiBulkSMS |
| 12-car-type-fix | แก้ประเภทรถ 4 บิล (12-car-type-check = ไฟล์ตรวจ) |
| 13-transfer-verify | สถานะเงินโอน pending / verified / rejected (`verify_payment`, `reject_payment`) |
| 14-safe-bills | **RPC บิลปลอดภัย** `create_bill`, `add_payments` (transaction เดียว + idempotency key), `refresh_bill_status`, `bill_net_paid` |
| 15-void-refund | `bill_requests` ยกเลิก/คืนเงินต้องอนุมัติ (`request_bill_action`, `decide_bill_action`) หัวหน้าอนุมัติคำขอตัวเองไม่ได้ |
| 16-backup | `restore_backup` (กู้จาก JSON แบบเพิ่มเฉพาะที่ไม่มี) |
| 17-staff-avatar | bucket `staff-avatars`, `staff.avatar_path`, `set_staff_avatar_v1` (+ ไฟล์ check / rollback) |
| 18-line-daily-fix | แก้เฉพาะ `daily_summary_text`: นับเฉพาะเงินที่ verified, หักคืนเงิน, ยอดบิล = total − refund_total, แสดงเงินโอนรอตรวจ, เตือนยอดเปลี่ยนหลังปิดยอด (รันซ้ำได้; ย้อนกลับ = รันฟังก์ชันจาก 06 ซ้ำ) |
| 19-close-pending-guard | trigger บน `cash_closes`: staff บันทึกปิดยอดไม่ได้ถ้าวันนั้นมีเงินโอนรอตรวจ (owner/head ได้) ย้อนกลับ = drop trigger `cash_closes_pending_guard` |

### ลิงก์ raw ของไฟล์ (เปิดอ่านได้ตรง)
- https://raw.githubusercontent.com/Artchanaphat/siamservice/main/db/01-schema.sql
- https://raw.githubusercontent.com/Artchanaphat/siamservice/main/db/02-app.sql
- https://raw.githubusercontent.com/Artchanaphat/siamservice/main/db/03-staff.sql
- https://raw.githubusercontent.com/Artchanaphat/siamservice/main/db/04-dlt.sql
- https://raw.githubusercontent.com/Artchanaphat/siamservice/main/db/05-features.sql
- https://raw.githubusercontent.com/Artchanaphat/siamservice/main/db/06-line-daily.sql
- https://raw.githubusercontent.com/Artchanaphat/siamservice/main/db/07-expense-line.sql
- https://raw.githubusercontent.com/Artchanaphat/siamservice/main/db/08-line-settings.sql
- https://raw.githubusercontent.com/Artchanaphat/siamservice/main/db/09-line-myid.sql
- https://raw.githubusercontent.com/Artchanaphat/siamservice/main/db/10-line-schedule.sql
- https://raw.githubusercontent.com/Artchanaphat/siamservice/main/db/11-files-sms.sql
- https://raw.githubusercontent.com/Artchanaphat/siamservice/main/db/12-car-type-check.sql
- https://raw.githubusercontent.com/Artchanaphat/siamservice/main/db/12-car-type-fix.sql
- https://raw.githubusercontent.com/Artchanaphat/siamservice/main/db/13-transfer-verify.sql
- https://raw.githubusercontent.com/Artchanaphat/siamservice/main/db/14-safe-bills.sql
- https://raw.githubusercontent.com/Artchanaphat/siamservice/main/db/15-void-refund.sql
- https://raw.githubusercontent.com/Artchanaphat/siamservice/main/db/16-backup.sql
- https://raw.githubusercontent.com/Artchanaphat/siamservice/main/db/17-staff-avatar-check.sql
- https://raw.githubusercontent.com/Artchanaphat/siamservice/main/db/17-staff-avatar-rollback.sql
- https://raw.githubusercontent.com/Artchanaphat/siamservice/main/db/17-staff-avatar.sql
- https://raw.githubusercontent.com/Artchanaphat/siamservice/main/db/18-line-daily-fix.sql
- https://raw.githubusercontent.com/Artchanaphat/siamservice/main/db/19-close-pending-guard.sql
- https://raw.githubusercontent.com/Artchanaphat/siamservice/main/supabase/functions/line-webhook/index.ts
- https://raw.githubusercontent.com/Artchanaphat/siamservice/main/index.html (แอปทั้งหมด ~1.15 MB)

## 4. โครงสร้างโค้ด
- `index.html` (~1.15 MB) = **แอปทั้งหมดในไฟล์เดียว** (HTML + CSS + JS) ใช้ supabase-js จาก jsdelivr · บรรทัด 1 มี `<meta charset>` แต่ไม่มี doctype (quirks mode ห้ามเพิ่ม doctype โดยไม่ทดสอบ layout/ใบเสร็จใหม่)
  - `<style>` หลักแรกสุด (บรรทัด ~8) แล้วตามด้วยชั้น CSS ที่ GPT ทำ (มี id เช่น `siamservice-ux-unify-v2`, `siamservice-pay-drawer-v1` ฯลฯ)
  - `<script id="boot-chk">` แล้ว `<script>` หลัก (~บรรทัด 2313) มีสูตรภาษี (`carTax`, `pickupTax`), ค่าตั้งค่าเริ่มต้น `SET_DEF`, การโหลดข้อมูล, ทุกหน้า
  - หน้า (เรียกด้วย `go('...')`): home, add (เปิดบิล), bill (รายละเอียด), edit, cust (ค้นหาลูกค้า/รถ), docs, income (รายได้/ยอดค้าง), inst (ผ่อนประกัน), sms, dlt (งานขนส่ง), queue (คิวตรวจ), track (ติดตามงาน 5 ขั้น), close (ปิดยอด), bell, settings · มีหน้าตรวจสอบระบบ/สำรองข้อมูล/audit (owner)
  - เทมเพลตพิมพ์ใบเสร็จอยู่ท้ายไฟล์ (`<style>` ตัวท้ายสุดเป็นของใบเสร็จ) **ห้ามแทรก CSS ที่ `</style>` ตัวสุดท้าย** ให้แทรกที่ตัวแรก
  - โหมด demo (ปุ่มล็อกอินทดลอง) แสดงเฉพาะ file:// หรือ host ที่มี "claude"
- `siam-service-style.css` (CSS เก่า v57) ลบออกจาก repo แล้วใน v86 ห้ามเพิ่ม `<link>` CSS ภายนอกกลับ
- `db/*.sql`, `supabase/functions/line-webhook/index.ts`

## 5. กฎห้ามแก้
1. **CSS ใบเสร็จ `rc-` / `rcx-`** (A4 แบ่งครึ่ง ต้นฉบับร้าน/สำเนาลูกค้า มีเส้นปะให้ฉีก) ต้องได้ภาพ PNG เหมือนเดิมทุกพิกเซลหลังแก้
2. **สูตรภาษี/ค่าบริการ** (ตาม easyth main.js): ค่า ตรอ. เฉพาะรถเกิน 7 ปี (จยย. เกิน 5 ปี), ค่าปรับ 1%/เดือน เศษเดือนนับเต็มเดือน, รถตู้/EV ใช้ตารางน้ำหนัก, ภาษีที่พิมพ์เองห้ามคำนวณทับ, ยอดรวมตาม recalcSum
3. **RPC บิลปลอดภัย** (`create_bill`, `add_payments` และ flow ยกเลิก/คืนเงิน) ห้ามเปลี่ยนให้เขียนตารางตรง
4. ห้ามเปลี่ยนชื่อ/ลบ id, class, ฟังก์ชันเดิม
5. เปลี่ยนโครงสร้าง DB ต้องทำเป็นไฟล์ SQL ใหม่ให้อาร์ทรันเอง ห้ามใส่ข้อมูลทดสอบลง DB จริง
6. ห้ามขอ service_role key, รหัส DB, LINE secret, SMS key ในแชท
7. UI: ภาษาไทยสุภาพ ฟอร์มว่าง ไม่มีข้อมูลตัวอย่าง ไม่มีเลื่อนจอแนวนอน dropdown เปิดลงล่าง ใช้ปุ่มเลือกแทนพิมพ์
8. ไฟล์จาก GPT มักทำบนเวอร์ชันเก่า ให้ merge ลง main ล่าสุด (ใช้ diff/สคริปต์ ไม่ใช้ index.html ทั้งไฟล์)

## 6. ประวัติล่าสุด
- v59 บิลปลอดภัย, ยกเลิก/คืนเงินมีอนุมัติ, ติดตามงาน, สำรองข้อมูล, realtime
- v60–v66 ชั้น CSS จาก GPT, ค้นหาบนแถบบน, รูปพนักงาน (v61), ตัวเลือกสาขาบนแถบบน
- v67–v70 กัน Chrome เติมรหัสอัตโนมัติ, หน้าอัปเดตงานขนส่ง, ใบเสร็จ A4 เป็นปุ่มหลัก (สลิปม้วนซ่อนถ้าไม่เปิดในตั้งค่า)
- v71 แผง "รับชำระยอดค้าง" · v72 ตัวกรองรายได้/ผ่อน · v73–v74 แก้บันทึกตั้งค่า
- v75 รายงานการเงินนับเฉพาะเงินโอนที่ตรวจแล้ว, "ทั้งหมด" โหลดบิลเก่าเมื่อเลือก
- v76 ชื่อเดือนไทยเต็ม (วันที่ในใบเสร็จ, ชิปเดือน, ตัวเลือกวันที่, รายงาน)
- v77 เปิดบิลโหมด "ตรวจสภาพอย่างเดียว" (ไม่คิดภาษี/พ.ร.บ./ฝากต่อภาษี)
- v78 หน้าจอแสดง 90% บนจอกว้าง, โหมดตรวจอย่างเดียวซ่อนช่องภาษี/พ.ร.บ.
- **v79** แถวชิปบริการอยู่กลาง ไม่ขึ้นบรรทัดใหม่

## 7. สถานะงานค้าง (28 ต.ค. 2569)
อาร์ทแจ้งว่าทำเสร็จแล้ว:
- ตั้งค่า SMS ThaiBulkSMS, ปิด GitHub Pages เดิม, ตรวจหน้า "ตรวจสอบระบบ" บน pages.dev, เรื่อง backup

ยังค้างจริง (ตรวจจาก repo):
- SQL 18 และ 19 รันแล้ว (อาร์ท 29 ต.ค. 2569)
- ~~ปิดยอดได้แม้มีเงินโอนรอตรวจ~~ แก้แล้วใน v80: พนักงานปิดไม่ได้ หัวหน้า/เจ้าของปิดได้หลังยืนยัน และเช็คฝั่ง DB ด้วย SQL 19 (รันแล้ว 29 ต.ค.)
- ไม่มี doctype (quirks mode) แก้ได้แต่ต้องทดสอบทั้งระบบ
- งานหน้าเพิ่ม easyth ถ้ามีไฟล์: sms_topup, หน้า money_pay เต็ม, รายงาน A4
