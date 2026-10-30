// ข้อมูลตาราง: ช่อง JSON / ช่องจริง-เท็จ / คีย์หลัก / ตารางลูก (ใช้แปลงค่าและต่อข้อมูลแบบ Supabase select('*,payments(*)'))
export const JSONC={bills:['snapshot','items','files_pending'],bill_edits:['before','after'],app_settings:['value'],audit_log:['old_data','new_data'],backup_snapshots:['counts','skipped']};
export const BOOLC={branches:['active'],staff:['active'],payments:['verified','rejected'],insp_queue:['billed'],sms_sent:['ok']};
export const PK={app_settings:'key',staff:'user_id',dlt_jobs:'bill_id',close_acks:'branch_id'};
// ตารางลูก: parent -> child: [fk ในตารางลูก, ช่องในตารางแม่, one=คืนเป็นออบเจ็กต์]
export const REL={
  bills:{payments:['bill_id','id'],bill_edits:['bill_id','id'],dlt_jobs:['bill_id','id',1],bill_requests:['bill_id','id'],insp_queue:['bill_id','id',1],bill_files:['bill_id','id']},
  vehicles:{customers:['id','customer_id',1]},
};
// ช่องที่ไม่ส่งออกทาง API เด็ดขาด
export const HIDE={staff:['pw_hash']};
export const TABLES=['branches','staff','customers','vehicles','bills','payments','bill_edits','dlt_jobs','bill_files','bill_requests','insp_queue','cash_closes','close_acks',
  'expenses','remits','cash_outs','exp_requests','app_settings','news','audit_log','line_reminders','sms_sent','backup_snapshots'];
export const now=()=>new Date().toISOString();
export function decode(t,r){if(!r)return r;for(const c of JSONC[t]||[])if(typeof r[c]==='string'){try{r[c]=JSON.parse(r[c])}catch(_){}}
  for(const c of BOOLC[t]||[])if(c in r&&r[c]!==null)r[c]=!!r[c];for(const c of HIDE[t]||[])delete r[c];return r}
export function encode(t,o){const r={};for(const [k,v] of Object.entries(o)){if((JSONC[t]||[]).includes(k)&&v!==null&&typeof v!=='string')r[k]=JSON.stringify(v);
  else if(typeof v==='boolean')r[k]=v?1:0;else if(v!==null&&typeof v==='object')r[k]=JSON.stringify(v);else r[k]=v===undefined?null:v}return r}
