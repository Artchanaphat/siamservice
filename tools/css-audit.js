// CSS audit: visits every page/dialog of index.html (demo mode) at many screen widths and in print,
// computes the cascade itself, and reports declarations that match elements but never take effect
// (always overridden by another rule). Those are the "layered overrides" that make new styles silently fail.
//   node tools/css-audit.js [index.html] [--json out.json] [--workers 4]
// Exit code 1 when overridden declarations exist (use as a guard before deploy).
const {chromium,devices}=require('playwright');const path=require('path');const fs=require('fs');
const {parseFile}=require('./css-parse.js');
const args=process.argv.slice(2);const file=path.resolve(args.find(a=>a.endsWith('.html'))||'index.html');
const jsonOut=args.includes('--json')?args[args.indexOf('--json')+1]:null;
const WORKERS=args.includes('--workers')?+args[args.indexOf('--workers')+1]:4;
const WIDTHS=args.includes('--quick')?[390,900,1300,1920]:[360,390,500,560,610,645,660,690,710,740,780,870,900,910,940,980,1010,1050,1090,1150,1220,1300,1445,1500,1650,1920];

const {rules}=parseFile(file);
const STATE=/:(hover|focus|active|visited|target|checked|indeterminate|placeholder-shown|autofill|-webkit-autofill|invalid|valid|user-invalid|disabled|enabled|default|read-only|read-write|required|optional|fullscreen|modal|popover-open|open)\b|::?(before|after|placeholder|selection|marker|first-line|first-letter|backdrop|file-selector-button|-webkit-|-moz-)/i;
const model=rules.map(r=>({o:r.order,sel:r.sel,media:r.media,prot:STATE.test(r.sel),decls:r.decls.map(d=>d.bad?null:{id:d.id,prop:d.prop,val:d.val,imp:d.imp})}));

// runs inside the page
function analyze(model){
  const mq={};const okMedia=list=>list.every(p=>{if(mq[p]!=null)return mq[p];const m=p.match(/^@(media|supports)\s*([\s\S]*)$/i);let v=true;
    try{v=m[1].toLowerCase()==='media'?matchMedia(m[2]).matches:CSS.supports(m[2])}catch(e){v=true}return mq[p]=v});
  const box=document.createElement('div').style,lhC={};
  const longhands=(p,v)=>{const k=p+'\u0000'+v;if(lhC[k])return lhC[k];box.cssText='';box.setProperty(p,v);const l=[...box];return lhC[k]=l};
  const splitTop=s=>{const o=[];let d=0,c='',q=null;for(const ch of s){if(q){c+=ch;if(ch===q)q=null;continue}if(ch==='"'||ch==="'")q=ch;else if(ch==='('||ch==='[')d++;else if(ch===')'||ch===']')d--;if(ch===','&&!d){o.push(c.trim());c=''}else c+=ch}o.push(c.trim());return o};
  const spec=s=>{let a=0,b=0,c=0,i=0;const n=s.length;let start=true;
    const ident=()=>{let j=i;while(j<n&&/[\w\-\\\u0080-￿]/.test(s[j]))j+=s[j]==='\\'?2:1;return j};
    while(i<n){const ch=s[i];
      if(ch===' '||ch==='>'||ch==='+'||ch==='~'||ch==='\n'||ch==='\t'){start=true;i++;continue}
      if(ch==='#'){a++;i=ident.call(null,i++)||i;i=(()=>{let j=i;while(j<n&&/[\w\-\\]/.test(s[j]))j++;return j})();start=false;continue}
      if(ch==='.'){b++;i++;while(i<n&&/[\w\-\\]/.test(s[i]))i++;start=false;continue}
      if(ch==='['){b++;let d=1;i++;while(i<n&&d){if(s[i]==='[')d++;else if(s[i]===']')d--;i++}start=false;continue}
      if(ch===':'){let el=s[i+1]===':';i+=el?2:1;let j=i;while(j<n&&/[\w\-]/.test(s[j]))j++;const name=s.slice(i,j).toLowerCase();i=j;let arg=null;
        if(s[i]==='('){let d=1,k=i+1;while(k<n&&d){if(s[k]==='(')d++;else if(s[k]===')')d--;k++}arg=s.slice(i+1,k-1);i=k}
        if(el)c++;else if(name==='where'){}else if(['is','not','has','matches'].includes(name)&&arg){let m=[0,0,0];for(const x of splitTop(arg)){const q=spec(x);if(q[0]>m[0]||q[0]===m[0]&&(q[1]>m[1]||q[1]===m[1]&&q[2]>m[2]))m=q}a+=m[0];b+=m[1];c+=m[2]}else b++;
        start=false;continue}
      if(ch==='*'){i++;start=false;continue}
      if(/[A-Za-z]/.test(ch)){c++;while(i<n&&/[\w\-]/.test(s[i]))i++;start=false;continue}
      i++}
    return [a,b,c]};
  const cmp=(x,y)=>{for(let i=0;i<x.length;i++){if(x[i]!==y[i])return x[i]>y[i]?1:-1}return 0};
  const best=new Map();// el -> Map(longhand -> [key, declId])
  const matched=new Set(),invalid=new Set();
  const all=document.querySelectorAll('*');
  for(const r of model){if(r.prot||!okMedia(r.media))continue;let els;try{els=document.querySelectorAll(r.sel)}catch(e){continue}if(!els.length)continue;
    const parts=splitTop(r.sel).map(x=>[x,spec(x)]);
    for(const el of els){let sp=[0,0,0];for(const [x,q] of parts){let ok=false;try{ok=parts.length===1||el.matches(x)}catch(e){}if(ok&&cmp(q,sp)>0)sp=q}
      let m=best.get(el);if(!m)best.set(el,m=new Map());
      r.decls.forEach((d,j)=>{if(!d)return;matched.add(d.id);if(d.prop.startsWith('--'))return;const lh=longhands(d.prop,d.val);if(!lh.length){invalid.add(d.id);return}
        const key=[d.imp?1:0,0,...sp,r.o,j];for(const l of lh){const cur=m.get(l);if(!cur||cmp(key,cur[0])>0)m.set(l,[key,d.id])}})}}
  // inline style attributes beat rules (non-important), important inline beats everything
  for(const [el,m] of best){if(!el.getAttribute||!el.getAttribute('style'))continue;const st=el.style;
    for(let i=0;i<st.length;i++){const l=st[i],imp=st.getPropertyPriority(l)==='important',cur=m.get(l);if(cur&&(imp||!cur[0][0]))m.set(l,[[9],'inline'])}}
  const won=new Set();for(const m of best.values())for(const [,v] of m)won.add(v[1]);
  return {matched:[...matched],won:[...won],invalid:[...invalid]}}

