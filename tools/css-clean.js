// Removes declarations listed as dead by css-audit.js (--json), then drops rules/@media blocks left empty.
//   node tools/css-clean.js index.html audit.json out.html
const fs=require('fs');const {parseFile}=require('./css-parse.js');
const [,,file,auditFile,out]=process.argv;const dead=new Set(JSON.parse(fs.readFileSync(auditFile)).dead);
let {src,rules}=parseFile(file);const cuts=[];
for(const r of rules){const ds=r.decls.filter(d=>!d.bad),kill=ds.filter(d=>dead.has(d.id));if(!kill.length)continue;
  if(kill.length===ds.length&&r.decls.length===ds.length){cuts.push([r.start,r.end]);continue}
  for(const d of kill){let e=d.end;if(src[e]===';')e++;cuts.push([d.start,e])}}
cuts.sort((a,b)=>b[0]-a[0]);let s=src;for(const [a,b] of cuts)s=s.slice(0,a)+s.slice(b);
// collapse empty @media/@supports blocks (repeat for nesting)
for(let k=0;k<4;k++)s=s.replace(/@(media|supports)[^{};]*\{\s*\}/g,'');
fs.writeFileSync(out,s);console.log('removed',cuts.length,'pieces ·',src.length-s.length,'bytes');
