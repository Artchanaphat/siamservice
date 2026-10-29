// Computed-style fingerprint of every element in every audited state (same states as css-audit.js).
//   node tools/css-fp.js index.html out.json [--quick]      then   node tools/css-fp.js --diff a.json b.json
const fs=require('fs');
if(process.argv[2]==='--diff'){const A=JSON.parse(fs.readFileSync(process.argv[3])),B=JSON.parse(fs.readFileSync(process.argv[4]));let bad=0,miss=0;
  for(const k of Object.keys(A)){if(!B[k]){miss++;continue}const a=A[k],b=B[k];if(a.n!==b.n){bad++;if(bad<20)console.log('count',k,a.n,b.n);continue}
    for(let i=0;i<a.h.length;i++)if(a.h[i]!==b.h[i]){bad++;if(bad<40)console.log('diff',k,a.p[i]);break}}
  console.log(`states ${Object.keys(A).length} · missing ${miss} · states with differences ${bad}`);process.exit(bad?1:0)}
const path=require('path');
const {worker,WIDTHS}=require('./css-audit.js');
const file=path.resolve(process.argv[2]),out=process.argv.slice(2).find(a=>a.endsWith('.json'))||'fp.json';
function fp(){const SKIP=new Set(['width','height','inline-size','block-size','perspective-origin','transform-origin']);for(const a of document.getAnimations())try{a.finish()}catch(e){try{a.cancel()}catch(e){}}const out={n:0,h:[],p:[]};const els=document.querySelectorAll('*');
  const hash=s=>{let h=5381;for(let i=0;i<s.length;i++)h=(h*33^s.charCodeAt(i))|0;return h};
  const path=e=>{let s='';for(let x=e,i=0;x&&x.nodeType===1&&i<4;x=x.parentElement,i++)s=x.tagName.toLowerCase()+(x.id?'#'+x.id:'')+(x.classList.length?'.'+[...x.classList].join('.'):'')+(s?'>'+s:'');return s};
  for(const e of els){const c=getComputedStyle(e);let s='';const ks=[];for(let i=0;i<c.length;i++)if(!SKIP.has(c[i]))ks.push(c[i]);ks.sort();for(const k of ks)s+=k+':'+c.getPropertyValue(k)+';'
    for(const ps of ['::before','::after']){const q=getComputedStyle(e,ps);if(q.content&&q.content!=='none')s+=ps+q.cssText.length+q.content+q.color+q.backgroundColor+q.width+q.height}
    out.h.push(hash(s));out.p.push(path(e))}
  out.n=els.length;return out}
(async()=>{const res={},log=[];const W=process.argv.includes('--quick')?[390,900,1300,1920]:WIDTHS;const groups=[[],[],[],[]];W.forEach((w,i)=>groups[i%4].push(w));
  await Promise.all(groups.map(g=>worker(g,null,log,fp,null,(k,r)=>{res[k]=r})));
  fs.writeFileSync(out,JSON.stringify(res));console.log('states',Object.keys(res).length,log.filter(l=>!/^w\d+:/.test(l)).slice(0,10).join('\n'))})();
