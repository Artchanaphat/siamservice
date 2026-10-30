// LINE (สรุปประจำวัน, แจ้งเตือนลูกค้า, webhook ผูกลูกค้า) + SMS (ThaiBulkSMS) + งานตั้งเวลา
import {fail,canSee} from './auth.js';
import {dayRange,bkkDate} from './hooks.js';
import {money} from './rpc_bills.js';

const getS=async(env,n)=>(await env.DB.prepare('select value from secrets where name=?').bind(n).first('value'))||'';
const one=(env,sql,...a)=>env.DB.prepare(sql).bind(...a).first();
const be=d=>{const [y,m,dd]=d.split('-');return `${dd}/${m}/${+y+543}`};
const addDays=(d,n)=>{const x=new Date(d+'T00:00:00Z');x.setUTCDate(x.getUTCDate()+n);return x.toISOString().slice(0,10)};

export async function lineSend(env,to,text,reply){const tok=await getS(env,'line_token');if(!tok)fail('ยังไม่ได้ใส่ Channel access token ในหน้าตั้งค่า');
  const r=await fetch('https://api.line.me/v2/bot/message/'+(reply?'reply':'push'),{method:'POST',headers:{'content-type':'application/json',authorization:'Bearer '+tok},
    body:JSON.stringify({...(reply?{replyToken:reply}:{to}),messages:[{type:'text',text:String(text).slice(0,4900)}]})});
  if(!r.ok)console.warn('line',r.status,await r.text())}

