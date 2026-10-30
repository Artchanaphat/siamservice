// สำรอง/กู้คืน, รหัส LINE/SMS, รหัสผูก LINE ลูกค้า
import {fail} from './auth.js';
import {encode,decode,now,PK,JSONC} from './meta.js';
import {cols} from './query.js';
import {NOTIFY} from './notify.js';

const owner=u=>{if(u.role!=='owner')fail('เฉพาะเจ้าของร้านเท่านั้น',403)};
const mask=v=>v?'••••'+String(v).slice(-4):null;
export const getSecret=async(env,n)=>(await env.DB.prepare('select value from secrets where name=?').bind(n).first('value'))||'';
const putSecret=(env,n,v)=>env.DB.prepare(`insert into secrets (name,value,updated_at) values (?,?,?) on conflict(name) do update set value=excluded.value,updated_at=excluded.updated_at`).bind(n,v,now()).run();

// ตารางในไฟล์สำรอง (staff ไม่มีรหัสผ่าน: หลังกู้คืน เจ้าของร้านต้องตั้งรหัสให้พนักงานใหม่)
export const BK=[['branches','id'],['staff','user_id','user_id,username,full_name,role,branch_id,active,created_at'],['customers','id'],['vehicles','id'],['bills','id'],['payments','id'],['bill_edits','id'],['dlt_jobs','bill_id'],
  ['bill_files','id'],['bill_requests','id'],['insp_queue','id'],['cash_closes','id'],['expenses','id'],['remits','id'],['cash_outs','id'],['exp_requests','id'],['close_acks','branch_id'],['app_settings','key'],['news','id'],['audit_log','id']];
export async function makeBackup(env,kind){const data={},counts={},skipped=[];
  for(const [t,k,c] of BK){const r=await env.DB.prepare(`select ${c||'*'} from ${t} order by ${k}`).all();data[t]=r.results.map(x=>decode(t,x));counts[t]=data[t].length}
  const body=JSON.stringify(data),key=`backups/${new Date().toISOString().replace(/[:.]/g,'-')}-${kind}.json`;
  await env.FILES.put(key,body,{httpMetadata:{contentType:'application/json'}});
  const id=(await env.DB.prepare('insert into backup_snapshots (kind,size_bytes,counts,skipped,r2_key) values (?,?,?,?,?) returning id').bind(kind,body.length,JSON.stringify(counts),JSON.stringify(skipped),key).first()).id;
  // เก็บ 7 ชุดล่าสุด
  const old=(await env.DB.prepare('select id,r2_key from backup_snapshots order by created_at desc limit -1 offset 7').all()).results;
  for(const o of old){if(o.r2_key)await env.FILES.delete(o.r2_key);await env.DB.prepare('delete from backup_snapshots where id=?').bind(o.id).run()}
  return id}
// เวลาจาก Supabase (+00:00 / ไมโครวินาที) -> ISO แบบ Z ให้เทียบกันได้
const TS=/^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(\.\d+)?([+-]\d{2}(:?\d{2})?|Z)$/;
const normTs=v=>typeof v==='string'&&TS.test(v)?new Date(v.replace(' ','T').replace(/([+-]\d{2})$/,'$1:00')).toISOString():v;

