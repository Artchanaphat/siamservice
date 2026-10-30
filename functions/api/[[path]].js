// API ระบบหลังบ้านบน Cloudflare (โค้ดอยู่ใน cf/)
// ถ้าผูก Service binding ชื่อ API (Worker siam-api ที่อยู่ข้างฐานข้อมูล) ไว้ ส่งต่อไปให้ตัวนั้นทำ จะถามฐานข้อมูลได้เร็วกว่า
import {onRequest as local} from '../../cf/api.js';
export function onRequest(ctx){const {request,env}=ctx;
  if(env.API&&!new URL(request.url).searchParams.has('local'))return env.API.fetch(request);
  return local(ctx)}
