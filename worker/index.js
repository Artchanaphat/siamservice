// siam-api: หลังบ้านตัวเดียวกับ Pages Functions แต่รันเป็น Worker ที่ตั้งตำแหน่งไว้ข้างฐานข้อมูล D1
// เว็บ (Pages) ส่งต่อ /api/* มาที่นี่ผ่าน Service binding ชื่อ API ถ้าไม่ได้ผูกไว้ Pages จะทำงานเองเหมือนเดิม
import {onRequest} from '../cf/api.js';
export default{fetch(request,env){const path=new URL(request.url).pathname.replace(/^\/api\/?/,'');
  return onRequest({request,env,params:{path:path?path.split('/'):[]}})}};
