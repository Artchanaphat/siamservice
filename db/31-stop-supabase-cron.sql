-- 31: หยุดงานตั้งเวลาใน Supabase (ใช้ตอนสลับไป Cloudflare แล้วเท่านั้น)
-- กันสรุป LINE / แจ้งเตือนลูกค้า ส่งซ้ำจากสองระบบ ระบบใหม่ทำงานเองทุก 10 นาทีผ่าน siam-cron
select cron.unschedule(jobname) from cron.job where jobname in ('siam-backup-nightly','siam-line-daily','siam-line-remind');
select jobname from cron.job;  -- ควรไม่เหลือ 3 ชื่อข้างบน
