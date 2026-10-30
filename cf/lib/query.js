// ตัวแปลงคำสั่งแบบ Supabase (from().select().eq()...) เป็น SQL ของ D1 พร้อมสิทธิ์ตามตำแหน่ง/สาขา (แทน RLS ของ Supabase)
import {JSONC,BOOLC,PK,REL,HIDE,TABLES,decode,encode,now} from './meta.js';
import {fail,canSee,isMgr} from './auth.js';
import {afterWrite,beforeWrite} from './hooks.js';

const colCache={};
export async function cols(env,t){if(!TABLES.includes(t))fail('ไม่พบตาราง '+t,404);
  if(!colCache[t]){const r=await env.DB.prepare(`pragma table_info(${t})`).all();colCache[t]=new Set(r.results.map(x=>x.name))}return colCache[t]}
const col=async(env,t,c)=>{if(!(await cols(env,t)).has(c))fail(`ไม่พบช่อง ${t}.${c}`);return c};

// ---------- สิทธิ์อ่าน: คืนเงื่อนไข SQL ----------
const BR=['bills','payments','dlt_jobs','bill_files','bill_requests','insp_queue','cash_closes','close_acks','expenses','remits','cash_outs','exp_requests','sms_sent'];
function readScope(u,t){
  if(['app_settings','branches','customers','vehicles','news','line_reminders'].includes(t))return['1=1',[]];
  if(t==='audit_log'||t==='backup_snapshots')return u.role==='owner'?['1=1',[]]:['0=1',[]];
  if(t==='staff'){if(u.role==='owner')return['1=1',[]];if(u.role==='head')return['(user_id=? or branch_id=?)',[u.uid,u.branch]];return['user_id=?',[u.uid]]}
  if(u.role==='owner')return['1=1',[]];
  if(t==='bill_edits')return['bill_id in (select id from bills where branch_id=?)',[u.branch]];
  if(BR.includes(t))return['branch_id=?',[u.branch]];
  return['0=1',[]]}

// ---------- สิทธิ์เขียน ----------
const any=u=>!!u.role;
function canWrite(u,t,op,row){const b=row&&row.branch_id,own=u.role==='owner',br=canSee(u,b);
  switch(t){
    case 'customers':case 'vehicles':return op==='delete'?own:any(u);
    case 'branches':case 'staff':case 'news':return own;
    case 'app_settings':if(own)return true;if(op==='delete')return false;return row.key==='lists'||(row.key==='rates'&&u.role==='head');
    case 'bills':return op==='update'?br&&isMgr(u):op==='delete'&&own;
    case 'payments':return(op==='update'||op==='delete')&&own;
    case 'bill_edits':return op==='insert'&&isMgr(u);
    case 'bill_files':return op==='delete'?own:op==='insert'&&br;
    case 'cash_closes':return op==='delete'?own:br;
    case 'dlt_jobs':return op==='delete'?own:br;
    case 'insp_queue':return br;
    case 'expenses':case 'remits':case 'cash_outs':return op==='insert'?br:br&&isMgr(u);
    case 'exp_requests':if(op==='insert')return br&&row.status==='pending'&&row.req_uid===u.uid&&row.expense_id==null;
      if(op==='delete')return br&&((row.status==='pending'&&row.req_uid===u.uid)||isMgr(u));return false;
  }return false}

// ---------- ตัวกรอง ----------
const OPS={eq:'=',neq:'<>',gt:'>',gte:'>=',lt:'<',lte:'<='};
const val=(t,c,v)=>(BOOLC[t]||[]).includes(c)?(v===true||v==='true'?1:v===false||v==='false'?0:v):v;
async function cond(env,t,[c,op,v]){await col(env,t,c);
  if(op in OPS){if(v===null||v==='null')return[op==='neq'?`${c} is not null`:`${c} is null`,[]];return[`${c} ${OPS[op]} ?`,[val(t,c,v)]]}
  if(op==='inj')return[`${c} in (select value from json_each(?))`,[JSON.stringify(v)]];
  if(op==='in'){const a=Array.isArray(v)?v:String(v).replace(/^\(|\)$/g,'').split(',');if(!a.length)return['0=1',[]];return[`${c} in (${a.map(()=>'?').join(',')})`,a.map(x=>val(t,c,x))]}
  if(op==='is')return[v===null||v==='null'?`${c} is null`:`${c} is ${v?'not null':'null'}`,[]];
  if(op==='like'||op==='ilike')return[`${c} like ?`,[String(v).replace(/\*/g,'%')]];
  if(op==='cs'){const a=Array.isArray(v)?v:JSON.parse(v);return[a.map(()=>`exists (select 1 from json_each(${c}) where value=?)`).join(' and ')||'1=1',a]}
  fail('ไม่รองรับตัวกรอง '+op)}