async function login(p,role='admin'){await p.goto('file://'+file);await p.waitForTimeout(500);await p.click(`[data-demo="${role}"]`);await p.waitForTimeout(500)}
async function worker(widths,acc,log,pageFn=analyze,arg=model,sink=null){const b=await chromium.launch();
  for(const w of widths){const opt=w<=400?{...devices['iPhone 13'],viewport:{width:w,height:800}}:{viewport:{width:w,height:900}};
    const ctx=await b.newContext({...opt,reducedMotion:'reduce'});const p=await ctx.newPage();p.on('dialog',d=>d.dismiss().catch(()=>{}));
    await p.clock.setFixedTime(new Date('2026-10-29T10:30:00+07:00'));
    let n=0,MED='screen';const take=async tag=>{tag=(MED==='print'?'P:':'')+tag;try{await p.mouse.move(0,0);await p.waitForTimeout(150);const r=await p.evaluate(pageFn,arg);if(sink)sink(w+'|'+tag,r);else{r.matched.forEach(x=>acc.matched.add(x));r.won.forEach(x=>acc.won.add(x));(r.invalid||[]).forEach(x=>acc.invalid.add(x));if(acc.lost){const wn=new Set(r.won);for(const x of r.matched)if(!wn.has(x)){const l=acc.lost.get(x);if(l)l.push(w+' '+tag);else acc.lost.set(x,[w+' '+tag])}}}n++}catch(e){log.push(w+' '+tag+': '+e.message.slice(0,120))}};
    const step=async(tag,fn)=>{try{await fn();await take(tag)}catch(e){log.push(w+' '+tag+': '+e.message.slice(0,120))}};
    const fresh=async(role)=>{await login(p,role)};
    await p.goto('file://'+file);await p.waitForTimeout(500);await take('login');
    for(const media of [390,710,780,900,1050].includes(w)?['screen','print']:['screen']){await p.emulateMedia({media});MED=media;
      await fresh();
      const pages=await p.evaluate(()=>Object.keys(R).filter(k=>!['bill','edit','docsDay'].includes(k)));
      for(const g of pages)await step(g,()=>p.evaluate(g=>go(g),g));
      for(const [pg,sel] of [['settings','[data-stn]'],['track','[data-tf]'],['cust','[data-ct]'],['cust','[data-so]'],['dlt','.dj-kpis [data-f]'],['home','[data-ht]'],['dlt','.dj-alert[data-f]']]){
        await p.evaluate(g=>go(g),pg);const k=await p.$$eval(sel,a=>a.length).catch(()=>0);
        for(let i=0;i<k;i++)await step(pg+sel+i,async()=>{await p.evaluate(g=>go(g),pg);await p.waitForTimeout(80);const els=await p.$$(sel);if(els[i])await els[i].click({timeout:1500}).catch(()=>{})})}
      // bills
      const bills=await p.evaluate(()=>{const a=[...intake,...oldBills].filter(Boolean);const f=fn=>{const x=a.find(fn);return x?x.id:null};return [...new Set([f(b=>b.amt-b.paid>0.004),f(b=>b.amt-b.paid<=0.004&&!b.void),f(b=>b.void),f(b=>(b.reqs||[]).length),f(b=>dltOf&&dltKind(b))].filter(x=>x!=null))]});
      for(const id of bills)await step('bill'+id,()=>p.evaluate(id=>showBill(id),id));
      await step('edit',async()=>{await p.evaluate(id=>showBill(id),bills[0]);const e=await p.$('[data-edit],#b-edit,.bs-edit');if(e)await e.click({timeout:1500}).catch(()=>{})});
      await step('docsDay',()=>p.evaluate(()=>{psDay=new Date(TODAY);go('docsDay')}));
      // dialogs (fresh page each)
      const dlg=[
        ['car',()=>p.evaluate(()=>openCar(cars[0].id))],
        ['pay',()=>p.evaluate(()=>{const b=intake.find(b=>b.amt-b.paid>0.004)||intake[0];payDlg(b)})],
        ['rcA4',async()=>{await p.evaluate(()=>receiptDlg(intake[0],'แบบ A4'));await p.waitForTimeout(500)}],
        ['rcSlip',async()=>{await p.evaluate(()=>receiptDlg(intake[0],'แบบม้วน'));await p.waitForTimeout(500)}],
        ['dltDlg',()=>p.evaluate(()=>dltDlg([dltJobs()[0]]))],
        ['dltDlgMany',()=>p.evaluate(()=>dltDlg(dltJobs().slice(0,2)))],
        ['confirm',()=>p.evaluate(()=>{uiConfirm('ทดสอบ')})],
        ['prompt',()=>p.evaluate(()=>{uiPrompt('ทดสอบ','x')})],
        ['ask',()=>p.evaluate(()=>{askDlg({title:'ทดสอบ',sub:'x',label:'y',chips:['a','b'],tone:'bad'})})],
        ['toast',()=>p.evaluate(()=>toast('ทดสอบ'))],
        ['tq',async()=>{await p.evaluate(()=>{const t=document.querySelector('#tq');t.value=cars[0].plate.slice(0,2);t.dispatchEvent(new Event('input',{bubbles:true}));t.focus()});await p.waitForTimeout(300)}],
        ['tqNone',async()=>{await p.evaluate(()=>{const t=document.querySelector('#tq');t.value='zzzz';t.dispatchEvent(new Event('input',{bubbles:true}))});await p.waitForTimeout(300)}],
        ['qoff',()=>p.evaluate(()=>{SET.queue_off=[curBrId()];go('home')})],
        ['qoffTrack',()=>p.evaluate(()=>{SET.queue_off=[curBrId()];go('track')})],
        ['menu',async()=>{const m=await p.$('#side-tog,.side-tog,[aria-label="เมนู"]');if(m)await m.click({timeout:1500}).catch(()=>{})}],
        ['userMenu',async()=>{const m=await p.$('.um,.user-btn,#um-btn,[aria-haspopup]');if(m)await m.click({timeout:1500}).catch(()=>{})}],
        ['bell',async()=>{const m=await p.$('.bell,#bell,[aria-label*="แจ้งเตือน"]');if(m)await m.click({timeout:1500}).catch(()=>{})}],
        ['selpop',async()=>{await p.evaluate(()=>go('add'));const s=await p.$('#view select');if(s)await s.click({timeout:1500}).catch(()=>{})}],
        ['carThenRc',async()=>{await p.evaluate(()=>openCar(cars[0].id));await p.waitForTimeout(200);await p.evaluate(()=>{document.querySelector('#dlg').hidden=true});await p.evaluate(()=>receiptDlg(intake[0],'แบบ A4'));await p.waitForTimeout(500)}],
        ['addFilled',async()=>{await p.evaluate(()=>go('add'));const c=await p.$$('#view input[type=checkbox]');for(const x of c.slice(0,4))await x.check({timeout:800}).catch(()=>{})}],
      ];
      for(const [t,fn] of dlg){await fresh();await step(t,fn)}
      // staff role
      await fresh('demo1');for(const g of ['home','add','track','close','cust','dlt','income','settings'])await step('staff-'+g,()=>p.evaluate(g=>go(g),g));
    }
    // print receipts
    if(w===900){await p.emulateMedia({media:'print'});MED='print';for(const k of ['แบบ A4','แบบม้วน']){await fresh();await step('print'+k,async()=>{await p.evaluate(k=>receiptDlg(intake[0],k),k);await p.waitForTimeout(500)})}await p.emulateMedia({media:'screen'});MED='screen'}
    await p.emulateMedia({media:'screen'});log.push(`w${w}: ${n} states`);await ctx.close()}
  await b.close()}

