# ระบบหลังบ้านบน Cloudflare (แทน Supabase)

- `functions/api/[[path]].js` → `cf/api.js` : API ทั้งหมดอยู่ที่ `/api/*` (Cloudflare Pages Functions)
- Bindings ของโปรเจกต์ Pages: `DB` = D1 `siam-db`, `FILES` = R2 `siam-files`
- `cf/lib/schema.js` : สร้างตารางให้อัตโนมัติตอนเรียก API ครั้งแรก (เพิ่มของใหม่ = เพิ่มใน MIGRATIONS + เพิ่ม VERSION)
- `cf/lib/query.js` : รับคำสั่งแบบ supabase-js (`from().select().eq()`) + สิทธิ์ตามตำแหน่ง/สาขา (แทน RLS)
- `cf/lib/hooks.js` : งานที่เคยเป็น trigger (ประวัติการใช้งาน, ปิดยอด, ไฟล์แนบ, ซิงก์)
- `cf/lib/rpc*.js` : ฟังก์ชันเดิมของ Supabase ชื่อเดิม พารามิเตอร์เดิม
- หน้าเว็บ: `cfClient()` ใน index.html ทำตัวเหมือน supabase-js · เปิดใช้ด้วย `?cf=1` (จำในเครื่อง) · `?cf=0` กลับไป Supabase
- ล็อกอินครั้งแรกบนระบบใหม่: ถ้ายังไม่มีรหัสในระบบใหม่ จะตรวจรหัสกับ Supabase เดิมแล้วคัดลอกบัญชีมาให้
- ซิงก์ข้ามเครื่อง: หน้าเว็บถาม `/api/changes` ทุก 15 วินาที

ทดสอบในเครื่อง: `npx wrangler pages dev --d1 DB --r2 FILES` (ใช้ฐานข้อมูลจำลองในเครื่อง)