export async function dailyText(env,day){const d=day||bkkDate(),[t0,t1]=dayRange(d),a400=new Date(Date.now()-400*864e5).toISOString();
  const st=JSON.parse((await one(env,`select value from app_settings where key='main'`)||{}).value||'{}');
  const lr=+st.dlt_late_received||2,ls=+st.dlt_late_submitted||7,lp=+st.dlt_late_plate||14;
  const vItems=JSON.stringify([...(st.dlt_items_tax||['ค่าภาษีรถ','ค่าฝากต่อภาษี']),...(st.dlt_items_tr||['ค่าโอน','ค่าย้าย','ค่าโอนย้าย','ค่าเปลี่ยนสี','ค่าตรวจสภาพโอน','ค่าเรื่อง'])]);
  let txt='📊 สรุปประจำวัน '+be(d);
  for(const b of (await env.DB.prepare('select id,name from branches where active=1 order by id').all()).results){const B=b.id;
    const bill=await one(env,`select count(*) n,coalesce(sum(total-refund_total),0) s from bills where branch_id=? and status<>'void' and bill_at>=? and bill_at<?`,B,t0,t1);
    const veh=(await env.DB.prepare(`select k,max(moto) moto from (select coalesce(json_extract(snapshot,'$.plate'),'')||'|'||coalesce(json_extract(snapshot,'$.prov'),'') k,max(instr(coalesce(json_extract(snapshot,'$.type'),''),'จักรยานยนต์')>0) moto from bills where branch_id=?1 and status<>'void' and bill_at>=?2 and bill_at<?3 group by 1
      union all select plate||'|'||province,max(car_type in ('รย.12','รย.17')) from insp_queue q where branch_id=?1 and created_at>=?2 and created_at<?3 and billed=0
      and not exists (select 1 from bills x where x.branch_id=?1 and x.bill_at>=?2 and x.bill_at<?3 and json_extract(x.snapshot,'$.plate')=q.plate and json_extract(x.snapshot,'$.prov')=q.province) group by 1) group by k`).bind(B,t0,t1).all()).results;
    const car=veh.filter(x=>!x.moto).length,moto=veh.length-car;
    const pay=await one(env,`select coalesce(sum(case when instr(m,'สด')>0 then a end),0) cash,coalesce(sum(case when instr(m,'สด')=0 and instr(m,'โอน')>0 then a end),0) tr,coalesce(sum(case when instr(m,'สด')=0 and instr(m,'โอน')=0 then a end),0) oth
      from (select coalesce(method,'') m,case when kind='refund' then -amount else amount end a from payments where branch_id=? and paid_at>=? and paid_at<? and rejected=0 and (verified=1 or kind='refund'))`,B,t0,t1);
    const ref=await one(env,`select count(*) n,coalesce(sum(amount),0) s from payments where branch_id=? and paid_at>=? and paid_at<? and kind='refund'`,B,t0,t1);
    const pend=await one(env,`select count(*) n,coalesce(sum(amount),0) s from payments where branch_id=? and paid_at>=? and paid_at<? and kind='pay' and verified=0 and rejected=0`,B,t0,t1);
    const pendAll=await one(env,`select count(*) n,coalesce(sum(amount),0) s from payments where branch_id=? and kind='pay' and verified=0 and rejected=0`,B);
    const debt=(await one(env,`select coalesce(sum(max(bi.total-bi.refund_total-coalesce(p.paid,0),0)),0) s from bills bi left join (select bill_id,sum(case when kind='refund' then -amount when verified=1 and rejected=0 then amount else 0 end) paid from payments group by bill_id) p on p.bill_id=bi.id where bi.branch_id=? and bi.status<>'void' and bi.bill_at>=?`,B,a400)).s;
    const nStaff=(await one(env,`select count(distinct by_name) n from payments where branch_id=? and paid_at>=? and paid_at<? and rejected=0 and (verified=1 or kind='refund')`,B,t0,t1)).n;
    const cl=await one(env,`select count(*) n,coalesce(sum(case when counted_cash is not null then counted_cash-cash-float_cash+cash_out end),0) d,coalesce(sum(cash+transfer+card+other),0) s from cash_closes where branch_id=? and close_date=?`,B,d);
    const ex=await one(env,`select count(*) n,coalesce(sum(amount),0) s,coalesce(sum(case when paid_from='drawer' then amount end),0) dr from expenses where branch_id=? and exp_date=?`,B,d);
    const rm=await one(env,'select count(*) n,coalesce(sum(amount),0) s from remits where branch_id=? and remit_date=?',B,d);
    const co=await one(env,`select coalesce(sum(case when kind='owner' then amount end),0) ow,coalesce(sum(case when kind='bank' then amount end),0) bk,coalesce(sum(case when kind='advance' then amount end),0) adv,coalesce(sum(case when kind='other' then amount end),0) oth from cash_outs where branch_id=? and out_date=?`,B,d);
    const req=await one(env,`select count(*) n,coalesce(sum(amount),0) s from exp_requests where branch_id=? and status='pending'`,B);
    const nInsp=(await one(env,`select count(*) n from bills bi where branch_id=? and status<>'void' and bill_at>=? and bill_at<? and exists (select 1 from json_each(bi.items) it where json_extract(it.value,'$[0]')='ค่าตรวจสภาพ')`,B,t0,t1)).n;
    const old=await one(env,`select count(distinct p.bill_id) n,coalesce(sum(p.amount),0) s from payments p join bills bi on bi.id=p.bill_id where p.branch_id=? and p.paid_at>=? and p.paid_at<? and p.kind='pay' and p.verified=1 and p.rejected=0 and bi.bill_at<?`,B,t0,t1,t0);
    const q=await one(env,`select coalesce(sum(status='pass'),0) p,coalesce(sum(status='fail'),0) f from insp_queue where branch_id=? and created_at>=? and created_at<?`,B,t0,t1);
    const late=(await env.DB.prepare(`select bi.bill_at,j.status,j.submitted_at,j.plate_at from bills bi left join dlt_jobs j on j.bill_id=bi.id where bi.branch_id=? and bi.status<>'void' and bi.bill_at>=?
      and exists (select 1 from json_each(bi.items) it where json_extract(it.value,'$[0]') in (select value from json_each(?))) and coalesce(j.status,'received')<>'done'`).bind(B,a400,vItems).all()).results
      .filter(x=>{const s=x.status||'received',f=s==='received'?x.bill_at:s==='submitted'?(x.submitted_at||x.bill_at):(x.plate_at||x.bill_at);return Date.now()-new Date(f)>(s==='received'?lr:s==='submitted'?ls:lp)*864e5}).length;
    const recv=pay.cash+pay.tr+pay.oth;
    txt+=`\n\n🏢 ${b.name}\n• รถเข้าวันนี้ ${car+moto} คัน (รถยนต์ ${car} / มอเตอร์ไซค์ ${moto})\n• บิลวันนี้ ${bill.n} ใบ ยอด ${money(bill.s)} บาท`
      +`\n• รับเงิน (ตรวจแล้ว): สด ${money(pay.cash)} / โอน ${money(pay.tr)}`+(pay.oth?` / อื่นๆ ${money(pay.oth)}`:'')
      +`\n• รวมรับ ${money(recv)} บาท`+(ref.n>0?` (หักคืนเงินแล้ว ${money(ref.s)} บาท ${ref.n} รายการ)`:'')
      +(old.n>0?`\n• รับชำระบิลวันก่อน ${old.n} ใบ ${money(old.s)} บาท (รวมในยอดรับแล้ว)`:'')
      +(pend.n>0?`\n• ⏳ เงินโอนรอตรวจ ${pend.n} รายการ ${money(pend.s)} บาท (ยังไม่นับในยอดรับ)`:'')
      +(pendAll.n>pend.n?`\n• ⏳ เงินโอนค้างตรวจจากวันก่อน ${pendAll.n-pend.n} รายการ ${money(pendAll.s-pend.s)} บาท`:'')
      +`\n• ยอดค้างชำระทั้งหมด ${money(debt)} บาท`
      +(ex.n>0?`\n• รายจ่ายร้าน ${ex.n} รายการ ${money(ex.s)} บาท`+(ex.dr>0?` (จ่ายจากลิ้นชัก ${money(ex.dr)})`:''):'')
      +(rm.n>0?`\n• เงินนำส่ง ${rm.n} รายการ ${money(rm.s)} บาท`:'')
      +(co.ow>0?`\n• เจ้าของเก็บเงินสด ${money(co.ow)} บาท`:'')+(co.bk>0?`\n• นำเงินสดฝากธนาคาร ${money(co.bk)} บาท`:'')
      +(co.adv>0?`\n• พนักงานเบิกล่วงหน้า ${money(co.adv)} บาท`:'')+(co.oth>0?`\n• นำเงินสดออกอื่นๆ ${money(co.oth)} บาท`:'')
      +(req.n>0?`\n• 📝 คำขอเบิกรออนุมัติ ${req.n} รายการ ${money(req.s)} บาท`:'')
      +'\n• ปิดยอด: '+(nStaff===0&&cl.n===0?'ไม่มีการรับเงิน':cl.n===0?'⚠️ ยังไม่ปิดยอด':cl.n<nStaff?`⚠️ ปิดแล้ว ${cl.n}/${nStaff} คน`:'ปิดแล้ว')
      +(cl.n>0&&cl.d<0?` (เงินสดขาด ${money(-cl.d)})`:cl.n>0&&cl.d>0?` (เงินสดเกิน ${money(cl.d)})`:cl.n>0?' (เงินสดตรง)':'')
      +(cl.n>0&&Math.abs(cl.s-recv)>0.004?`\n• ⚠️ ยอดเปลี่ยนหลังปิดยอด (ตอนปิด ${money(cl.s)} / ตอนนี้ ${money(recv)}) กรุณาตรวจในหน้าปิดยอด`:'')
      +(nInsp+q.p+q.f>0?`\n• ตรวจสภาพ ${nInsp} คัน`+(q.p+q.f>0?` (ลงผลในคิว: ผ่าน ${q.p} / ไม่ผ่าน ${q.f})`:''):'')
      +(late>0?`\n• ⚠️ งานขนส่งเกินกำหนด ${late} งาน`:'')}
  const n7=await one(env,'select coalesce(sum(tax_exp between ?1 and ?2),0) tax,coalesce(sum(prb_exp between ?1 and ?2),0) prb from vehicles',addDays(d,1),addDays(d,7));
  return txt+`\n\n📅 อีก 7 วันข้างหน้า: ภาษีหมด ${n7.tax} คัน · พ.ร.บ.หมด ${n7.prb} คัน`}

