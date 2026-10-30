// LINE / SMS (ระยะ 4 — ยังไม่ได้ย้าย)
import {fail} from './auth.js';
const todo=()=>fail('ส่วนนี้ยังย้ายไป Cloudflare ไม่เสร็จ (ระยะ 4)');
export const NOTIFY={line_preview:todo,line_test:todo,sms_send:todo,sms_credit:todo};
