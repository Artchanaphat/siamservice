# HANDOFF: ระบบหลังร้าน ตรอ.สยามเซอร์วิส

อัปเดต 29 ต.ค. 2569 · เวอร์ชันล่าสุด **v114**

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
รันแล้วครบ **01–22** (อาร์ทรันเอง) · รวม **22** (2026-10-29):

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
| 20-auto-backup | รันแล้ว (29 ต.ค. 2569) ตาราง `backup_snapshots` (ไม่มี policy), `_backup_make` (cron `siam-backup-nightly` 02:00 น. เก็บ 14 ชุด ไม่รวม audit_log), RPC เจ้าของ `backup_now` / `backup_list` / `backup_get` · ย้อนกลับ: `select cron.unschedule('siam-backup-nightly'); drop table backup_snapshots cascade;` |
| 21-line-daily-v2 | แทน `daily_summary_text` อีกรอบ: บรรทัด "ตรวจสภาพ n คัน" นับจากบิลที่มี `ค่าตรวจสภาพ` (ผลในคิวอยู่ในวงเล็บ), บรรทัด "รับชำระบิลวันก่อน", กำหนดวันงานขนส่งเกินกำหนดและรายการที่นับเป็นงานขนส่ง อ่านจาก `app_settings.main` (`dlt_late_*`, `dlt_items_tax`, `dlt_items_tr`) · ย้อนกลับ = รัน 18 ซ้ำ |
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
- https://raw.githubusercontent.com/Artchanaphat/siamservice/main/db/20-auto-backup.sql
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
- ~~ไม่มี doctype~~ ใส่แล้วใน v91 (standards mode) เทียบภาพทุกหน้าแล้ว ต่างแค่ 2–4 px
- SQL 20 (สำรองอัตโนมัติ) รันแล้ว 29 ต.ค. 2569
- งานหน้าเพิ่ม easyth ถ้ามีไฟล์: sms_topup, หน้า money_pay เต็ม, รายงาน A4

## 8. งานวันที่ 29 ต.ค. 2569 (v85–v92)
- v85 พิมพ์ทะเบียน/ชื่อ/เบอร์ ในหน้าเปิดบิลและหน้าคิว แสดงลูกค้าเดิมให้เลือก (`carAC`)
- v86 จับคู่บิลกับรถตอนโหลดด้วย Map · ลบ siam-service-style.css
- v87 ล้าง CSS (ลบกฎที่ไม่มีใช้ 172, ค่าที่ถูกทับ 260, คอมเมนต์) บรรทัดละกฎ · สคริปต์เทียบภาพ: โฟลเดอร์ project files `siam-service/tools/` (shot.js, cmp.py, clean.py)
- v88 หน้าปิดยอดแสดงเงินโอนรอตรวจของวันอื่น · v89–v90 ปุ่มเลือกเล่มตัวจริง/สำเนา
- v91 ใส่ `<!doctype html>` · หน้า **ค่าคอมประกัน** (`R.comm`, เมนูการเงิน) อัตรา % ต่อบริษัทใน `SET.comm` = {basis:'net'|'gross', def:[พรบ%,ประกัน%], co:{บริษัท:[..]}} เบี้ยสุทธิ ≈ เบี้ยรวม ÷ 1.07428 · บิลใหม่เก็บ `snapshot.prbCo`
- v92 การ์ด "สำรองอัตโนมัติทุกคืน" ในหน้าสำรองข้อมูล (ต้องรัน SQL 20)