export async function sendDaily(env,day){const tos=(await getS(env,'line_to')).split(/\s*,\s*/).filter(Boolean);if(!(await getS(env,'line_token'))||!tos.length)fail('ยังไม่ได้ใส่ Channel access token หรือ User ID ในหน้าตั้งค่า');
  const msg=(await dailyText(env,day)).slice(0,4900);for(const u of tos)await lineSend(env,u,msg);return tos.length}

export async function sendReminders(env,day){const d=day||bkkDate();const st=JSON.parse((await one(env,`select value from app_settings where key='main'`)||{}).value||'{}');
  const dd=(Array.isArray(st.line_days)&&st.line_days.length?st.line_days:[30,7]).map(Number);let n=0;
  const rows=(await env.DB.prepare(`select v.id,v.plate,v.province,c.first_name,c.line_user_id,v.tax_exp,v.prb_exp,v.ins_exp from vehicles v join customers c on c.id=v.customer_id where c.line_user_id is not null`).all()).results;
  for(const r of rows)for(const [kind,exp] of [['tax',r.tax_exp],['prb',r.prb_exp],['ins',r.ins_exp]]){if(!exp)continue;const left=Math.round((new Date(exp)-new Date(d))/864e5);if(!dd.includes(left))continue;
    const ins=await env.DB.prepare('insert or ignore into line_reminders (vehicle_id,kind,exp_date,days) values (?,?,?,?)').bind(r.id,kind,exp,left).run();if(!ins.meta.changes)continue;
    const br=await one(env,'select name,phone from branches where id=coalesce((select branch_id from bills where vehicle_id=? order by bill_at desc limit 1),(select min(id) from branches where active=1))',r.id)||{};
    await lineSend(env,r.line_user_id,`เรียนคุณ${r.first_name}\n${kind==='tax'?'ภาษีรถ':kind==='prb'?'พ.ร.บ. ของรถ':'ประกันภัยรถ'} ทะเบียน ${r.plate} ${r.province} จะหมดอายุวันที่ ${be(exp)} (อีก ${left} วัน)\nต่อได้ที่ ตรอ.${br.name||'สยามเซอร์วิส'}${br.phone?' โทร '+br.phone:''} ขอบคุณครับ`);n++}
  return n}

