// ฟังก์ชันฝั่งเซิร์ฟเวอร์ (แทน Supabase RPC) — ชื่อและพารามิเตอร์เหมือนเดิม หน้าเว็บจึงเรียกได้โดยไม่ต้องแก้
import {fail,hashPw,canSee,isMgr} from './auth.js';
import {decode,now} from './meta.js';
import {log} from './hooks.js';
import {BILL} from './rpc_bills.js';
import {MONEY} from './rpc_money.js';
import {MISC} from './rpc_misc.js';

const owner=u=>{if(u.role!=='owner')fail('เฉพาะเจ้าของร้าน',403)};
export const RPC={
  async create_staff(env,u,a){if(u.role!=='owner')fail('เฉพาะเจ้าของร้านเท่านั้นที่สร้างบัญชีได้',403);
    const un=String(a.p_username||'').trim().toLowerCase(),pw=String(a.p_password||''),role=a.p_role;
    if(!/^[a-z0-9._-]{3,30}$/.test(un))fail('ชื่อผู้ใช้ต้องเป็นภาษาอังกฤษหรือตัวเลข 3-30 ตัว');if(pw.length<6)fail('รหัสผ่านต้องมีอย่างน้อย 6 ตัว');
    if(!['owner','head','staff'].includes(role))fail('ตำแหน่งไม่ถูกต้อง');if(role!=='owner'&&a.p_branch==null)fail('กรุณาเลือกสาขา');
    if(await env.DB.prepare('select 1 from staff where lower(username)=?').bind(un).first())fail('ชื่อผู้ใช้นี้มีอยู่แล้ว');
    const uid=crypto.randomUUID(),row={user_id:uid,username:un,full_name:String(a.p_full_name||'').trim()||un,role,branch_id:role==='owner'?null:+a.p_branch,active:1};
    await env.DB.prepare('insert into staff (user_id,username,full_name,role,branch_id,active,pw_hash) values (?,?,?,?,?,1,?)').bind(uid,un,row.full_name,role,row.branch_id,await hashPw(pw)).run();
    await log(env,u,'staff','insert',null,row);return uid},
  async reset_staff_password(env,u,a){if(u.role!=='owner')fail('เฉพาะเจ้าของร้านเท่านั้นที่ตั้งรหัสให้คนอื่นได้',403);if(String(a.p_password||'').length<6)fail('รหัสผ่านต้องมีอย่างน้อย 6 ตัว');
    const r=await env.DB.prepare('update staff set pw_hash=? where user_id=?').bind(await hashPw(a.p_password),a.p_user).run();if(!r.meta.changes)fail('ไม่พบบัญชีนี้');
    await env.DB.prepare('delete from sessions where user_id=?').bind(a.p_user).run();return null},
  async set_staff_avatar_v1(env,u,a){const t=a.p_target_user,p=a.p_avatar_path;
    const tg=await env.DB.prepare('select avatar_path from staff where user_id=? and active=1').bind(t).first();
    if(!tg||!(t===u.uid||u.role==='owner'))fail('ไม่มีสิทธิ์แก้รูปพนักงานบัญชีนี้',403);
    if(p!=null){if(!/^[0-9a-f-]{36}\/[0-9a-f-]{36}\.(webp|png)$/.test(p)||p.split('/')[0]!==t)fail('รูปแบบ path รูปพนักงานไม่ถูกต้อง');
      if(!(await env.FILES.head('staff-avatars/'+p)))fail('ไม่พบไฟล์รูป กรุณาอัปโหลดรูปก่อน')}
    await env.DB.prepare('update staff set avatar_path=? where user_id=?').bind(p,t).run();return tg.avatar_path||null},
  // หน้าตรวจระบบ: บน Cloudflare ทุกส่วนติดตั้งพร้อมกัน
  async schema_status(){return{s19:true,s20:true,s20cron:true,s21:true,s22:true}},
  ...BILL,...MONEY,...MISC};