## 9. งานวันที่ 29 ต.ค. 2569 ต่อ (v93–v114)
- v93 แก้ฟอนต์ตารางหลังใส่ doctype (line-height ตารางใน #shell/#dlg = normal)
- v94–v97 หน้ารายจ่าย: เรียงช่อง หมวด → จำนวนเงิน → หมายเหตุ → วันที่, จำหมวดล่าสุด, เจ้าของเพิ่มหมวดได้ในหน้า
- v98–v99 กล่องแจ้งเตือน/ยืนยันของระบบเอง `uiAlert` / `uiConfirm` / `uiPrompt` (แทน alert/confirm/prompt ของเบราว์เซอร์) กลางจอ
- v100 ช่องค้นหาในหน้า (`lsAttach`, `LS_CFG`) คิว / ติดตามงาน / เอกสาร / ปิดยอด / รายจ่าย / ค่าคอม · v102 แก้ช่องค้นหายืดเป็นกล่องใหญ่
- v101 ปุ่ม ‹ › เลื่อนวัน/เดือนในช่องวันที่ (`navAttach`)
- v103 พิมพ์ชื่อ/เบอร์ในบิลใหม่ = แสดงลูกค้าพร้อมรถทุกคันให้เลือก หรือ "＋ รถคันใหม่" (`carAC` โหมดกลุ่มเจ้าของ, `ownerKey`, `ownerCars`, `fillOwner`) รถคันใหม่ผูก `custId` เดิม (เฉพาะชื่อยังตรง) · ช่อง **ผู้มาติดต่อ** (`snapshot.ctn/ctt`) ค้นหาได้ (`ctIdx`) · หน้าบิลแสดงรถคันอื่นของเจ้าของเดียวกัน
- v104 แท็บบริการในบิลใหม่ไฮไลต์เฉพาะแท็บที่ดูอยู่
- v105 หน้าค้นหา "พิมพ์เอกสาร A4" พิมพ์ได้จริง · ซ่อนเมนูข่าวสาร (หน้าต้นแบบ ไม่มีข้อมูลจริง)
- v106 หน้าบิล: กล่อง "ประวัติบิลของรถคันนี้" กดแล้วเปิดแผงด้านข้าง (`bhHTML`, `bhOpen`)
- v107 กดรถที่บิลอยู่อีกสาขา แจ้งว่าบิลอยู่สาขาไหน (`DB.carOtherBranches`)
- v108 หน้าค้นหา: เปิดบิลด้วยไอคอนขวาสุด (คลิกแถวไม่เปิด เพื่อคัดลอกข้อความได้) · แถวอื่นที่คลิกได้ ไม่เปิดถ้ากำลังลากเลือกข้อความ (`selTxt`)
- v109 หน้างานขนส่ง: แยกคอลัมน์ สถานะงาน / การชำระเงิน
- v110–v112 ตั้งค่า › **กำหนดเวลาและการเตือน**: `exp_soon` (ช่วงใกล้หมดอายุ), `dlt_late_received/submitted/plate`, `pick_days` (วันนัดรับเริ่มต้น), `insp_age_car/moto` (อายุรถที่ต้องเสียค่าตรวจ), `dlt_items_tax/tr` (รายการที่นับเป็นงานขนส่ง)
- v113–v114 ปักหมุดรายการในตั้งค่า (ยี่ห้อ ลักษณะรถ คำนำหน้า บริษัทประกัน หมวดรายจ่าย) `SET.pins` รายการที่ปักขึ้นก่อน กดแล้วบันทึกทันที
- ข้อตกลงงาน: อาร์ทไม่ใช้ GPT แล้ว สั่งงาน Claude โดยตรง · ไม่ต้องส่งรูปตัวอย่าง ตอบสั้นเพื่อประหยัด

## 10. v115 + SQL 22 (ตรวจระบบตามรายการ GPT 11 ข้อ)
- **db/22-security-fixes.sql** (ต้องรันเอง): restore_backup แก้คอลัมน์รหัสอัตโนมัติ/เลขบิล/บัญชีผู้ใช้ที่หายไป, เลขบิลเกิน 9999 ไม่ถูกตัด,
  ปิด insert/update ตรงที่ bills/payments/bill_edits (ผ่าน create_bill/add_payments/edit_bill เท่านั้น เป็น security definer),
  เงินโอนรอตรวจเสมอ, decide_bill_action ล็อกเดียวกับรับเงิน + ห้ามอนุมัติถ้ามีโอนรอตรวจ + คืนจากเงินยืนยันแล้ว,
  edit_bill ธุรกรรมเดียว, sms_send ตรวจสาขา, cash_closes คำนวณยอดในฐานข้อมูล + staff แก้ยอดที่ปิดแล้วไม่ได้, schema_status() ให้หน้าตรวจระบบ
- หน้าเว็บ: แก้บิลรอผลจากฐานข้อมูลก่อนขึ้น "บันทึกเรียบร้อย" (ล้มเหลว = ไม่เปลี่ยนอะไร), TODAY เลื่อนวันเองตอนเที่ยงคืน,
  หน้าตรวจระบบเช็ค 19–22 และแยก "เชื่อมต่อแล้ว" กับ "ทดสอบส่งจริง", หน้าสำรองข้อมูลแจ้งข้อจำกัด
- ถ้ายังไม่รัน 22 หน้าเว็บยังใช้ได้ (แก้บิลใช้วิธีเดิม)
