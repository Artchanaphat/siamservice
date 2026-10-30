// เงิน: ภาพรวมเจ้าของ / รายละเอียด / สรุปรายเดือน / รับทราบปิดยอด / อนุมัติขอเบิก
import {fail,canSee,isMgr} from './auth.js';
import {now} from './meta.js';
import {log,dayRange,bkkDate,drawerOut} from './hooks.js';
import {money} from './rpc_bills.js';

const CASH=`instr(M,'สด')>0`,TR=`instr(M,'สด')=0 and instr(M,'โอน')>0`,CARD=`instr(M,'สด')=0 and instr(M,'โอน')=0 and instr(M,'บัตร')>0`,OTH=`instr(M,'สด')=0 and instr(M,'โอน')=0 and instr(M,'บัตร')=0`;
const m=(s,col)=>s.replace(/M/g,col);
const PASS=`(select coalesce(sum(json_extract(it.value,'$[1]')),0) from json_each(bi.items) it where json_extract(it.value,'$[0]') in (select value from json_each(?)))`;
const HAS_ITEM=n=>`exists (select 1 from json_each(bi.items) it where json_extract(it.value,'$[0]')=${n})`;
const ago=d=>new Date(Date.now()-d*864e5).toISOString();
const addDays=(d,n)=>{const x=new Date(d+'T00:00:00Z');x.setUTCDate(x.getUTCDate()+n);return x.toISOString().slice(0,10)};
const one=(env,sql,...a)=>env.DB.prepare(sql).bind(...a).first();
const all=async(env,sql,...a)=>(await env.DB.prepare(sql).bind(...a).all()).results;
const owner=u=>{if(u.role!=='owner')fail('ใช้ได้เฉพาะเจ้าของร้าน',403)};
const pj=a=>JSON.stringify(Array.isArray(a)?a:[]);

async function monthPart(env,br,from,to,pass){const [t0]=dayRange(from),[,t1]=dayRange(to);
  const r=await one(env,`select count(*) bills,count(distinct coalesce(json_extract(bi.snapshot,'$.plate'),'')||'|'||coalesce(json_extract(bi.snapshot,'$.prov'),'')) cars,
    coalesce(sum(bi.total-bi.refund_total),0) total,coalesce(sum(${PASS}),0) pass from bills bi where bi.branch_id=? and bi.status<>'void' and bi.bill_at>=? and bi.bill_at<?`,pj(pass),br,t0,t1);
  r.expense=await one(env,'select coalesce(sum(amount),0) s from expenses where branch_id=? and exp_date between ? and ?',br,from,to).then(x=>x.s);
  r.recv=await one(env,`select coalesce(sum(case when kind='refund' then -amount else amount end),0) s from payments where branch_id=? and rejected=0 and (verified=1 or kind='refund') and paid_at>=? and paid_at<?`,br,t0,t1).then(x=>x.s);
  return r}