module.exports={worker,WIDTHS,model,rules};
if(require.main===module)(async()=>{const acc={matched:new Set(),won:new Set(),invalid:new Set(),lost:args.includes('--since')?new Map():null},log=[];
  const groups=Array.from({length:WORKERS},()=>[]);WIDTHS.forEach((w,i)=>groups[i%WORKERS].push(w));
  await Promise.all(groups.map(g=>worker(g,acc,log)));
  const byId={};rules.forEach(r=>r.decls.forEach(d=>byId[d.id]={r,d}));
  // keep custom properties, vendor-prefixed declarations and values Chromium cannot parse (other browsers may need them)
  const vendor=d=>/^-(webkit|moz|ms|o)-/.test(d.prop)||/-(webkit|moz|ms)-/.test(d.val);
  const dead=[...acc.matched].filter(id=>!acc.won.has(id)&&!acc.invalid.has(id)&&byId[id]&&!byId[id].d.prop.startsWith('--')&&!vendor(byId[id].d));
  if(jsonOut)fs.writeFileSync(jsonOut,JSON.stringify({dead,matched:[...acc.matched],won:[...acc.won],log},null,0));
  console.log(log.filter(l=>!/^w\d+:/.test(l)).slice(0,30).join('\n'));
  console.log(log.filter(l=>/^w\d+:/.test(l)).join(' | '));
  console.log(`rules ${rules.length} · declarations matched ${acc.matched.size} · overridden everywhere ${dead.length}`);
  // --since <git ref>: guard mode. Only declarations added since that ref are judged:
  // a new declaration that matches elements but never takes effect means an older rule overrides it.
  if(args.includes('--since')){const ref=args[args.indexOf('--since')+1];const old=require('child_process').execSync(`git show ${ref}:index.html`,{cwd:path.dirname(file),maxBuffer:1<<26}).toString();
    const tmp=path.join(require('os').tmpdir(),'css-audit-old.html');fs.writeFileSync(tmp,old);const key=(r,d)=>r.media.join('|')+'\u0000'+r.sel+'\u0000'+d.text;
    const oldKeys=new Set();parseFile(tmp).rules.forEach(r=>r.decls.forEach(d=>oldKeys.add(key(r,d))));
    const fresh=[];rules.forEach(r=>r.decls.forEach(d=>{if(!d.bad&&!oldKeys.has(key(r,d)))fresh.push(d.id)}));const deadSet=new Set(dead);
    const bad=fresh.filter(id=>acc.lost.has(id)&&!acc.invalid.has(id)&&!byId[id].d.prop.startsWith('--')&&!vendor(byId[id].d)),unmatched=fresh.filter(id=>!acc.matched.has(id));
    console.log(`\nnew declarations since ${ref}: ${fresh.length} · overridden in some screens/states: ${bad.length} · matched nothing in audited states: ${unmatched.length}`);
    bad.forEach(id=>{const {r,d}=byId[id],l=acc.lost.get(id);console.log(`  ✗ ${r.media.join(' ')} ${r.sel.slice(0,70)} { ${d.text} } — no effect in ${l.length} states, e.g. ${l.slice(0,3).join(', ')}`)});
    unmatched.slice(0,20).forEach(id=>{const {r,d}=byId[id];console.log(`  ? ${r.media.join(' ')} ${r.sel.slice(0,70)} { ${d.text} }`)});
    process.exit(bad.length?1:0)}
  dead.slice(0,15).forEach(id=>{const {r,d}=byId[id];console.log(`  ${r.sel.slice(0,60)} { ${d.text.slice(0,60)} }`)});
  process.exit(dead.length?1:0)})();
