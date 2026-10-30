// บิล / รับเงิน / โอนรอตรวจ / แก้ไขบิล / ยกเลิก-คืนเงิน / ส่งมอบเอกสาร / ผลตรวจสภาพ
// ทุกงานที่ต้อง "สำเร็จทั้งหมดหรือไม่บันทึกเลย" ใช้ env.DB.batch() ซึ่งเป็นธุรกรรมเดียว
import {fail,canSee,isMgr} from './auth.js';
import {decode,now} from './meta.js';
import {log,bkkDate} from './hooks.js';

export const money=n=>(+n||0).toLocaleString('en-US',{minimumFractionDigits:2,maximumFractionDigits:2});
const s=v=>v==null?'':String(v);
const dOrNull=v=>v&&/^\d{4}-\d{2}-\d{2}/.test(v)?String(v).slice(0,10):null;
const intOrNull=v=>v===''||v==null||isNaN(+v)?null:Math.round(+v);
const getBill=async(env,id)=>decode('bills',await env.DB.prepare('select * from bills where id=?').bind(id).first());
const netPaid=async(env,bid)=>env.DB.prepare(`select coalesce(sum(case when kind='refund' then -amount else amount end),0) s from payments where bill_id=? and rejected=0`).bind(bid).first('s');
const edit=(env,bid,what,who)=>env.DB.prepare('insert into bill_edits (bill_id,what,by_name) values (?,?,?)').bind(bid,what,who);
// สถานะบิลหลังรับเงิน/คืนเงิน (แทน trigger payments_refresh)
const statusSql=`update bills set status=case when status='void' then 'void' when (select coalesce(sum(case when kind='refund' then -amount else amount end),0) from payments where bill_id=bills.id and rejected=0)>=total-refund_total-0.000001 then 'paid' else 'open' end where id=?`;
// บันทึก log หลังธุรกรรมสำเร็จ (ประวัติการใช้งาน + ซิงก์ข้ามเครื่อง)
async function logRows(env,u,list){for(const [t,op,old,row] of list)try{await log(env,u,t,op,old,row)}catch(e){console.warn('log',e)}}

// คำสั่งเพิ่มรายการรับเงิน: ถ้ายอดรวมเกินยอดค้าง ระบบใส่จำนวน -1 ให้ชน CHECK(amount>0) แล้วยกเลิกทั้งธุรกรรม
function payStmts(env,billSql,billArgs,branch,pays,key,who){const out=[],total=pays.reduce((t,p)=>t+(+p.amount||0),0);
  pays.forEach((p,i)=>{const m=s(p.method).trim()||'เงินสด',w=/โอน/.test(m);
    const guard=i===0?`case when (select coalesce(sum(case when kind='refund' then -amount else amount end),0) from payments where bill_id=(${billSql}) and rejected=0)+?<=(select total-refund_total from bills where id=(${billSql}))+0.005 and (select status from bills where id=(${billSql}))<>'void' then ? else -1 end`:'?';
    const args=i===0?[...billArgs,total,...billArgs,...billArgs,+p.amount]:[+p.amount];
    out.push(env.DB.prepare(`insert into payments (bill_id,branch_id,amount,method,by_name,verified,client_key) values ((${billSql}),?,${guard},?,?,?,?)`)
      .bind(...billArgs,branch,...args,m,s(p.by_name).trim()||who,w?0:1,key?key+':'+i:null))});
  return out}
const overpay=e=>/CHECK constraint failed/i.test(e.message);

