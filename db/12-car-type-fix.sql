-- 12-car-type-fix.sql : แก้ "ประเภทรถ" ที่จดไว้ในบิลให้ตรงกับที่เลือกตอนเปิดบิล
-- รันหลังจากดูผล 12-car-type-check.sql แล้ว
-- แก้เฉพาะบิลล่าสุดของรถแต่ละคัน เพราะค่า vehicles.car_type ถูกบันทึกจากบิลนั้นพอดี (ไม่ใช่การเดา)
-- บิลเก่ากว่าของรถคันเดียวกันจะไม่ถูกแตะ ให้ตรวจเองตามรายการที่ check แสดง
-- ไม่แก้ข้อมูลลูกค้า ยอดเงิน หรือรายการในบิล แก้เฉพาะ snapshot.type และเพิ่ม snapshot.ctype
with ct(code, label) as (values
  ('sedan','รถยนต์นั่งส่วนบุคคลไม่เกิน 7 คน (รย.1)'),('van','รถยนต์นั่งส่วนบุคคลเกิน 7 คน (รย.2)'),
  ('pickup','รถยนต์บรรทุกส่วนบุคคล (รย.3)'),('moto','รถจักรยานยนต์ (รย.12)'),('moto_pub','รถจักรยานยนต์สาธารณะ (รย.17)'),
  ('tractor','รถแทรกเตอร์ลากจูง (รย.13)'),('trailer','รถพ่วง / รถกึ่งพ่วง (รย.16)'),('truck6','รถบรรทุก 6 ล้อ (ขบ.)'),
  ('truck10','รถบรรทุก 10 ล้อ (ขบ.)'),('taxi','รถยนต์รับจ้าง (TAXI)'),('ev','EV นั่งส่วนบุคคลไม่เกิน 7 ที่นั่ง'),
  ('ev_van','EV นั่งส่วนบุคคลเกิน 7 ที่นั่ง'),('ev_moto','EV จักรยานยนต์ไฟฟ้า'),('other','อื่นๆ')),
latest as (
  select distinct on (bi.vehicle_id) bi.id, v.car_type, ct.label
    from bills bi join vehicles v on v.id = bi.vehicle_id join ct on ct.code = v.car_type
   order by bi.vehicle_id, bi.bill_at desc, bi.id desc)
update bills bi
   set snapshot = bi.snapshot || jsonb_build_object('ctype', l.car_type, 'type', l.label)
  from latest l
 where bi.id = l.id
   and coalesce(bi.snapshot ->> 'ctype', '') = ''
   and bi.snapshot ->> 'type' is distinct from l.label
returning bi.bill_no, bi.snapshot ->> 'plate' as plate, l.label as new_type;
