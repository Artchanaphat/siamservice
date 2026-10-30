// API หลังบ้านบน Cloudflare Pages Functions (ใช้กับ functions/api/[[path]].js)
// ตัวแปร: env.DB = D1 (siam-db), env.FILES = R2 (siam-files)
import {who,forget,newSession,checkPw,hashPw,sha256,fail,HttpError} from './lib/auth.js';
import {runSelect,runWrite} from './lib/query.js';
import {RPC} from './lib/rpc.js';
import {files} from './lib/files.js';
import {decode,now} from './lib/meta.js';
import {migrate} from './lib/schema.js';
import {lineWebhook,cron} from './lib/notify.js';

const SB_URL='https://plilxmgripxmebvjafmj.supabase.co',SB_KEY='sb_publishable_38gR_gKTmCYqC3RYMcFpmQ_arM3dFxw';
async function fromSupabase(env,un,pw){try{
  const r=await fetch(SB_URL+'/auth/v1/token?grant_type=password',{method:'POST',headers:{apikey:SB_KEY,'content-type':'application/json'},body:JSON.stringify({email:un+'@siam.app',password:pw})});
  if(!r.ok)return null;const t=await r.json(),h={apikey:SB_KEY,authorization:'Bearer '+t.access_token};
  const st=(await (await fetch(SB_URL+'/rest/v1/staff?select=user_id,username,full_name,role,branch_id,active&user_id=eq.'+t.user.id,{headers:h})).json())[0];if(!st)return null;
  if(!(await env.DB.prepare('select 1 from branches limit 1').first())||st.branch_id!=null&&!(await env.DB.prepare('select 1 from branches where id=?').bind(st.branch_id).first())){
    const bs=await (await fetch(SB_URL+'/rest/v1/branches?select=*',{headers:h})).json();
    for(const b of bs)await env.DB.prepare('insert or ignore into branches (id,code,name,address,phone,line_id,sms_credit,active,promptpay,created_at) values (?,?,?,?,?,?,?,?,?,?)')
      .bind(b.id,b.code,b.name,b.address||'',b.phone||'',b.line_id||'',b.sms_credit||0,b.active?1:0,b.promptpay||'',new Date(b.created_at).toISOString()).run()}
  const hp=await hashPw(pw);
  await env.DB.prepare(`insert into staff (user_id,username,full_name,role,branch_id,active,pw_hash) values (?,?,?,?,?,?,?) on conflict(user_id) do update set pw_hash=excluded.pw_hash`)
    .bind(st.user_id,st.username,st.full_name||'',st.role,st.branch_id,st.active?1:0,hp).run();
  return env.DB.prepare('select * from staff where user_id=?').bind(st.user_id).first()}catch(e){console.warn('supabase login',e);return null}}
const J=(d,s=200)=>new Response(JSON.stringify(d),{status:s,headers:{'content-type':'application/json; charset=utf-8','cache-control':'no-store'}});
const need=u=>{if(!u)fail('กรุณาเข้าสู่ระบบใหม่',401);return u};