export const MISC={
  async backup_list(env,u){owner(u);return(await env.DB.prepare('select id,created_at,kind,size_bytes,counts,skipped from backup_snapshots order by created_at desc').all()).results.map(x=>decode('backup_snapshots',x))},
  async backup_get(env,u,{p_id}){owner(u);const r=await env.DB.prepare('select * from backup_snapshots where id=?').bind(p_id).first();if(!r)fail('ไม่พบชุดสำรองนี้');
    const o=await env.FILES.get(r.r2_key);if(!o)fail('ไม่พบไฟล์ชุดสำรองนี้');return{created_at:r.created_at,kind:r.kind,counts:JSON.parse(r.counts),skipped:JSON.parse(r.skipped),data:await o.json()}},
  async backup_now(env,u){owner(u);return makeBackup(env,'manual')},
  async restore_backup(env,u,{p}){owner(u);if(!p||p.app!=='siam-service-backup')fail('ไฟล์นี้ไม่ใช่ไฟล์สำรองของระบบ');const out={};let total=0;
    for(const [t] of BK){const rows=p.data&&p.data[t];if(!Array.isArray(rows)||!rows.length)continue;const cs=await cols(env,t);let n=0;
      for(let i=0;i<rows.length;i+=50){const st=[];
        for(const r0 of rows.slice(i,i+50)){const r={};for(const [k,v] of Object.entries(r0))if(cs.has(k)&&k!=='pw_hash')r[k]=(JSONC[t]||[]).includes(k)?v:normTs(v);
          const e=encode(t,r),ks=Object.keys(e);st.push(env.DB.prepare(`insert or ignore into ${t} (${ks.join(',')}) values (${ks.map(()=>'?').join(',')})`).bind(...ks.map(k=>e[k])))}
        const res=await env.DB.batch(st);n+=res.reduce((a,x)=>a+(x.meta.changes||0),0)}
      out[t]=n;total+=n}
    // เลขบิลต่อจากเลขเดิม
    const bs=(await env.DB.prepare(`select branch_id,cast(strftime('%Y',bill_at,'+7 hours') as integer)+543 y,max(cast(substr(bill_no,length(bill_no)-3) as integer)) n from bills where bill_no like '%-%' group by 1,2`).all()).results;
    for(const x of bs)await env.DB.prepare('insert into bill_counters (branch_id,be_year,last_no) values (?,?,?) on conflict(branch_id,be_year) do update set last_no=max(last_no,excluded.last_no)').bind(x.branch_id,x.y,x.n||0).run();
    return{inserted:out,total}},

  async line_code_for(env,u,{p_customer}){let c=await env.DB.prepare('select line_code from customers where id=?').bind(p_customer).first();if(!c)fail('ไม่พบลูกค้า');c=c.line_code;
    while(!c){const x=String(crypto.getRandomValues(new Uint32Array(1))[0]%1000000).padStart(6,'0');
      try{const r=await env.DB.prepare('update customers set line_code=? where id=? and line_code is null').bind(x,p_customer).run();c=r.meta.changes?x:await env.DB.prepare('select line_code from customers where id=?').bind(p_customer).first('line_code')}catch(e){if(!/UNIQUE/.test(e.message))throw e}}
    return c},
  async line_secret_status(env,u){owner(u);return{token:mask(await getSecret(env,'line_token')),to:await getSecret(env,'line_to'),secret:mask(await getSecret(env,'line_channel_secret'))}},
  async set_line_secrets(env,u,{p_token,p_to,p_secret}){owner(u);const t=String(p_token||'').trim(),s=String(p_secret||'').trim();
    if(t){if(t.length<100)fail('Channel access token สั้นเกินไป ตรวจว่าคัดลอกมาครบ');await putSecret(env,'line_token',t)}
    if(p_to!=null){const to=String(p_to).trim();if(to&&to.split(/\s*,\s*/).some(x=>!/^U[0-9a-f]{32}$/.test(x)))fail('User ID ต้องขึ้นต้นด้วย U ตามด้วยตัวอักษร 32 ตัว (หลายคนคั่นด้วย ,)');await putSecret(env,'line_to',to)}
    if(s){if(!/^[0-9a-f]{32}$/.test(s))fail('Channel secret ต้องเป็นตัวอักษร 32 ตัว');await putSecret(env,'line_channel_secret',s)}return null},
  async line_schedule(env,u){owner(u);return{daily:(await getSecret(env,'sched_daily'))||'20:00',remind:(await getSecret(env,'sched_remind'))||'09:00'}},
  async set_line_schedule(env,u,{p_daily,p_remind}){owner(u);const ok=x=>/^([01]\d|2[0-3]):[0-5]\d$/.test(x);
    if(p_daily&&String(p_daily).trim()){if(!ok(p_daily.trim()))fail('รูปแบบเวลาไม่ถูกต้อง');await putSecret(env,'sched_daily',p_daily.trim())}
    if(p_remind&&String(p_remind).trim()){if(!ok(p_remind.trim()))fail('รูปแบบเวลาไม่ถูกต้อง');await putSecret(env,'sched_remind',p_remind.trim())}return MISC.line_schedule(env,u)},
  async sms_secret_status(env,u){owner(u);return{key:mask(await getSecret(env,'sms_api_key')),secret:mask(await getSecret(env,'sms_api_secret'))}},
  async set_sms_secrets(env,u,{p_key,p_secret}){owner(u);const k=String(p_key||'').trim(),s=String(p_secret||'').trim();
    if(k){if(k.length<8)fail('API Key สั้นเกินไป ตรวจว่าคัดลอกมาครบ');await putSecret(env,'sms_api_key',k)}
    if(s){if(s.length<8)fail('API Secret สั้นเกินไป ตรวจว่าคัดลอกมาครบ');await putSecret(env,'sms_api_secret',s)}return null},
  async sms_recent(env,u){return(await env.DB.prepare(`select vehicle_id,kind,max(sent_at) sent_at from sms_sent where ok=1 and vehicle_id is not null and sent_at>? ${u.role==='owner'?'':'and branch_id='+(+u.branch)} group by 1,2`).bind(new Date(Date.now()-45*864e5).toISOString()).all()).results},
  ...NOTIFY,
};
