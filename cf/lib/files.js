// ไฟล์แนบบิล / รูปพนักงาน บน R2 (แทน Supabase Storage) — ลิงก์ดูไฟล์มีลายเซ็นและหมดอายุใน 1 ชั่วโมง
import {fail,canSee,sha256} from './auth.js';
const BUCKETS={'bill-files':{max:10485760,types:/^(image\/(jpeg|png|webp|gif|heic|heif)|application\/pdf)$/},'staff-avatars':{max:1048576,types:/^image\/(webp|png)$/}};
async function key(env){let k=await env.DB.prepare(`select value from secrets where name='url_key'`).first('value');
  if(!k){k=[...crypto.getRandomValues(new Uint8Array(32))].map(x=>x.toString(16).padStart(2,'0')).join('');await env.DB.prepare(`insert or ignore into secrets (name,value) values ('url_key',?)`).bind(k).run();
    k=await env.DB.prepare(`select value from secrets where name='url_key'`).first('value')}return k}
const sig=async(env,p,e)=>(await sha256((await key(env))+'|'+p+'|'+e)).slice(0,32);
const okPath=p=>/^[A-Za-z0-9._\/-]{3,200}$/.test(p)&&!p.includes('..');
function mayWrite(u,b,p){if(b==='bill-files')return canSee(u,+p.split('/')[0]);if(b==='staff-avatars')return u.role==='owner'||p.split('/')[0]===u.uid;return false}
function mayRead(u,b,p){if(b==='bill-files')return canSee(u,+p.split('/')[0]);return b==='staff-avatars'}
export async function signUrl(env,b,p,base=''){const e=Math.floor(Date.now()/1000)+3600;return `${base}/api/files/get/${b}/${p}?e=${e}&s=${await sig(env,b+'/'+p,e)}`}

export async function files(env,u,req,rest){const url=new URL(req.url),[act,b,...pp]=rest.split('/'),p=pp.join('/');
  if(act==='get'){const e=+url.searchParams.get('e'),s=url.searchParams.get('s');if(!e||e<Date.now()/1000||s!==await sig(env,b+'/'+p,e))fail('ลิงก์หมดอายุ',403);
    const o=await env.FILES.get(b+'/'+p);if(!o)fail('ไม่พบไฟล์',404);
    return new Response(o.body,{headers:{'content-type':o.httpMetadata&&o.httpMetadata.contentType||'application/octet-stream','cache-control':'private, max-age=3600'}})}
  if(!u)fail('กรุณาเข้าสู่ระบบใหม่',401);if(!BUCKETS[b])fail('ไม่พบที่เก็บไฟล์',404);
  if(act==='upload'&&req.method==='POST'){if(!okPath(p)||!mayWrite(u,b,p))fail('ไม่มีสิทธิ์อัปโหลดไฟล์นี้',403);
    const ct=req.headers.get('content-type')||'',buf=await req.arrayBuffer();if(!BUCKETS[b].types.test(ct))fail('ชนิดไฟล์ไม่รองรับ');if(buf.byteLength>BUCKETS[b].max)fail('ไฟล์ใหญ่เกินกำหนด');
    if(await env.FILES.head(b+'/'+p))fail('มีไฟล์ชื่อนี้แล้ว',409);await env.FILES.put(b+'/'+p,buf,{httpMetadata:{contentType:ct}});return{data:{path:p}}}
  if(act==='sign'&&req.method==='POST'){const {paths}=await req.json(),base=url.origin;
    return{data:await Promise.all((paths||[]).map(async x=>okPath(x)&&mayRead(u,b,x)?{path:x,signedUrl:await signUrl(env,b,x,base),error:null}:{path:x,signedUrl:null,error:'ไม่มีสิทธิ์'}))}}
  if(act==='remove'&&req.method==='POST'){const {paths}=await req.json();
    for(const x of paths||[]){if(!okPath(x)||(b==='bill-files'?u.role!=='owner':!mayWrite(u,b,x)))fail('ไม่มีสิทธิ์ลบไฟล์นี้',403);await env.FILES.delete(b+'/'+x)}return{data:(paths||[]).map(x=>({name:x}))}}
  fail('คำสั่งไฟล์ไม่ถูกต้อง')}