// LINE webhook: /api/line-webhook (ตั้งใน LINE Developers > Messaging API > Webhook URL)
export async function lineWebhook(env,req){const body=await req.text(),secret=await getS(env,'line_channel_secret'),sig=req.headers.get('x-line-signature')||'';
  if(!secret)return new Response('no secret',{status:401});
  const k=await crypto.subtle.importKey('raw',new TextEncoder().encode(secret),{name:'HMAC',hash:'SHA-256'},false,['sign']);
  const mac=btoa(String.fromCharCode(...new Uint8Array(await crypto.subtle.sign('HMAC',k,new TextEncoder().encode(body)))));
  if(mac.length!==sig.length||[...mac].reduce((d,c,i)=>d|c.charCodeAt(0)^sig.charCodeAt(i),0))return new Response('bad signature',{status:401});
  for(const e of JSON.parse(body).events||[]){const u=e.source&&e.source.userId;if(!u||e.source.type!=='user')continue;try{await lineEvent(env,u,e.type,e.message&&e.message.type==='text'?e.message.text:null,e.replyToken||null)}catch(x){console.error('line_event',x)}}
  return new Response('ok')}
async function lineEvent(env,user,type,text,reply){const linked=!!(await one(env,'select 1 from customers where line_user_id=?',user));
  if(type==='unfollow'){await env.DB.prepare('update customers set line_user_id=null,line_linked_at=null where line_user_id=?').bind(user).run();return}
  if(type==='follow')return lineSend(env,user,'ขอบคุณที่เพิ่มเพื่อน ตรอ.สยามเซอร์วิส ครับ\nถ้าต้องการให้ร้านแจ้งเตือนก่อนภาษี / พ.ร.บ. หมดอายุ พิมพ์รหัส 6 หลักที่อยู่ใต้ QR บนใบเสร็จ ส่งมาในแชตนี้ได้เลยครับ',reply);
  if(type!=='message')return;const t=String(text||'');
  if(['ไอดี','id','myid','userid'].includes(t.replace(/\s/g,'').toLowerCase()))return lineSend(env,user,`User ID ของคุณคือ\n${user}\nคัดลอกไปใส่ในแอป › ตั้งค่าระบบ › ช่อง User ID (หลายคนคั่นด้วย ,)`,reply);
  const m=t.match(/(?:^|\D)(\d{6})(?:\D|$)/),code=m&&m[1];
  if(!code){if(!linked)await lineSend(env,user,'พิมพ์รหัส 6 หลักจากใบเสร็จ เพื่อรับการแจ้งเตือนก่อนภาษี / พ.ร.บ. หมดอายุ ครับ',reply);return}
  const r=await env.DB.prepare('update customers set line_user_id=?,line_linked_at=? where line_code=?').bind(user,new Date().toISOString(),code).run();
  if(!r.meta.changes){if(!linked)await lineSend(env,user,`ไม่พบรหัส ${code} กรุณาตรวจรหัสบนใบเสร็จอีกครั้ง หรือโทรสอบถามร้านครับ`,reply);return}
  const cars=(await env.DB.prepare('select group_concat(v.plate||\' \'||v.province,\', \') c from vehicles v join customers c on c.id=v.customer_id where c.line_code=?').bind(code).first('c'));
  await lineSend(env,user,'✅ ผูกบัญชีเรียบร้อย ร้านจะแจ้งเตือนก่อนภาษี / พ.ร.บ. หมดอายุ'+(cars?'\nรถของคุณ: '+cars:'')+'\n(อย่าบล็อกหรือลบเพื่อน ไม่อย่างนั้นจะไม่ได้รับข้อความ)',reply)}

