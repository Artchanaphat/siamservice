// Parses the top-level <style> blocks of index.html into rules + declarations with exact file offsets.
// Used by css-audit.js (find declarations that never win) and css-clean.js (remove them).
const fs=require('fs');
function styleBlocks(src){
  const scr=[...src.matchAll(/<script\b[^>]*>[\s\S]*?<\/script>/g)].map(m=>[m.index,m.index+m[0].length]);
  const inScr=i=>scr.some(([a,b])=>a<=i&&i<b);
  return [...src.matchAll(/(<style\b[^>]*>)([\s\S]*?)<\/style>/g)].filter(m=>!inScr(m.index)).map(m=>({start:m.index+m[1].length,text:m[2]}));
}
// skip string or comment starting at i; returns new index or -1
function skip(c,i){const ch=c[i];
  if(ch==='"'||ch==="'"){let j=i+1;while(j<c.length&&c[j]!==ch)j+=c[j]==='\\'?2:1;return j+1}
  if(ch==='/'&&c[i+1]==='*'){const j=c.indexOf('*/',i+2);return j<0?c.length:j+2}
  return -1}
function splitTop(s,sep){const out=[];let d=0,cur='',i=0,st=0;
  while(i<s.length){const k=skip(s,i);if(k>=0){cur+=s.slice(i,k);i=k;continue}
    const ch=s[i];if(ch==='('||ch==='[')d++;else if(ch===')'||ch===']')d--;
    if(ch===sep&&d===0){out.push([cur,st]);cur='';st=i+1}else cur+=ch;i++}
  out.push([cur,st]);return out}
function parseDecls(body,base){const out=[];
  for(const [raw,off] of splitTop(body,';')){
    const lead=raw.length-raw.trimStart().length,t=raw.trim();if(!t)continue;
    const noC=t.replace(/\/\*[\s\S]*?\*\//g,'').trim();if(!noC)continue;
    const ci=noC.indexOf(':');if(ci<0){out.push({bad:true,start:base+off+lead,end:base+off+raw.length,text:t});continue}
    let prop=noC.slice(0,ci).trim().toLowerCase(),val=noC.slice(ci+1).trim(),imp=false;
    const m=val.match(/!\s*important\s*$/i);if(m){imp=true;val=val.slice(0,m.index).trim()}
    // end includes the following ';' when present
    let end=base+off+raw.length;
    out.push({prop,val,imp,start:base+off+lead,end,text:t})}
  return out}
// returns flat list of rules {sel, media:[preludes], decls, start,end, bodyStart, bodyEnd, sheet, order}
function parseCSS(c,base,sheet,media,rules,raws){let i=0,buf='',bufStart=0;
  while(i<c.length){const k=skip(c,i);if(k>=0){if(c[i]==='/'){i=k;continue}if(!buf.trim())bufStart=i;buf+=c.slice(i,k);i=k;continue}
    const ch=c[i];
    if(ch==='{'){const pre=buf.trim();const preStart=bufStart;buf='';
      let d=1,j=i+1;while(j<c.length&&d){const k2=skip(c,j);if(k2>=0){j=k2;continue}if(c[j]==='{')d++;else if(c[j]==='}')d--;j++}
      const body=c.slice(i+1,j-1);
      if(/^@(media|supports)\b/i.test(pre))parseCSS(body,base+i+1,sheet,[...media,pre],rules,raws);
      else if(pre.startsWith('@'))raws.push({pre,media,start:base+preStart,end:base+j});
      else rules.push({sel:pre,media,sheet,start:base+preStart,end:base+j,bodyStart:base+i+1,bodyEnd:base+j-1,decls:parseDecls(body,base+i+1)});
      i=j;bufStart=i;continue}
    if(ch===';'&&buf.trim().startsWith('@')){buf='';i++;bufStart=i;continue}
    if(!buf.trim())bufStart=i;buf+=ch;i++}
  return rules}
function parseFile(file){const src=fs.readFileSync(file,'utf8');const rules=[],raws=[];
  styleBlocks(src).forEach((b,si)=>parseCSS(b.text,b.start,si,[],rules,raws));
  rules.forEach((r,i)=>{r.order=i;r.decls.forEach((d,j)=>{d.id=i+':'+j})});
  return {src,rules,raws}}
module.exports={parseFile,splitTop};
if(require.main===module){const {src,rules}=parseFile(process.argv[2]||'index.html');
  let n=0;rules.forEach(r=>n+=r.decls.length);console.log(rules.length,'rules',n,'decls');
  // sanity: every decl text appears at its offset
  let bad=0;rules.forEach(r=>r.decls.forEach(d=>{if(!d.bad&&src.slice(d.start,d.start+d.text.length)!==d.text)bad++}));console.log('offset mismatches',bad);
  console.log(rules.slice(0,2).map(r=>[r.sel,r.media,src.slice(r.start,r.start+60)]))}
