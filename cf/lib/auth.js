// ล็อกอินด้วยชื่อผู้ใช้/รหัสผ่าน: รหัสผ่านเก็บเป็น PBKDF2-SHA256 (100,000 รอบ), โทเคนเก็บเป็น SHA-256
import {now} from './meta.js';
const enc=new TextEncoder();
const b64=u=>btoa(String.fromCharCode(...new Uint8Array(u)));
const unb64=s=>Uint8Array.from(atob(s),c=>c.charCodeAt(0));
export const sha256=async s=>[...new Uint8Array(await crypto.subtle.digest('SHA-256',enc.encode(s)))].map(x=>x.toString(16).padStart(2,'0')).join('');
async function pbkdf2(pw,salt,iter){const k=await crypto.subtle.importKey('raw',enc.encode(pw),'PBKDF2',false,['deriveBits']);
  return crypto.subtle.deriveBits({name:'PBKDF2',hash:'SHA-256',salt,iterations:iter},k,256)}
export async function hashPw(pw){const salt=crypto.getRandomValues(new Uint8Array(16)),it=100000;return `pbkdf2$${it}$${b64(salt)}$${b64(await pbkdf2(pw,salt,it))}`}
export async function checkPw(pw,h){if(!h)return false;const [k,it,s,d]=h.split('$');if(k!=='pbkdf2')return false;
  const x=b64(await pbkdf2(pw,unb64(s),+it));if(x.length!==d.length)return false;let r=0;for(let i=0;i<x.length;i++)r|=x.charCodeAt(i)^d.charCodeAt(i);return r===0}
export class HttpError extends Error{constructor(status,msg){super(msg);this.status=status}}
export const fail=(msg,status=400)=>{throw new HttpError(status,msg)};
const DAYS=d=>new Date(Date.now()+d*864e5).toISOString();
export async function newSession(env,uid,remember){const tok=b64(crypto.getRandomValues(new Uint8Array(32))).replace(/[+/=]/g,c=>({'+':'-','/':'_','=':''}[c]));
  await env.DB.prepare('insert into sessions (token_hash,user_id,expires_at,last_seen) values (?,?,?,?)').bind(await sha256(tok),uid,DAYS(remember?30:1),now()).run();
  await env.DB.prepare('delete from sessions where expires_at < ?').bind(now()).run();return tok}
// อ่านผู้ใช้จาก Authorization: Bearer <token> (ยืดอายุอัตโนมัติ)
// จำผู้ใช้ที่ตรวจแล้วไว้ 30 วินาที ลดการถามฐานข้อมูลทุกคำขอ
const WHO=new Map();
export const forget=th=>{if(th)WHO.delete(th);else WHO.clear()};
export async function who(env,req){const h=req.headers.get('authorization')||'',tok=h.startsWith('Bearer ')?h.slice(7):'';if(!tok)return null;
  const th=await sha256(tok);const c=WHO.get(th);if(c&&c.until>Date.now())return c.u;const r=await env.DB.prepare(`select s.token_hash,s.expires_at,s.created_at,st.* from sessions s join staff st on st.user_id=s.user_id where s.token_hash=?`).bind(th).first();
  if(!r||r.expires_at<now()||!r.active)return null;
  const life=new Date(r.expires_at)-new Date(r.created_at);if(new Date(r.expires_at)-Date.now()<life/2)await env.DB.prepare('update sessions set expires_at=?,last_seen=? where token_hash=?').bind(new Date(Date.now()+life).toISOString(),now(),th).run();
  const u={uid:r.user_id,username:r.username,name:r.full_name||r.username,role:r.role,branch:r.branch_id,token_hash:th};
  if(WHO.size>500)WHO.clear();WHO.set(th,{u,until:Date.now()+30e3});return u}
export const canSee=(u,b)=>!!u&&(u.role==='owner'||(b!=null&&+b===+u.branch));
export const isMgr=u=>!!u&&(u.role==='owner'||u.role==='head');