// or('bill_at.gte.2026-01-01T..,status.eq.open')
async function orCond(env,t,s){const parts=String(s).split(/,(?![^(]*\))/),w=[],p=[];
  for(const x of parts){const m=x.match(/^([a-z_]+)\.([a-z]+)\.(.*)$/);if(!m)fail('ตัวกรอง or ไม่ถูกต้อง');const [q,a]=await cond(env,t,[m[1],m[2],m[3]]);w.push(q);p.push(...a)}
  return['('+w.join(' or ')+')',p]}
async function where(env,u,t,f,or){const [s0,p0]=readScope(u,t),w=[s0],p=[...p0];
  for(const x of f||[]){const [q,a]=await cond(env,t,x);w.push(q);p.push(...a)}
  if(or){const [q,a]=await orCond(env,t,or);w.push(q);p.push(...a)}
  return[w.join(' and '),p]}

// select('*,payments(*),insp_queue(id,status)') -> {cols:['*'], embeds:[{t,cols}]}
function parseSel(s){s=String(s||'*').replace(/\s+/g,'');const out={cols:[],embeds:[]};let d=0,cur='';
  for(const ch of s+','){if(ch==='(')d++;if(ch===')')d--;if(ch===','&&d===0){if(cur){const m=cur.match(/^([a-z_]+)\((.*)\)$/);if(m)out.embeds.push({t:m[1],sel:m[2]});else out.cols.push(cur)}cur=''}else cur+=ch}
  if(!out.cols.length)out.cols=['*'];return out}
async function colList(env,t,cs){if(cs.includes('*'))return'*';for(const c of cs)await col(env,t,c);return cs.join(',')}
async function embed(env,u,t,rows,embeds){if(!rows.length)return rows;
  // ต่อทุกตารางพร้อมกัน ตารางละ 1 คำสั่ง (ส่งรายการคีย์เป็น JSON ก้อนเดียว ไม่ต้องแบ่งเป็นชุดละ 90)
  await Promise.all(embeds.map(async e=>{const rel=(REL[t]||{})[e.t];if(!rel)fail(`ไม่รองรับการต่อ ${t}.${e.t}`);const [fk,pk,one]=rel;
    const keys=[...new Set(rows.map(r=>r[pk]).filter(x=>x!=null))];const by=new Map();
    if(keys.length){const sub=parseSel(e.sel);let cs=await colList(env,e.t,sub.cols);if(cs!=='*'&&!cs.split(',').includes(fk))cs+=','+fk;
      const [w,p]=await where(env,u,e.t,[[fk,'inj',keys]]);const r=await env.DB.prepare(`select ${cs} from ${e.t} where ${w}`).bind(...p).all();
      for(const x of r.results){decode(e.t,x);const k=x[fk];if(!by.has(k))by.set(k,[]);by.get(k).push(x)}}
    for(const r of rows){const l=by.get(r[pk])||[];r[e.t]=one?(l[0]||null):l}}));
  return rows}

export async function runSelect(env,u,q){const t=q.t;await cols(env,t);const sel=parseSel(q.sel);
  const [w,p]=await where(env,u,t,q.f,q.or);let sql=`select ${await colList(env,t,sel.cols)} from ${t} where ${w}`;
  if(q.ord&&q.ord.length){const o=[];for(const [c,asc] of q.ord)o.push(`${await col(env,t,c)} ${asc===false?'desc':'asc'}`);sql+=' order by '+o.join(',')}
  if(q.rng){sql+=` limit ${Math.max(0,q.rng[1]-q.rng[0]+1)|0} offset ${q.rng[0]|0}`}else if(q.lim)sql+=` limit ${q.lim|0}`;
  const r=await env.DB.prepare(sql).bind(...p).all();const rows=r.results.map(x=>decode(t,x));
  if(sel.cols.includes('*')||sel.embeds.length)await embed(env,u,t,rows,sel.embeds);return rows}

