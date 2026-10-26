-- 12-car-type-check.sql : ตรวจบิลที่บันทึก "ประเภทรถ" ในบิลไม่ตรงกับที่เลือกไว้ (อ่านอย่างเดียว ไม่แก้ข้อมูล)
-- สาเหตุ: โปรแกรมรุ่นก่อน v47 เก็บประเภทรถในบิลจากชื่อย่อ 3 แบบ (รถเก๋ง/กระบะ/มอเตอร์ไซค์)
-- ทำให้ รย.2 กลายเป็น รย.3 และประเภทอื่น ๆ (ขบ., รย.13, EV …) กลายเป็น รย.1
-- ข้อมูลรถ (ตาราง vehicles.car_type) เก็บรหัสถูกต้อง ผิดเฉพาะชื่อที่จดไว้ในบิล (bills.snapshot.type)
with ct(code, label) as (values
  ('sedan','รถยนต์นั่งส่วนบุคคลไม่เกิน 7 คน (รย.1)'),('van','รถยนต์นั่งส่วนบุคคลเกิน 7 คน (รย.2)'),
  ('pickup','รถยนต์บรรทุกส่วนบุคคล (รย.3)'),('moto','รถจักรยานยนต์ (รย.12)'),('moto_pub','รถจักรยานยนต์สาธารณะ (รย.17)'),
  ('tractor','รถแทรกเตอร์ลากจูง (รย.13)'),('trailer','รถพ่วง / รถกึ่งพ่วง (รย.16)'),('truck6','รถบรรทุก 6 ล้อ (ขบ.)'),
  ('truck10','รถบรรทุก 10 ล้อ (ขบ.)'),('taxi','รถยนต์รับจ้าง (TAXI)'),('ev','EV นั่งส่วนบุคคลไม่เกิน 7 ที่นั่ง'),
  ('ev_van','EV นั่งส่วนบุคคลเกิน 7 ที่นั่ง'),('ev_moto','EV จักรยานยนต์ไฟฟ้า'),('other','อื่นๆ')),
b as (
  select bi.id, bi.bill_no, bi.bill_at, bi.vehicle_id, v.plate || ' ' || v.province as plate, v.car_type,
         bi.snapshot ->> 'type' as bill_type, bi.snapshot ->> 'ctype' as bill_ctype, ct.label as vehicle_label,
         row_number() over (partition by bi.vehicle_id order by bi.bill_at desc, bi.id desc) = 1 as is_latest
    from bills bi join vehicles v on v.id = bi.vehicle_id left join ct on ct.code = v.car_type)
select bill_no, to_char(bill_at at time zone 'Asia/Bangkok', 'YYYY-MM-DD HH24:MI') as วันที่, plate as ทะเบียน,
       bill_type as ประเภทในบิล, coalesce(vehicle_label, 'ไม่ทราบรหัส ' || car_type) as ประเภทที่เลือกไว้,
       case when vehicle_label is null then 'ต้องตรวจเอง (รหัสประเภทรถในข้อมูลรถไม่รู้จัก)'
            when is_latest then 'แก้อัตโนมัติได้ (บิลล่าสุดของรถคันนี้)' else 'ต้องตรวจเอง (มีบิลใหม่กว่าของรถคันนี้)' end as วิธีแก้
  from b
 where coalesce(bill_ctype, '') = '' and vehicle_label is distinct from bill_type
 order by bill_at;