export const BILL={
  async create_bill(env,u,{p}){p=p||{};const k=s(p.client_key),br=+p.branch_id,c=p.cust||{},v=p.veh||{},b=p.bill||{},qid=p.queue_id?+p.queue_id:null;let cid=p.cust_id?+p.cust_id:null;
    if(!k)fail('ไม่มีรหัสอ้างอิงบิล');if(!canSee(u,br))fail('ไม่มีสิทธิ์เปิดบิลของสาขานี้',403);
    const dup=async()=>{const ex=await env.DB.prepare('select id,bill_no,customer_id,vehicle_id from bills where client_key=?').bind(k).first();if(!ex)return null;
      const ids=(await env.DB.prepare('select id from payments where bill_id=? order by id').bind(ex.id).all()).results.map(x=>x.id);
      return{id:ex.id,bill_no:ex.bill_no,customer_id:ex.customer_id,vehicle_id:ex.vehicle_id,dup:true,pay_ids:ids}};
    const d0=await dup();if(d0)return d0;
    if(qid){const q=await env.DB.prepare('select bill_id from insp_queue where id=?').bind(qid).first();if(q&&q.bill_id){const bn=await env.DB.prepare('select bill_no from bills where id=?').bind(q.bill_id).first('bill_no');fail(`คิวนี้เปิดบิลไปแล้ว (เลขที่ ${bn})`)}}
    if(!s(c.first_name).trim())fail('กรุณาระบุชื่อลูกค้า');if(!s(v.plate).trim())fail('กรุณาระบุทะเบียนรถ');
    const total=+b.total||0,disc=+b.discount||0;if(total<0)fail('ยอดรวมบิลติดลบ กรุณาตรวจส่วนลด');if(disc<0)fail('ส่วนลดต้องไม่ติดลบ');
    if(total<=0)fail('ยอดรวมบิลเป็น 0 บาท กรุณาตรวจว่าใส่ราคาของแต่ละรายการครบแล้ว');
    const brow=await env.DB.prepare('select code from branches where id=?').bind(br).first();if(!brow)fail('ไม่พบสาขา');
    if(cid&&!(await env.DB.prepare('select 1 from customers where id=?').bind(cid).first()))cid=null;
    const CF=['prefix','first_name','last_name','tel','id_card','address','tumbol','amphoe','province','zipcode','short_note','note'],cv=CF.map(f=>s(c[f]).trim?s(c[f]):'');
    const at=now(),y=+bkkDate(at).slice(0,4)+543,st=[],cidSql=cid?'?':'(select max(id) from customers)',cidArg=cid?[cid]:[];
    if(cid)st.push(env.DB.prepare(`update customers set ${CF.map(f=>f+'=?').join(',')},updated_at=? where id=?`).bind(...cv,at,cid));
    else st.push(env.DB.prepare(`insert into customers (${CF.join(',')}) values (${CF.map(()=>'?').join(',')})`).bind(...cv));
    const VF=['plate','province','car_type','body','brand','model','color','chassis_no','engine_no','ins_company','prb_company'],
      vv=VF.map(f=>s(v[f])),vd=[intOrNull(v.cc),intOrNull(v.weight_kg),dOrNull(v.reg_date),dOrNull(v.tax_exp),dOrNull(v.prb_exp),dOrNull(v.ins_exp),dOrNull(v.k_exp)],
      VA=[...VF,'cc','weight_kg','reg_date','tax_exp','prb_exp','ins_exp','k_exp'];
    st.push(env.DB.prepare(`insert into vehicles (customer_id,${VA.join(',')}) values (${cidSql},${VA.map(()=>'?').join(',')}) on conflict(plate,province) do update set customer_id=excluded.customer_id,`+
      VA.filter(f=>f!=='plate'&&f!=='province').map(f=>`${f}=excluded.${f}`).join(',')+`,updated_at='${at}'`).bind(...cidArg,...vv,...vd));
    const vidSql='(select id from vehicles where plate=? and province=?)',vidArg=[s(v.plate),s(v.province)];
    st.push(env.DB.prepare('insert into bill_counters (branch_id,be_year,last_no) values (?,?,1) on conflict(branch_id,be_year) do update set last_no=last_no+1').bind(br,y));
    st.push(env.DB.prepare(`insert into bills (branch_id,bill_no,bill_at,customer_id,vehicle_id,snapshot,items,ins_premium,discount,total,pick_date,note,client_key,files_pending,created_by,status)
      values (?,printf('%s-%02d%04d',?,?%100,(select last_no from bill_counters where branch_id=? and be_year=?)),?,${cidSql},${vidSql},?,?,?,?,?,?,?,?,?,?,'open')`)
      .bind(br,brow.code,y,br,y,at,...cidArg,...vidArg,JSON.stringify(b.snapshot||{}),JSON.stringify(b.items||[]),+b.ins_premium||0,disc,total,dOrNull(b.pick_date),s(b.note),k,JSON.stringify(b.files_pending||[]),u.uid));
    const bidSql='select id from bills where client_key=?',pays=Array.isArray(p.pays)?p.pays:[];
    for(const x of pays)if(!(+x.amount>0))fail('จำนวนเงินต้องมากกว่า 0');
    st.push(...payStmts(env,bidSql,[k],br,pays,k,u.name));
    st.push(env.DB.prepare(statusSql.replace('where id=?',`where id=(${bidSql})`)).bind(k));
    if(qid)st.push(env.DB.prepare(`update insp_queue set bill_id=(${bidSql}),billed=1,updated_by_name=?,updated_at=? where id=? and bill_id is null`+(u.role==='owner'?'':' and branch_id=?')).bind(k,u.name,at,qid,...(u.role==='owner'?[]:[u.branch])));
    try{await env.DB.batch(st)}catch(e){if(/UNIQUE constraint failed: bills\.client_key/.test(e.message)){const d=await dup();if(d)return d}
      if(overpay(e))fail(`ยอดรับเงิน ${money(pays.reduce((t,x)=>t+ +x.amount,0))} บาท เกินยอดค้างชำระ ${money(total)} บาท`);throw e}
    const nb=await env.DB.prepare('select * from bills where client_key=?').bind(k).first(),pr=(await env.DB.prepare('select * from payments where bill_id=? order by id').bind(nb.id).all()).results;
    await logRows(env,u,[['customers',cid?'update':'insert',null,{id:nb.customer_id}],['vehicles','upsert',null,{id:nb.vehicle_id}],['bills','insert',null,decode('bills',nb)],...pr.map(x=>['payments','insert',null,decode('payments',x)]),...(qid?[['insp_queue','update',{},{id:qid,branch_id:br,bill_id:nb.id}]]:[])]);
    return{id:nb.id,bill_no:nb.bill_no,customer_id:nb.customer_id,vehicle_id:nb.vehicle_id,dup:false,pay_ids:pr.map(x=>x.id)}},

  async add_payments(env,u,{p_bill,p_pays,p_key}){if(!p_key)fail('ไม่มีรหัสอ้างอิงการรับเงิน');const b=await getBill(env,p_bill);
    if(!b||!canSee(u,b.branch_id))fail('ไม่พบบิล หรือไม่มีสิทธิ์รับเงินบิลนี้');
    const ex=async()=>(await env.DB.prepare('select id from payments where client_key like ? order by id').bind(p_key+':%').all()).results.map(x=>x.id);
    let ids=await ex();if(ids.length)return{dup:true,pay_ids:ids};if(b.status==='void')fail('บิลนี้ถูกยกเลิกแล้ว รับเงินไม่ได้');
    const pays=Array.isArray(p_pays)?p_pays:[];for(const x of pays)if(!(+x.amount>0))fail('จำนวนเงินต้องมากกว่า 0');
    const add=pays.reduce((t,x)=>t+ +x.amount,0),paid=await netPaid(env,b.id),tot=b.total-b.refund_total;
    if(paid+add>tot+0.005)fail(`ยอดรับเงิน ${money(add)} บาท เกินยอดค้างชำระ ${money(Math.max(tot-paid,0))} บาท`);
    try{await env.DB.batch([...payStmts(env,'?',[b.id],b.branch_id,pays,p_key,u.name),env.DB.prepare(statusSql).bind(b.id)])}
    catch(e){if(/UNIQUE constraint failed: payments\.client_key/.test(e.message))return{dup:true,pay_ids:await ex()};if(overpay(e))fail('ยอดรับเงินเกินยอดค้างชำระ (มีการรับเงินบิลนี้จากเครื่องอื่นพร้อมกัน) กรุณาโหลดบิลใหม่');throw e}
    ids=await ex();const rows=(await env.DB.prepare(`select * from payments where id in (${ids.map(()=>'?').join(',')})`).bind(...ids).all()).results;
    await logRows(env,u,rows.map(x=>['payments','insert',null,decode('payments',x)]).concat([['bills','update',{},{id:b.id,branch_id:b.branch_id}]]));return{dup:false,pay_ids:ids}},

  async verify_payment(env,u,{p_id}){const r=decode('payments',await env.DB.prepare('select * from payments where id=?').bind(p_id).first());
    if(!r)fail('ไม่พบรายการรับเงิน');if(!canSee(u,r.branch_id))fail('ไม่มีสิทธิ์ยืนยันรายการของสาขาอื่น',403);
    if(r.rejected)fail(`รายการนี้ถูกปฏิเสธไปแล้ว โดย ${r.rejected_by||'-'} ยืนยันซ้ำไม่ได้`);
    if(r.verified)return{id:r.id,verified:true,verified_by:r.verified_by,verified_at:r.verified_at};
    const at=now(),n=await env.DB.prepare('update payments set verified=1,verified_by=?,verified_at=? where id=? and verified=0 and rejected=0 returning *').bind(u.name,at,p_id).first();
    if(!n)return BILL.verify_payment(env,u,{p_id});await env.DB.prepare(statusSql).bind(r.bill_id).run();
    await logRows(env,u,[['payments','update',r,decode('payments',n)]]);return{id:r.id,verified:true,verified_by:u.name,verified_at:at}},

  async reject_payment(env,u,{p_id,p_reason}){if(!s(p_reason).trim())fail('กรุณาระบุเหตุผลที่ปฏิเสธ');
    const r=decode('payments',await env.DB.prepare('select * from payments where id=?').bind(p_id).first());if(!r)fail('ไม่พบรายการรับเงิน');
    if(!canSee(u,r.branch_id))fail('ไม่มีสิทธิ์ตรวจรายการของสาขาอื่น',403);if(r.verified)fail('รายการนี้ยืนยันแล้ว ปฏิเสธไม่ได้ (ถ้าผิดให้ทำรายการคืนเงิน)');
    if(r.rejected)return{id:r.id,rejected:true,rejected_by:r.rejected_by,rejected_at:r.rejected_at};
    const at=now(),n=await env.DB.prepare('update payments set rejected=1,reject_reason=?,rejected_by=?,rejected_at=? where id=? and verified=0 and rejected=0 returning *').bind(s(p_reason).trim(),u.name,at,p_id).first();
    if(!n)return BILL.reject_payment(env,u,{p_id,p_reason});await env.DB.prepare(statusSql).bind(r.bill_id).run();
    await logRows(env,u,[['payments','update',r,decode('payments',n)]]);return{id:r.id,rejected:true,rejected_by:u.name,rejected_at:at}},

  async edit_bill(env,u,{p}){p=p||{};if(!isMgr(u))fail('บัญชีนี้ไม่มีสิทธิ์แก้ไขบิล (เฉพาะเจ้าของร้าน/หัวหน้าสาขา)',403);
    const b=await getBill(env,+p.bill_id);if(!b||!canSee(u,b.branch_id))fail('ไม่พบบิล หรือไม่มีสิทธิ์แก้ไขบิลนี้');if(b.status==='void')fail('บิลนี้ถูกยกเลิกแล้ว แก้ไขไม่ได้');
    const st=[env.DB.prepare('update bills set snapshot=?,note=? where id=?').bind(JSON.stringify(p.snapshot??b.snapshot),p.note??b.note,b.id),
      env.DB.prepare('insert into bill_edits (bill_id,what,after,by_name) values (?,?,?,?)').bind(b.id,s(p.what).trim()||'แก้ไขข้อมูล',p.snapshot==null?null:JSON.stringify(p.snapshot),u.name)];
    const vid=p.veh_id?+p.veh_id:null,cid=p.cust_id?+p.cust_id:null,at=now();let vcust=null;
    if(vid){if(vid!==b.vehicle_id)fail('รถไม่ตรงกับบิลนี้');const VK=['plate','province','car_type','brand','model','cc','body','color','chassis_no','engine_no','weight_kg','reg_date'];
      const v=p.veh||{},ks=VK.filter(k=>k in v);vcust=await env.DB.prepare('select customer_id from vehicles where id=?').bind(vid).first('customer_id');
      if(ks.length)st.push(env.DB.prepare(`update vehicles set ${ks.map(k=>k+'=?').join(',')},updated_at=? where id=?`).bind(...ks.map(k=>k==='cc'||k==='weight_kg'?intOrNull(v[k]):k==='reg_date'?dOrNull(v[k]):s(v[k])),at,vid))}
    if(cid){const vc=vcust??await env.DB.prepare('select customer_id from vehicles where id=?').bind(b.vehicle_id).first('customer_id');
      if(cid!==b.customer_id&&cid!==vc)fail('ลูกค้าไม่ตรงกับบิลนี้');const CK=['prefix','first_name','last_name','tel','short_note','id_card','address','tumbol','amphoe','province','zipcode'];
      const c=p.cust||{},ks=CK.filter(k=>k in c);if(ks.length)st.push(env.DB.prepare(`update customers set ${ks.map(k=>k+'=?').join(',')},updated_at=? where id=?`).bind(...ks.map(k=>s(c[k])),at,cid))}
    await env.DB.batch(st);await logRows(env,u,[['bills','update',b,await getBill(env,b.id)],...(vid?[['vehicles','update',{},{id:vid}]]:[]),...(cid?[['customers','update',{},{id:cid}]]:[])]);return{ok:true,by:u.name}},

  async clear_files_pending(env,u,{p_bill}){if(!isMgr(u))fail('เฉพาะเจ้าของร้าน/หัวหน้าสาขา',403);const b=await getBill(env,p_bill);if(!b||!canSee(u,b.branch_id))fail('ไม่พบบิล');
    await env.DB.batch([env.DB.prepare(`update bills set files_pending='[]' where id=?`).bind(b.id),edit(env,b.id,'ยืนยันว่าเอกสารครบ ไม่ต้องแนบเพิ่ม',u.name)]);
    await logRows(env,u,[['bills','update',b,await getBill(env,b.id)]]);return null},

  async mark_delivered(env,u,{p_bill,p_undo}){const b=await getBill(env,p_bill);if(!b||!canSee(u,b.branch_id))fail('ไม่พบบิล');
    if(p_undo){if(!isMgr(u))fail('ยกเลิกการส่งมอบได้เฉพาะเจ้าของร้าน/หัวหน้าสาขา',403);
      await env.DB.batch([env.DB.prepare('update bills set delivered_at=null,delivered_by=null where id=?').bind(b.id),edit(env,b.id,'ยกเลิกสถานะส่งมอบเอกสาร',u.name)]);
      await logRows(env,u,[['bills','update',b,await getBill(env,b.id)]]);return{delivered_at:null}}
    await env.DB.batch([env.DB.prepare('update bills set delivered_at=coalesce(delivered_at,?),delivered_by=coalesce(delivered_by,?) where id=?').bind(now(),u.name,b.id),edit(env,b.id,'ส่งมอบเอกสารให้ลูกค้าแล้ว',u.name)]);
    const n=await getBill(env,b.id);await logRows(env,u,[['bills','update',b,n]]);return{delivered_at:n.delivered_at,delivered_by:n.delivered_by}},

  async set_insp_result(env,u,{p_bill,p_result,p_reason,p_retest,p_note}){const r=s(p_result).trim()||null,rs=s(p_reason).trim()||null,nt=s(p_note).trim()||null,rt=dOrNull(p_retest);
    if(r&&!['pass','fail'].includes(r))fail('ผลตรวจไม่ถูกต้อง');if(r==='fail'&&!rs&&p_reason!=null)fail('กรุณาระบุสาเหตุที่ตรวจไม่ผ่าน');
    const b=await getBill(env,p_bill);if(!b||!canSee(u,b.branch_id))fail('ไม่พบบิล');if(b.status==='void')fail('บิลนี้ถูกยกเลิกแล้ว');
    if(b.insp_result&&!isMgr(u))fail('บันทึกผลตรวจไปแล้ว การเปลี่ยนผลทำได้เฉพาะเจ้าของร้าน/หัวหน้าสาขา',403);
    const be=d=>{const [y,m,dd]=d.split('-');return `${dd}/${m}/${+y+543}`};
    const what=(r==='pass'?'บันทึกผลตรวจสภาพ: ผ่าน':r==='fail'?'บันทึกผลตรวจสภาพ: ไม่ผ่าน'+(rs?' · สาเหตุ: '+rs:'')+(rt?' · นัดตรวจซ้ำ '+be(rt):'')+(nt?' · '+nt:''):'ล้างผลตรวจสภาพ')
      +(b.insp_result?` (เดิม: ${b.insp_result==='pass'?'ผ่าน':'ไม่ผ่าน'})`:'');
    const at=r?now():null,f=r==='fail';
    await env.DB.batch([env.DB.prepare('update bills set insp_result=?,insp_at=?,insp_by=?,insp_reason=?,insp_retest=?,insp_note=? where id=?').bind(r,at,r?u.name:null,f?rs:null,f?rt:null,f?nt:null,b.id),edit(env,b.id,what,u.name)]);
    const n=await getBill(env,b.id);await logRows(env,u,[['bills','update',b,n]]);
    return{insp_result:n.insp_result,insp_at:n.insp_at,insp_by:n.insp_by,insp_reason:n.insp_reason,insp_retest:n.insp_retest,insp_note:n.insp_note}},

  async request_bill_action(env,u,{p_bill,p_kind,p_amount,p_method,p_reason}){if(!['void','refund'].includes(p_kind))fail('ประเภทคำขอไม่ถูกต้อง');if(!s(p_reason).trim())fail('กรุณาระบุเหตุผล');
    const b=await getBill(env,p_bill);if(!b||!canSee(u,b.branch_id))fail('ไม่พบบิล หรือไม่มีสิทธิ์');if(b.status==='void')fail('บิลนี้ถูกยกเลิกไปแล้ว');
    if(await env.DB.prepare(`select 1 from bill_requests where bill_id=? and status='pending'`).bind(b.id).first())fail('บิลนี้มีคำขอที่รออนุมัติอยู่แล้ว');
    if(await env.DB.prepare(`select 1 from payments where bill_id=? and kind='pay' and verified=0 and rejected=0`).bind(b.id).first())fail('บิลนี้มีเงินโอนรอตรวจสอบ กรุณายืนยันหรือปฏิเสธเงินโอนก่อน');
    const paid=await netPaid(env,b.id),amt=+p_amount||0;
    if(p_kind==='refund'){if(amt<=0)fail('จำนวนเงินที่คืนต้องมากกว่า 0');if(amt>paid+0.005)fail(`คืนเงินได้ไม่เกินยอดที่รับไว้ ${paid} บาท`)}
    const why=s(p_reason).trim();
    try{await env.DB.batch([env.DB.prepare('insert into bill_requests (bill_id,branch_id,kind,amount,method,reason,requested_by,requested_uid) values (?,?,?,?,?,?,?,?)').bind(b.id,b.branch_id,p_kind,p_kind==='void'?paid:amt,s(p_method)||'เงินสด',why,u.name,u.uid),
      edit(env,b.id,(p_kind==='void'?'ขอยกเลิกบิล':`ขอคืนเงิน ${money(amt)} บาท`)+' เหตุผล: '+why,u.name)])}
    catch(e){if(/UNIQUE/.test(e.message))fail('บิลนี้มีคำขอที่รออนุมัติอยู่แล้ว');throw e}
    const r=await env.DB.prepare(`select * from bill_requests where bill_id=? and status='pending'`).bind(b.id).first();await logRows(env,u,[['bill_requests','insert',null,r]]);return{id:r.id,status:'pending'}},

  async decide_bill_action(env,u,{p_id,p_approve,p_note}){if(!isMgr(u))fail('อนุมัติได้เฉพาะเจ้าของร้าน/หัวหน้าสาขา',403);
    const r=await env.DB.prepare('select * from bill_requests where id=?').bind(p_id).first();if(!r||!canSee(u,r.branch_id))fail('ไม่พบคำขอ');
    if(r.status!=='pending')fail(`คำขอนี้ดำเนินการไปแล้ว (${r.status})`);if(u.role==='head'&&r.requested_uid===u.uid)fail('หัวหน้าสาขาอนุมัติคำขอของตัวเองไม่ได้ ให้ผู้อื่นอนุมัติ');
    const note=s(p_note).trim()||null,at=now(),kindTh=r.kind==='void'?'ยกเลิกบิล':'คืนเงิน';
    // เงื่อนไข status='pending' ในคำสั่ง update กันการอนุมัติซ้ำพร้อมกันสองเครื่อง
    if(!p_approve){const x=await env.DB.batch([env.DB.prepare(`update bill_requests set status='rejected',decided_by=?,decided_at=?,decide_note=? where id=? and status='pending'`).bind(u.name,at,note,p_id),
        edit(env,r.bill_id,'ไม่อนุมัติคำขอ'+kindTh+(note?' : '+note:''),u.name)]);
      await logRows(env,u,[['bill_requests','update',r,{...r,status:'rejected'}]]);return{id:p_id,status:'rejected'}}
    const b=await getBill(env,r.bill_id);if(b.status==='void')fail('บิลนี้ถูกยกเลิกไปแล้ว');
    const w=await env.DB.prepare(`select count(*) n,coalesce(sum(amount),0) s from payments where bill_id=? and kind='pay' and verified=0 and rejected=0`).bind(b.id).first();
    if(w.n>0)fail(`บิลนี้ยังมีเงินโอนรอตรวจสอบ ${w.n} รายการ (${money(w.s)} บาท) กรุณายืนยันหรือปฏิเสธก่อนอนุมัติ`);
    const paid=await env.DB.prepare(`select coalesce(sum(case when kind='refund' then -amount else amount end),0) s from payments where bill_id=? and rejected=0 and (kind='refund' or verified=1)`).bind(b.id).first('s');
    const amt=r.kind==='void'?Math.max(paid,0):r.amount;if(amt>paid+0.005)fail(`ยอดที่รับไว้ (ยืนยันแล้ว) ตอนนี้ ${money(paid)} บาท น้อยกว่ายอดที่ขอคืน`);
    // คำสั่งแรกเปลี่ยนสถานะคำขอ ถ้าถูกอนุมัติไปแล้วจากอีกเครื่อง จะใส่ค่าไม่ถูกต้องให้ชน CHECK แล้วยกเลิกทั้งชุด
    const st=[env.DB.prepare(`update bill_requests set status=case when status='pending' then 'approved' else 'x' end,amount=?,decided_by=?,decided_at=?,decide_note=? where id=?`).bind(amt,u.name,at,note,p_id)];
    if(amt>0)st.push(env.DB.prepare(`insert into payments (bill_id,branch_id,amount,method,by_name,verified,verified_by,verified_at,kind,request_id,note) values (?,?,?,?,?,1,?,?,'refund',?,?)`).bind(b.id,b.branch_id,amt,r.method,u.name,u.name,at,r.id,r.reason));
    if(r.kind==='void'){st.push(env.DB.prepare(`update bills set status='void',void_reason=?,void_by=?,void_approved_by=?,void_at=? where id=?`).bind(r.reason,r.requested_by,u.name,at,b.id));
      st.push(env.DB.prepare('update insp_queue set billed=0,bill_id=null where bill_id=?').bind(b.id))}
    else{st.push(env.DB.prepare('update bills set refund_total=refund_total+? where id=?').bind(amt,b.id));st.push(env.DB.prepare(statusSql).bind(b.id))}
    st.push(edit(env,b.id,(r.kind==='void'?'อนุมัติยกเลิกบิล'+(amt>0?` คืนเงิน ${money(amt)} บาท`:''):`อนุมัติคืนเงิน ${money(amt)} บาท`)+` (ขอโดย ${r.requested_by})`,u.name));
    try{await env.DB.batch(st)}catch(e){if(/CHECK/.test(e.message))fail('คำขอนี้ดำเนินการไปแล้ว');throw e}
    await logRows(env,u,[['bill_requests','update',r,{...r,status:'approved'}],['bills','update',b,await getBill(env,b.id)]]);return{id:p_id,status:'approved',amount:amt}},
};