// ---------- เขียน ----------
const strip=(t,o)=>{const x={...o};for(const c of HIDE[t]||[])delete x[c];return x};
async function insertOne(env,u,t,o,conflict){const cs=await cols(env,t);o=strip(t,o);for(const k of Object.keys(o))if(!cs.has(k))fail(`ไม่พบช่อง ${t}.${k}`);
  if(t==='exp_requests'){o.req_uid=u.uid;if(!o.status)o.status='pending'}
  if(conflict){const keys=conflict.split(',');const [w,p]=[keys.map(k=>`${k}=?`).join(' and '),keys.map(k=>val(t,k,o[k]))];
    const old=await env.DB.prepare(`select * from ${t} where ${w}`).bind(...p).first();
    if(old){const patch={...o};for(const k of keys)delete patch[k];return updateRows(env,u,t,[decode(t,old)],patch)}}
  if(!canWrite(u,t,'insert',o))fail('ไม่มีสิทธิ์บันทึกข้อมูลนี้',403);
  o=await beforeWrite(env,u,t,'insert',null,o);const e=encode(t,o),ks=Object.keys(e);
  const row=await env.DB.prepare(`insert into ${t} (${ks.join(',')}) values (${ks.map(()=>'?').join(',')}) returning *`).bind(...ks.map(k=>e[k])).first();
  const d=decode(t,row);await afterWrite(env,u,t,'insert',null,d);return[d]}
export async function updateRows(env,u,t,olds,patch){const cs=await cols(env,t);patch=strip(t,patch);for(const k of Object.keys(patch))if(!cs.has(k))fail(`ไม่พบช่อง ${t}.${k}`);
  const out=[],pk=PK[t]||'id';
  for(const old of olds){const nw={...old,...patch};if(!canWrite(u,t,'update',old)||!canWrite(u,t,'update',nw))fail('ไม่มีสิทธิ์แก้ไขข้อมูลนี้',403);
    const p2=await beforeWrite(env,u,t,'update',old,{...patch});const e=encode(t,p2),ks=Object.keys(e);if(!ks.length){out.push(old);continue}
    const key=t==='close_acks'?'branch_id=? and close_date=?':`${pk}=?`,kv=t==='close_acks'?[old.branch_id,old.close_date]:[old[pk]];
    const row=await env.DB.prepare(`update ${t} set ${ks.map(k=>k+'=?').join(',')} where ${key} returning *`).bind(...ks.map(k=>e[k]),...kv).first();
    const d=decode(t,row);await afterWrite(env,u,t,'update',old,d);out.push(d)}
  return out}
export async function runWrite(env,u,q){const t=q.t;await cols(env,t);let rows=[];
  if(q.op==='insert'||q.op==='upsert'){const list=Array.isArray(q.vals)?q.vals:[q.vals];for(const o of list)rows.push(...await insertOne(env,u,t,o,q.op==='upsert'?(q.conflict||PK[t]||'id'):null))}
  else{if(!(q.f&&q.f.length))fail('ต้องระบุเงื่อนไขก่อนแก้ไข/ลบ');const [w,p]=await where(env,u,t,q.f,q.or);
    const olds=(await env.DB.prepare(`select * from ${t} where ${w}`).bind(...p).all()).results.map(x=>decode(t,x));
    if(q.op==='update')rows=await updateRows(env,u,t,olds,q.vals||{});
    else if(q.op==='delete'){const pk=PK[t]||'id';for(const old of olds){if(!canWrite(u,t,'delete',old))fail('ไม่มีสิทธิ์ลบข้อมูลนี้',403);
        await beforeWrite(env,u,t,'delete',old,null);await env.DB.prepare(`delete from ${t} where ${pk}=?`).bind(old[pk]).run();await afterWrite(env,u,t,'delete',old,null);rows.push(old)}}
    else fail('คำสั่งไม่ถูกต้อง')}
  if(q.ret==null)return null;
  const sel=parseSel(q.ret);if(sel.cols.includes('*'))return rows;return rows.map(r=>Object.fromEntries(sel.cols.map(c=>[c,r[c]])))}