export const MONEY={
  async ack_close(env,u,{p_branch,p_day,p_note}){owner(u);
    await env.DB.prepare(`insert into close_acks (branch_id,close_date,ack_by,ack_note,ack_at) values (?,?,?,?,?) on conflict(branch_id,close_date) do update set ack_by=excluded.ack_by,ack_note=excluded.ack_note,ack_at=excluded.ack_at`).bind(p_branch,p_day,u.name,p_note||'',now()).run();
    await log(env,u,'close_acks','insert',null,{branch_id:p_branch,close_date:p_day,ack_note:p_note||''});return{ok:true}},

  async decide_exp_request(env,u,{p_id,p_approve,p_paid_from='drawer',p_drawer='',p_note=''}){const r=await one(env,'select * from exp_requests where id=?',p_id);if(!r)fail('ไม่พบคำขอเบิก');
    if(!isMgr(u)||!canSee(u,r.branch_id))fail('อนุมัติได้เฉพาะเจ้าของร้าน/หัวหน้าสาขา',403);if(r.status!=='pending')fail('คำขอนี้ถูกพิจารณาไปแล้ว');
    if(u.role==='head'&&r.req_uid===u.uid)fail('หัวหน้าสาขาอนุมัติคำขอของตัวเองไม่ได้ ให้เจ้าของร้านอนุมัติ');
    if(!['drawer','bank','owner'].includes(p_paid_from||''))fail('กรุณาเลือกว่าจ่ายด้วยอะไร');const at=now(),st=[];
    if(p_approve)st.push(env.DB.prepare(`insert into expenses (branch_id,exp_date,category,amount,note,by_name,paid_from,drawer_staff,photo) values (?,?,?,?,?,?,?,?,?)`)
      .bind(r.branch_id,bkkDate(),r.category,r.amount,(r.note+(r.req_by?` (ขอเบิกโดย ${r.req_by})`:'')).trim(),u.name,p_paid_from,p_paid_from==='drawer'?(p_drawer||u.name):'',r.photo));
    st.push(env.DB.prepare(`update exp_requests set status=case when status='pending' then ? else 'x' end,decided_by=?,decided_at=?,decide_note=?,expense_id=${p_approve?'(select max(id) from expenses)':'null'} where id=?`)
      .bind(p_approve?'approved':'rejected',u.name,at,p_note||'',p_id));
    try{await env.DB.batch(st)}catch(e){if(/CHECK/.test(e.message))fail('คำขอนี้ถูกพิจารณาไปแล้ว');throw e}
    const n=await one(env,'select * from exp_requests where id=?',p_id);
    await log(env,u,'exp_requests','update',r,n);if(n.expense_id)await log(env,u,'expenses','insert',null,await one(env,'select * from expenses where id=?',n.expense_id));
    return{status:n.status,expense_id:n.expense_id}},

  async monthly_stats(env,u,{p_from,p_pass}){const [t0]=dayRange(p_from),brw=u.role==='owner'?'':' and bi.branch_id='+(+u.branch),erw=u.role==='owner'?'':' and branch_id='+(+u.branch);
    const bm=await all(env,`select bi.branch_id,strftime('%Y-%m',bi.bill_at,'+7 hours') ym,count(*) bills,count(distinct coalesce(json_extract(bi.snapshot,'$.plate'),'')||'|'||coalesce(json_extract(bi.snapshot,'$.prov'),'')) cars,
      sum(bi.total-bi.refund_total) total,sum(${PASS}) passthru from bills bi where bi.status<>'void' and bi.bill_at>=?${brw} group by 1,2`,pj(p_pass),t0);
    const em=await all(env,`select branch_id,substr(exp_date,1,7) ym,sum(amount) expense from expenses where exp_date>=?${erw} group by 1,2`,p_from);
    const k=x=>x.branch_id+'|'+x.ym,M=new Map();for(const x of bm)M.set(k(x),{...x,expense:0});
    for(const x of em){const o=M.get(k(x));if(o)o.expense=x.expense;else M.set(k(x),{branch_id:x.branch_id,ym:x.ym,bills:0,cars:0,total:0,passthru:0,expense:x.expense})}
    return[...M.values()].sort((a,z)=>a.ym.localeCompare(z.ym)||a.branch_id-z.branch_id)},

  async owner_overview(env,u,{p_day,p_pass}){owner(u);const d=p_day,[t0,t1]=dayRange(d),m0=d.slice(0,8)+'01',pm0=addDays(m0,-1).slice(0,8)+'01',pmEnd=addDays(m0,-1);
    const off=(new Date(d)-new Date(m0))/864e5,pm1=addDays(pm0,off)<pmEnd?addDays(pm0,off):pmEnd,a400=ago(400),a30=ago(30);
    const st=JSON.parse((await one(env,`select value from app_settings where key='main'`)||{}).value||'{}');
    const lr=+st.dlt_late_received||2,ls=+st.dlt_late_submitted||7,lp=+st.dlt_late_plate||14;
    const vItems=[...(st.dlt_items_tax||['ค่าภาษีรถ','ค่าฝากต่อภาษี']),...(st.dlt_items_tr||['ค่าโอน','ค่าย้าย','ค่าโอนย้าย','ค่าเปลี่ยนสี','ค่าตรวจสภาพโอน','ค่าเรื่อง'])];
    // ทำทุกสาขาพร้อมกัน
    const out=await Promise.all((await all(env,'select id,code,name from branches where active=1 order by id')).map(async b=>{const B=b.id;
      const veh=await all(env,`select k,max(moto) moto from (
          select coalesce(json_extract(snapshot,'$.plate'),'')||'|'||coalesce(json_extract(snapshot,'$.prov'),'') k,max(instr(coalesce(json_extract(snapshot,'$.type'),''),'จักรยานยนต์')>0) moto from bills where branch_id=? and status<>'void' and bill_at>=? and bill_at<? group by 1
          union all select plate||'|'||province,max(car_type in ('รย.12','รย.17')) from insp_queue q where branch_id=? and created_at>=? and created_at<? and billed=0
            and not exists (select 1 from bills x where x.branch_id=? and x.bill_at>=? and x.bill_at<? and json_extract(x.snapshot,'$.plate')=q.plate and json_extract(x.snapshot,'$.prov')=q.province) group by 1) group by k`,B,t0,t1,B,t0,t1,B,t0,t1);
      const today={car:veh.filter(x=>!x.moto).length,moto:veh.filter(x=>x.moto).length};
      Object.assign(today,await one(env,`select count(*) bills,coalesce(sum(total-refund_total),0) bill_sum,sum(${HAS_ITEM("'ค่าตรวจสภาพ'")}) insp from bills bi where branch_id=? and status<>'void' and bill_at>=? and bill_at<?`,B,t0,t1));today.insp=today.insp||0;
      Object.assign(today,await one(env,`select coalesce(sum(status='pass'),0) pass,coalesce(sum(status='fail'),0) fail,coalesce(sum(status in ('wait','check')),0) wait from insp_queue where branch_id=? and created_at>=? and created_at<?`,B,t0,t1));
      Object.assign(today,await one(env,`select coalesce(sum(case when ${m(CASH,'m')} then a end),0) cash,coalesce(sum(case when ${m(TR,'m')} then a end),0) tr,coalesce(sum(case when ${m(CARD,'m')} then a end),0) card,
          coalesce(sum(case when ${m(OTH,'m')} then a end),0) other,coalesce(sum(k='refund'),0) ref_n,coalesce(-sum(case when k='refund' then a end),0) ref_sum
        from (select coalesce(method,'') m,kind k,case when kind='refund' then -amount else amount end a from payments where branch_id=? and paid_at>=? and paid_at<? and rejected=0 and (verified=1 or kind='refund'))`,B,t0,t1));
      Object.assign(today,await one(env,`select count(*) pend_n,coalesce(sum(amount),0) pend_sum from payments where branch_id=? and paid_at>=? and paid_at<? and kind='pay' and verified=0 and rejected=0`,B,t0,t1));
      const cc=await all(env,'select * from cash_closes where branch_id=? and close_date=? order by staff_name',B,d);
      const close={staff_n:(await one(env,`select count(distinct coalesce(nullif(by_name,''),'ไม่ระบุ')) n from payments where branch_id=? and paid_at>=? and paid_at<? and rejected=0 and (verified=1 or kind='refund')`,B,t0,t1)).n,
        close_n:cc.length,counted_n:cc.filter(x=>x.counted_cash!=null).length,diff:cc.filter(x=>x.counted_cash!=null).reduce((t,x)=>t+x.counted_cash-x.cash-x.float_cash+x.cash_out,0),
        float:cc.reduce((t,x)=>t+x.float_cash,0),cash_out:cc.reduce((t,x)=>t+x.cash_out,0),by:cc.length?cc.map(x=>x.closed_by_name).sort().pop():null,at:cc.length?cc.map(x=>x.updated_at||x.created_at).sort().pop():null,
        sum:cc.reduce((t,x)=>t+x.cash+x.transfer+x.card+x.other,0),
        rows:cc.map(x=>({staff:x.staff_name,cash:x.cash,float:x.float_cash,out:x.cash_out,counted:x.counted_cash,diff:x.counted_cash==null?null:x.counted_cash-x.cash-x.float_cash+x.cash_out,note:x.note||''}))};
      const ack=await one(env,'select ack_by by_,ack_note note,ack_at at from close_acks where branch_id=? and close_date=?',B,d);close.ack=ack?{by:ack.by_,note:ack.note,at:ack.at}:null;
      Object.assign(today,{q_all:(await one(env,'select count(*) n from insp_queue where branch_id=? and created_at>=? and created_at<?',B,t0,t1)).n,
        q_wait:(await one(env,`select count(*) n from insp_queue where branch_id=? and created_at>=? and created_at<? and status='wait'`,B,t0,t1)).n,
        q_check:(await one(env,`select count(*) n from insp_queue where branch_id=? and created_at>=? and created_at<? and status='check'`,B,t0,t1)).n,
        docs_wait:(await one(env,`select count(*) n from dlt_jobs j join bills bi on bi.id=j.bill_id where bi.branch_id=? and bi.status<>'void' and j.status<>'done' and bi.bill_at>=?`,B,a400)).n,
        last:[(await one(env,'select max(created_at) x from bills where branch_id=? and bill_at>=? and bill_at<?',B,t0,t1)).x,(await one(env,'select max(paid_at) x from payments where branch_id=? and paid_at>=? and paid_at<?',B,t0,t1)).x,
          (await one(env,'select max(coalesce(updated_at,created_at)) x from insp_queue where branch_id=? and created_at>=? and created_at<?',B,t0,t1)).x].filter(Boolean).sort().pop()||null});
      const sm=async(t,dc,ex='')=>(await one(env,`select coalesce(sum(amount),0) s from ${t} where branch_id=? and ${dc}=?${ex}`,B,d)).s;
      const outx={exp:await sm('expenses','exp_date'),exp_n:(await one(env,'select count(*) n from expenses where branch_id=? and exp_date=?',B,d)).n,remit:await sm('remits','remit_date'),
        owner:await sm('cash_outs','out_date'," and kind='owner'"),bank:await sm('cash_outs','out_date'," and kind='bank'"),advance:await sm('cash_outs','out_date'," and kind='advance'"),other:await sm('cash_outs','out_date'," and kind='other'"),drawer:await drawerOut(env,B,d,null)};
      const todo={transfers:(await all(env,`select p.id,p.bill_id,bi.bill_no,json_extract(bi.snapshot,'$.plate') plate,json_extract(bi.snapshot,'$.name') name,p.amount amt,p.by_name by_,p.paid_at at,coalesce(p.note,'') note,(select count(*) from bill_files f where f.bill_id=p.bill_id) files
          from payments p join bills bi on bi.id=p.bill_id where p.branch_id=? and p.kind='pay' and p.verified=0 and p.rejected=0 order by p.paid_at`,B)).map(({by_,...x})=>({...x,by:by_})),
        bill_reqs:(await all(env,`select r.id,r.bill_id,bi.bill_no,json_extract(bi.snapshot,'$.plate') plate,r.kind,r.amount amt,r.reason,r.requested_by by_,r.requested_at at,bi.total-bi.refund_total total from bill_requests r join bills bi on bi.id=r.bill_id where r.branch_id=? and r.status='pending' order by r.requested_at`,B)).map(({by_,...x})=>({...x,by:by_})),
        exp_reqs:(await all(env,`select id,category cat,amount amt,note,req_by by_,req_date d,photo<>'' photo from exp_requests where branch_id=? and status='pending' order by created_at`,B)).map(({by_,...x})=>({...x,by:by_,photo:!!x.photo})),
        unclosed:(await all(env,`select distinct date(p.paid_at,'+7 hours') d from payments p where p.branch_id=? and p.paid_at>=? and p.paid_at<? and p.rejected=0 and (p.verified=1 or p.kind='refund')
          and not exists (select 1 from cash_closes c where c.branch_id=? and c.close_date=date(p.paid_at,'+7 hours')) order by d`,B,new Date(new Date(t0).getTime()-7*864e5).toISOString(),t1,B)).map(x=>x.d)};
      const PD=`left join (select bill_id,sum(case when kind='refund' then -amount when verified=1 and rejected=0 then amount else 0 end) paid from payments group by bill_id) p on p.bill_id=bi.id`;
      const follow=await one(env,`select coalesce(sum(max(bi.total-bi.refund_total-coalesce(p.paid,0),0)),0) debt,coalesce(sum(bi.total-bi.refund_total-coalesce(p.paid,0)>0.004),0) debt_n,
        coalesce(sum(case when bi.bill_at<? then max(bi.total-bi.refund_total-coalesce(p.paid,0),0) else 0 end),0) debt_old from bills bi ${PD} where bi.branch_id=? and bi.status<>'void' and bi.bill_at>=?`,a30,B,a400);
      const late=await all(env,`select bi.bill_at,j.status,j.submitted_at,j.plate_at from bills bi left join dlt_jobs j on j.bill_id=bi.id where bi.branch_id=? and bi.status<>'void' and bi.bill_at>=?
        and exists (select 1 from json_each(bi.items) it where json_extract(it.value,'$[0]') in (select value from json_each(?))) and coalesce(j.status,'received')<>'done'`,B,a400,JSON.stringify(vItems));
      follow.dlt_late=late.filter(x=>{const s=x.status||'received',from=s==='received'?x.bill_at:s==='submitted'?(x.submitted_at||x.bill_at):(x.plate_at||x.bill_at);return Date.now()-new Date(from)>(s==='received'?lr:s==='submitted'?ls:lp)*864e5}).length;
      follow.dlt_wait=(await one(env,`select count(*) n from dlt_jobs j join bills bi on bi.id=j.bill_id where bi.branch_id=? and bi.status<>'void' and j.status='plate'`,B)).n;
      Object.assign(follow,await one(env,`select coalesce(sum(amount),0) adv,count(distinct person) adv_n from cash_outs where branch_id=? and kind='advance' and settled_ym=''`,B));
      follow.remit_paid_mtd=(await one(env,'select coalesce(sum(amount),0) s from remits where branch_id=? and remit_date>=? and remit_date<=?',B,m0,d)).s;
      const [mtd,prev]=await Promise.all([monthPart(env,B,m0,d,p_pass),monthPart(env,B,pm0,pm1,p_pass)]);
      return{id:B,code:b.code,name:b.name,today,close,out:outx,mtd,prev,todo,follow}}));
    return{day:d,prev_from:pm0,prev_to:pm1,branches:out}},

  async owner_detail(env,u,{p_kind,p_sub,p_branch,p_from,p_to,p_pass}){owner(u);const [t0]=dayRange(p_from),[,t1]=dayRange(p_to),sub=p_sub||'all',bw=c=>p_branch==null?'1=1':`${c}=${+p_branch}`;
    const fix=r=>r.map(({by_,...x})=>({...x,by:by_??x.by}));let r;
    const pmeth=`(case when p.kind='refund' then p.method||' (คืนเงิน)' else p.method end)`;
    switch(p_kind){
      case 'pay':{const f=sub==='cash'?m(CASH,'p.method'):sub==='tr'?m(TR,'p.method'):sub==='card'?`instr(p.method,'สด')=0 and instr(p.method,'โอน')=0`:'1=1';
        r=await all(env,`select br.name br,p.paid_at at,bi.bill_no no,json_extract(bi.snapshot,'$.plate') plate,json_extract(bi.snapshot,'$.name') name,p.by_name by_,${pmeth} how,case when p.kind='refund' then -p.amount else p.amount end amt,
          trim(coalesce(nullif(p.note,''),'')||case when p.verified_by is not null and instr(p.method,'โอน')>0 then case when coalesce(p.note,'')<>'' then ' · ' else '' end||'ตรวจโดย '||p.verified_by else '' end) note
          from payments p join bills bi on bi.id=p.bill_id join branches br on br.id=p.branch_id where ${bw('p.branch_id')} and p.paid_at>=? and p.paid_at<? and p.rejected=0 and (p.verified=1 or p.kind='refund') and ${f} order by p.paid_at limit 500`,t0,t1);break}
      case 'pend':r=await all(env,`select br.name br,p.paid_at at,bi.bill_no no,json_extract(bi.snapshot,'$.plate') plate,json_extract(bi.snapshot,'$.name') name,p.by_name by_,p.method how,p.amount amt,coalesce(p.note,'') note
          from payments p join bills bi on bi.id=p.bill_id join branches br on br.id=p.branch_id where ${bw('p.branch_id')} and p.kind='pay' and p.verified=0 and p.rejected=0 and (?='all' or (p.paid_at>=? and p.paid_at<?)) order by p.paid_at limit 500`,sub,t0,t1);break;
      case 'bills':r=await all(env,`select br.name br,bi.bill_at at,bi.bill_no no,json_extract(bi.snapshot,'$.plate') plate,json_extract(bi.snapshot,'$.name') name,coalesce(s.full_name,'') by_,bi.total-bi.refund_total amt,${PASS} pass,
          (select group_concat(json_extract(it.value,'$[0]'),', ') from json_each(bi.items) it) note from bills bi join branches br on br.id=bi.branch_id left join staff s on s.user_id=bi.created_by
          where ${bw('bi.branch_id')} and bi.status<>'void' and bi.bill_at>=? and bi.bill_at<? and (?='all' or (?='insp' and ${HAS_ITEM("'ค่าตรวจสภาพ'")})) order by bi.bill_at limit 500`,pj(p_pass),t0,t1,sub,sub);break;
      case 'exp':r=await all(env,`select br.name br,e.exp_date at,e.category name,e.by_name by_,e.amount amt,case e.paid_from when 'drawer' then 'เงินสดในลิ้นชัก '||e.drawer_staff when 'bank' then 'โอนจากบัญชีร้าน' when 'owner' then 'เจ้าของจ่ายเอง' else '' end how,e.note
          from expenses e join branches br on br.id=e.branch_id where ${bw('e.branch_id')} and e.exp_date between ? and ? order by e.exp_date limit 500`,p_from,p_to);break;
      case 'remit':r=await all(env,`select br.name br,x.remit_date at,x.payee name,x.by_name by_,x.amount amt,case x.method when 'drawer' then 'เงินสดในลิ้นชัก '||x.drawer_staff when 'bank' then 'โอนจากบัญชีร้าน' when 'owner' then 'เจ้าของจ่ายเอง' else x.method end how,x.note
          from remits x join branches br on br.id=x.branch_id where ${bw('x.branch_id')} and x.remit_date between ? and ? order by x.remit_date limit 500`,p_from,p_to);break;
      case 'cashout':case 'adv':r=await all(env,`select br.name br,o.out_date at,o.person name,o.by_name by_,o.amount amt,case o.kind when 'owner' then 'เจ้าของเก็บเงินสด' when 'bank' then 'ฝากธนาคาร' when 'advance' then 'เบิกล่วงหน้า' else 'อื่นๆ' end
          ||case when o.paid_from='drawer' then ' (ลิ้นชัก '||o.drawer_staff||')' else '' end how,o.note from cash_outs o join branches br on br.id=o.branch_id where ${bw('o.branch_id')} and `+
          (p_kind==='adv'?`o.kind='advance' and o.settled_ym=''`:`o.out_date between ? and ? and (?='all' or o.kind=?)`)+' order by o.out_date limit 500',...(p_kind==='adv'?[]:[p_from,p_to,sub,sub]));break;
      case 'drawer':r=await all(env,`select * from (select br.name br,e.exp_date at,'รายจ่าย: '||e.category name,e.drawer_staff by_,e.amount amt,e.note from expenses e join branches br on br.id=e.branch_id where ${bw('e.branch_id')} and e.exp_date between ?1 and ?2 and e.paid_from='drawer'
          union all select br.name,x.remit_date,'เงินนำส่ง: '||x.payee,x.drawer_staff,x.amount,x.note from remits x join branches br on br.id=x.branch_id where ${bw('x.branch_id')} and x.remit_date between ?1 and ?2 and x.method='drawer'
          union all select br.name,o.out_date,'นำเงินสดออก: '||o.person,o.drawer_staff,o.amount,o.note from cash_outs o join branches br on br.id=o.branch_id where ${bw('o.branch_id')} and o.out_date between ?1 and ?2 and o.paid_from='drawer') order by at`,p_from,p_to);break;
      case 'debt':r=(await all(env,`select br.name br,bi.bill_at at,bi.bill_no no,json_extract(bi.snapshot,'$.plate') plate,json_extract(bi.snapshot,'$.name') name,coalesce(s.full_name,'') by_,bi.total-bi.refund_total-coalesce(p.paid,0) amt,bi.total-bi.refund_total t
          from bills bi join branches br on br.id=bi.branch_id left join staff s on s.user_id=bi.created_by left join (select bill_id,sum(case when kind='refund' then -amount when verified=1 and rejected=0 then amount else 0 end) paid from payments group by bill_id) p on p.bill_id=bi.id
          where ${bw('bi.branch_id')} and bi.status<>'void' and bi.bill_at>=? and bi.total-bi.refund_total-coalesce(p.paid,0)>0.004 and (?='all' or (?='old' and bi.bill_at<?)) order by bi.bill_at limit 500`,ago(400),sub,sub,ago(30))).map(({t,...x})=>({...x,note:'ยอดบิล '+money(t)}));break;
      case 'docs':r=await all(env,`select br.name br,bi.bill_at at,bi.bill_no no,json_extract(bi.snapshot,'$.plate') plate,json_extract(bi.snapshot,'$.name') name,coalesce(j.updated_by_name,'') by_,
          case j.status when 'received' then 'รอยื่นขนส่ง' when 'submitted' then 'ยื่นแล้ว รอป้าย/เล่ม' when 'plate' then 'ได้แล้ว รอลูกค้ารับ' else j.status end how,coalesce(j.note,'') note
          from dlt_jobs j join bills bi on bi.id=j.bill_id join branches br on br.id=bi.branch_id where ${bw('bi.branch_id')} and bi.status<>'void' and j.status<>'done' and bi.bill_at>=? and (?='all' or j.status=?) order by bi.bill_at limit 500`,ago(400),sub,sub);break;
      case 'queue':r=await all(env,`select br.name br,q.created_at at,q.plate,q.cust_name name,coalesce(q.updated_by_name,'') by_,case q.status when 'wait' then 'รอตรวจ' when 'check' then 'กำลังตรวจ' when 'pass' then 'ผ่าน' when 'fail' then 'ไม่ผ่าน' else q.status end how,coalesce(q.note,'') note
          from insp_queue q join branches br on br.id=q.branch_id where ${bw('q.branch_id')} and q.created_at>=? and q.created_at<? and (?='all' or q.status=? or (?='done' and q.status in ('pass','fail'))) order by q.created_at limit 500`,t0,t1,sub,sub,sub);break;
      default:fail('ไม่รู้จักรายการ '+p_kind)}
    return fix(r)},
};
