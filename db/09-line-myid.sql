-- ตรอ.สยามเซอร์วิส : ให้คนที่แอดไลน์ร้านพิมพ์ "ไอดี" แล้วระบบตอบ User ID กลับ
-- ใช้หา User ID ของคนที่จะรับสรุปประจำวันเพิ่ม (รันหลัง 07 รันซ้ำได้)

create or replace function public.line_event(p_user text, p_type text, p_text text, p_reply text) returns void
language plpgsql security definer set search_path = public as $$
declare code text := substring(coalesce(p_text, '') from '(?:^|\D)(\d{6})(?:\D|$)'); n int; cars text;
  linked boolean := exists (select 1 from customers where line_user_id = p_user);
begin
  if p_type = 'unfollow' then
    update customers set line_user_id = null, line_linked_at = null where line_user_id = p_user; return;
  end if;
  if p_type = 'follow' then
    perform line_send(p_user, 'ขอบคุณที่เพิ่มเพื่อน ตรอ.สยามเซอร์วิส ครับ' || E'\n' ||
      'ถ้าต้องการให้ร้านแจ้งเตือนก่อนภาษี / พ.ร.บ. หมดอายุ พิมพ์รหัส 6 หลักที่อยู่ใต้ QR บนใบเสร็จ ส่งมาในแชตนี้ได้เลยครับ', p_reply);
    return;
  end if;
  if p_type <> 'message' then return; end if;
  if lower(regexp_replace(coalesce(p_text, ''), '\s', '', 'g')) in ('ไอดี', 'id', 'myid', 'userid') then
    perform line_send(p_user, 'User ID ของคุณคือ' || E'\n' || p_user || E'\n' ||
      'คัดลอกไปใส่ในแอป › ตั้งค่าระบบ › ช่อง User ID (หลายคนคั่นด้วย ,)', p_reply);
    return;
  end if;
  if code is null then
    if linked then return; end if;  -- ลูกค้าที่ผูกแล้วคุยกับแอดมินตามปกติ
    perform line_send(p_user, 'พิมพ์รหัส 6 หลักจากใบเสร็จ เพื่อรับการแจ้งเตือนก่อนภาษี / พ.ร.บ. หมดอายุ ครับ', p_reply);
    return;
  end if;
  update customers set line_user_id = p_user, line_linked_at = now() where line_code = code;
  get diagnostics n = row_count;
  if n = 0 then
    if linked then return; end if;
    perform line_send(p_user, 'ไม่พบรหัส ' || code || ' กรุณาตรวจรหัสบนใบเสร็จอีกครั้ง หรือโทรสอบถามร้านครับ', p_reply);
    return;
  end if;
  select string_agg(v.plate || ' ' || v.province, ', ') into cars
    from vehicles v join customers c on c.id = v.customer_id where c.line_code = code;
  perform line_send(p_user, '✅ ผูกบัญชีเรียบร้อย ร้านจะแจ้งเตือนก่อนภาษี / พ.ร.บ. หมดอายุ' ||
    coalesce(E'\nรถของคุณ: ' || cars, '') || E'\n(อย่าบล็อกหรือลบเพื่อน ไม่อย่างนั้นจะไม่ได้รับข้อความ)', p_reply);
end $$;
revoke all on function public.line_event(text, text, text, text) from public, anon, authenticated;
grant execute on function public.line_event(text, text, text, text) to service_role;