async function route(req,env,path){const m=req.method;
  // วัดความเร็วฐานข้อมูล: เปิด /api/ping ในเบราว์เซอร์ได้เลย (ไม่มีข้อมูลร้าน)
  if(path==='ping'){const ms=[];let meta={};for(let i=0;i<5;i++){const t=Date.now();const r=await env.DB.prepare('select 1').all();ms.push(Date.now()-t);meta=r.meta||{}}
    return{edge:req.cf&&req.cf.colo,db_region:meta.served_by_region||null,db_ms:ms,avg:Math.round(ms.reduce((a,b)=>a+b,0)/ms.length)}}
  if(path==='line-webhook'&&m==='POST')return lineWebhook(env,req);
  if(path==='cron')return cron(env,req);
  if(path==='auth/login'&&m==='POST'){const {username,password,remember}=await req.json();
    const un=String(username||'').trim().toLowerCase().replace(/@siam\.app$/,'');if(!un||!password)fail('กรุณากรอกชื่อผู้ใช้และรหัสผ่าน');
    let st=await env.DB.prepare('select * from staff where lower(username)=?').bind(un).first();
    // ย้ายจาก Supabase: บัญชีที่ยังไม่มีรหัสในระบบใหม่ ตรวจรหัสกับ Supabase เดิม ถ้าถูกจะคัดลอกบัญชีมาและใช้รหัสเดิมต่อได้เลย
    // ยังไม่มีสาขา (เจ้าของร้านไม่มีสาขาประจำ) ก็ดึงสาขาจาก Supabase ด้วย
    const noBr=!(await env.DB.prepare('select 1 from branches limit 1').first());
    if((!st||!st.pw_hash||noBr)&&env.SB_URL!=='off'){const sb=await fromSupabase(env,un,String(password));if(sb)st=sb}
    if(!st||!(await checkPw(String(password),st.pw_hash)))fail('ชื่อผู้ใช้หรือรหัสผ่านไม่ถูกต้อง',401);
    if(!st.active)fail('บัญชีนี้ถูกระงับการใช้งาน กรุณาติดต่อเจ้าของร้าน',403);
    const token=await newSession(env,st.user_id,!!remember);return{token,user:{id:st.user_id}}}
  const u=await who(env,req);
  if(path==='auth/me')return{user:u?{id:u.uid}:null};
  if(path==='auth/logout'){if(u){forget(u.token_hash);await env.DB.prepare('delete from sessions where token_hash=?').bind(u.token_hash).run()}return{ok:true}}
  if(path==='auth/password'&&m==='POST'){need(u);const {password}=await req.json();if(String(password||'').length<6)fail('รหัสผ่านสั้นหรือง่ายเกินไป ต้องมีอย่างน้อย 6 ตัว');
    const st=await env.DB.prepare('select pw_hash from staff where user_id=?').bind(u.uid).first();if(await checkPw(password,st.pw_hash))fail('รหัสใหม่ต้องไม่ซ้ำกับรหัสเดิม');
    await env.DB.prepare('update staff set pw_hash=? where user_id=?').bind(await hashPw(password),u.uid).run();
    await env.DB.prepare('delete from sessions where user_id=? and token_hash<>?').bind(u.uid,u.token_hash).run();forget();return{ok:true}}
  if(path==='q'&&m==='POST'){need(u);const q=await req.json();if(q.op==='select')return{data:await runSelect(env,u,q)};const d=await runWrite(env,u,q);if(q.t==='staff')forget();return{data:d}}
  if(path.startsWith('rpc/')&&m==='POST'){need(u);const fn=RPC[path.slice(4)];if(!fn)fail('could not find the function '+path.slice(4),404);
    const args=await req.json().catch(()=>({}));const d=await fn(env,u,args||{},req);if(/staff/.test(path))forget();return{data:d}}
  // ซิงก์ข้ามเครื่อง: รายการที่เปลี่ยนหลังลำดับ since
  if(path==='changes'){need(u);const url=new URL(req.url),since=+url.searchParams.get('since')||0;
    if(!since)return{seq:await env.DB.prepare('select coalesce(max(seq),0) s from changes').first('s'),rows:[]};
    const r=await env.DB.prepare('select seq,tbl,row_id,branch_id,bill_id from changes where seq>? order by seq limit 500').bind(since).all();
    const rows=r.results.filter(x=>u.role==='owner'||x.branch_id==null||+x.branch_id===+u.branch);
    return{seq:r.results.length?r.results[r.results.length-1].seq:since,rows}}
  if(path.startsWith('files/'))return files(env,u,req,path.slice(6));
  fail('ไม่พบเส้นทาง '+path,404)}

export async function onRequest({request,env,params}){
  const path=[].concat(params.path||[]).join('/');
  try{await migrate(env);const out=await route(request,env,path);return out instanceof Response?out:J(out)}
  catch(e){const s=e instanceof HttpError?e.status:/constraint|UNIQUE|CHECK/i.test(e.message)?409:500;
    let msg=e.message||String(e);if(/UNIQUE constraint failed: vehicles\.plate/.test(msg))msg='ทะเบียนรถนี้มีในระบบแล้ว';
    if(s===500)console.error(path,e);return J({error:{message:msg}},s)}}