// ---------- SMS ----------
async function sms(env,method,path,form){const k=await getS(env,'sms_api_key'),s=await getS(env,'sms_api_secret');if(!k||!s)fail('ยังไม่ได้ใส่ API Key / Secret ของ SMS ในหน้าตั้งค่า');
  try{const r=await fetch('https://api-v2.thaibulksms.com'+path,{method,headers:{authorization:'Basic '+btoa(k+':'+s),...(form?{'content-type':'application/x-www-form-urlencoded'}:{}),accept:'application/json'},body:form||undefined});
    return{status:r.status,body:await r.text()}}catch(e){return{status:0,body:String(e.message||e)}}}
function smsErr(st,bd){let j=null;try{j=JSON.parse(bd)}catch(_){}const m=j&&(j.error&&(j.error.description||j.error.name)||j.message||j.error)||String(bd).slice(0,200);
  return st===401||st===403?`API Key / Secret ไม่ถูกต้อง (${m||''})`:st===0?'เชื่อมต่อ ThaiBulkSMS ไม่ได้: '+(m||''):(m||'HTTP '+st)}

// ---------- งานตั้งเวลา: /api/cron (เรียกจาก Cloudflare Worker ตั้งเวลา ทุก 10 นาที) ----------
export async function cron(env,req){const key=await getS(env,'cron_key');if(!key||req.headers.get('x-cron-key')!==key)return new Response('forbidden',{status:403});
  const nowB=new Date(Date.now()+7*36e5),hm=nowB.toISOString().slice(11,16),today=nowB.toISOString().slice(0,10),done=[];
  const due=async(name,at)=>{if(hm<at)return false;const last=await getS(env,'last_'+name);if(last===today)return false;
    await env.DB.prepare(`insert into secrets (name,value) values (?,?) on conflict(name) do update set value=excluded.value`).bind('last_'+name,today).run();return true};
  if(await due('backup','02:00')){const {makeBackup}=await import('./rpc_misc.js');await makeBackup(env,'auto');done.push('backup')}
  const dAt=(await getS(env,'sched_daily'))||'20:00';if(await due('daily',dAt)){try{await sendDaily(env,dAt<'12:00'?addDays(today,-1):today);done.push('daily')}catch(e){done.push('daily:'+e.message)}}
  const rAt=(await getS(env,'sched_remind'))||'09:00';if(await due('remind',rAt)){try{done.push('remind:'+await sendReminders(env,today))}catch(e){done.push('remind:'+e.message)}}
  return new Response(JSON.stringify({ok:true,at:hm,done}),{headers:{'content-type':'application/json'}})}

