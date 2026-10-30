// งานที่เคยเป็น trigger ใน Supabase: อัปเดตเวลาแก้ไข, ประวัติการใช้งาน (audit_log), ปิดยอด, ไฟล์แนบ, ซิงก์ข้ามเครื่อง
import {now,encode} from './meta.js';
import {fail} from './auth.js';

const TOUCH=['customers','vehicles','dlt_jobs','cash_closes','insp_queue','app_settings'];
const AUDIT=['bills','payments','customers','vehicles','expenses','cash_closes','dlt_jobs','insp_queue','staff','branches','app_settings','remits','cash_outs','exp_requests','close_acks'];
const SYNC=['bills','payments','bill_edits','dlt_jobs','bill_files','bill_requests','vehicles','customers','insp_queue'];

// วันที่ไทย (UTC+7) -> ช่วงเวลา UTC
export const dayRange=d=>[new Date(d+'T00:00:00+07:00').toISOString(),new Date(new Date(d+'T00:00:00+07:00').getTime()+864e5).toISOString()];
export const bkkDate=(t=new Date())=>new Date(new Date(t).getTime()+7*36e5).toISOString().slice(0,10);

export async function drawerOut(env,b,d,staff){const q=(t,dc,m,mv)=>env.DB.prepare(`select coalesce(sum(amount),0) s from ${t} where branch_id=? and ${dc}=? and ${m}=?`+(staff!=null?' and drawer_staff=?':'')).bind(...[b,d,mv].concat(staff!=null?[staff]:[])).first('s');
  return(await q('expenses','exp_date','paid_from','drawer'))+(await q('remits','remit_date','method','drawer'))+(await q('cash_outs','out_date','paid_from','drawer'))}

export async function beforeWrite(env,u,t,op,old,o){
  if(op!=='delete'&&TOUCH.includes(t)&&op==='update')o.updated_at=now();
  if(t==='staff'&&op==='update'&&old.user_id===u.uid&&(('active' in o&&!!o.active!==!!old.active)||('role' in o&&o.role!==old.role)))fail('แก้ตำแหน่งหรือปิดบัญชีของตัวเองไม่ได้');
  if(t==='cash_closes'&&op!=='delete'){const r={...(old||{}),...o},[t0,t1]=dayRange(r.close_date);
    if(u.role!=='owner'&&u.role!=='head'){
      if(op==='update'||await env.DB.prepare('select 1 from cash_closes where branch_id=? and close_date=? limit 1').bind(r.branch_id,r.close_date).first())fail('วันนี้ปิดยอดไปแล้ว การแก้ไขยอดปิดทำได้เฉพาะเจ้าของร้าน/หัวหน้าสาขา');
      const p=await env.DB.prepare(`select count(*) n,coalesce(sum(amount),0) s from payments where branch_id=? and paid_at>=? and paid_at<? and kind='pay' and verified=0 and rejected=0`).bind(r.branch_id,t0,t1).first();
      if(p.n>0)fail(`ยังมีเงินโอนรอตรวจสอบ ${p.n} รายการ (${(+p.s).toLocaleString('en-US',{minimumFractionDigits:2,maximumFractionDigits:2})} บาท) กรุณาตรวจสอบเงินโอนก่อน หรือให้หัวหน้า/เจ้าของร้านเป็นผู้ปิดยอด`)}
    const ps=(await env.DB.prepare(`select method,case when kind='refund' then -amount else amount end a from payments where branch_id=? and paid_at>=? and paid_at<? and rejected=0 and (kind='refund' or verified=1) and coalesce(nullif(by_name,''),'ไม่ระบุ')=?`).bind(r.branch_id,t0,t1,r.staff_name).all()).results;
    let cash=0,tr=0,card=0,oth=0;for(const x of ps){const m=x.method||'';if(/สด/.test(m))cash+=x.a;else if(/โอน/.test(m))tr+=x.a;else if(/บัตร/.test(m))card+=x.a;else oth+=x.a}
    Object.assign(o,{cash,transfer:tr,card,other:oth,cash_out:await drawerOut(env,r.branch_id,r.close_date,r.staff_name),closed_by_name:u.name||o.closed_by_name||''})}
  return o}

export async function log(env,u,t,op,old,nw){
  if(AUDIT.includes(t)){let o=old,n=nw;
    if(op==='update'){o={};n={};for(const k of Object.keys(nw))if(k!=='updated_at'&&JSON.stringify(old[k])!==JSON.stringify(nw[k])){o[k]=old[k];n[k]=nw[k]}if(!Object.keys(n).length)o=n=null}
    if(op!=='update'||n){const r=nw||old;
      await env.DB.prepare('insert into audit_log (user_id,user_name,branch_id,tbl,action,row_id,old_data,new_data) values (?,?,?,?,?,?,?,?)')
        .bind(u?u.uid:null,u?u.name:'ระบบอัตโนมัติ',r.branch_id??null,t,op,String(r.id??r.bill_id??r.key??r.user_id??''),o?JSON.stringify(o):null,n?JSON.stringify(n):null).run()}}
  if(SYNC.includes(t)){const r=nw||old;await env.DB.prepare('insert into changes (tbl,row_id,branch_id,bill_id) values (?,?,?,?)').bind(t,String(r.id??r.bill_id??''),r.branch_id??null,r.bill_id??(t==='bills'?r.id:null)).run()}}

export async function afterWrite(env,u,t,op,old,nw){
  if(t==='bill_files'&&op==='insert'){const b=await env.DB.prepare('select files_pending from bills where id=?').bind(nw.bill_id).first();
    if(b){const L=JSON.parse(b.files_pending||'[]'),i=L.indexOf(nw.file_name);L.splice(i<0?0:i,1);await env.DB.prepare('update bills set files_pending=? where id=?').bind(JSON.stringify(L),nw.bill_id).run()}}
  await log(env,u,t,op,old,nw)}