const owner=u=>{if(u.role!=='owner')fail('เฉพาะเจ้าของร้านเท่านั้น',403)};
export const NOTIFY={
  async line_preview(env,u){owner(u);return dailyText(env)},
  async line_test(env,u){owner(u);return sendDaily(env)},
  async sms_credit(env){const {status,body}=await sms(env,'GET','/credit');if(status<200||status>299)return{ok:false,error:smsErr(status,body)};let j;try{j=JSON.parse(body)}catch(_){j=body}return{ok:true,credit:j}},
  async sms_send(env,u,{p_items}){if(!Array.isArray(p_items)||!p_items.length)fail('ไม่มีรายการที่จะส่ง');if(p_items.length>100)fail('ส่งได้ครั้งละไม่เกิน 100 รายการ');
    const st=JSON.parse((await one(env,`select value from app_settings where key='main'`)||{}).value||'{}'),snd=String(st.sms_sender||'').trim(),frc=st.sms_force||'standard';
    if(!snd)fail('ยังไม่ได้ตั้งชื่อผู้ส่ง (Sender name) ในหน้าตั้งค่าระบบ');let ok=0,bad=0,rem=null;const res=[];
    const logRow=(br,it,num,msg,okv,credit,detail)=>env.DB.prepare('insert into sms_sent (branch_id,vehicle_id,kind,msisdn,message,ok,credit,detail,by_name) values (?,?,?,?,?,?,?,?,?)').bind(br,it.vehicle_id||null,it.kind||'other',num,msg,okv?1:0,credit,detail,u.name).run();
    for(const it of p_items){let num=String(it.to||'').replace(/\D/g,'');const msg=String(it.message||'').trim().slice(0,670),br=it.branch_id?+it.branch_id:u.branch;
      if(br!=null&&!canSee(u,br))fail('ไม่มีสิทธิ์ส่ง SMS ในนามสาขานี้');
      num=/^0[689]\d{8}$/.test(num)?'+66'+num.slice(1):/^66[689]\d{8}$/.test(num)?'+'+num:null;
      if(!num||!msg){const e=!msg?'ไม่มีข้อความ':'เบอร์มือถือไม่ถูกต้อง';bad++;await logRow(br,it,it.to||'',msg,false,null,e);res.push({to:it.to,vehicle_id:it.vehicle_id,ok:false,error:e});continue}
      const r=await sms(env,'POST','/sms',new URLSearchParams({msisdn:num,message:msg,sender:snd,force:frc}).toString());let j=null;try{j=JSON.parse(r.body)}catch(_){}
      if(r.status>=200&&r.status<300){ok++;rem=j&&j.remaining_credit!=null?j.remaining_credit:rem;await logRow(br,it,num,msg,true,j&&j.total_use_credit!=null?+j.total_use_credit:null,j&&j.phone_number_list&&j.phone_number_list[0]&&j.phone_number_list[0].message_id||null);res.push({to:it.to,vehicle_id:it.vehicle_id,ok:true})}
      else{const e=smsErr(r.status,r.body);bad++;await logRow(br,it,num,msg,false,null,e);res.push({to:it.to,vehicle_id:it.vehicle_id,ok:false,error:e});if([0,401,403].includes(r.status))break}}
    return{sent:ok,failed:bad,remaining:rem,results:res}},
};
