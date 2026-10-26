// ตรอ.สยามเซอร์วิส : รับข้อความจาก LINE OA แล้วส่งต่อให้ฐานข้อมูล (ผูกลูกค้ากับ LINE)
// วางโค้ดนี้ใน Supabase > Edge Functions > Deploy a new function > Via Editor ตั้งชื่อ line-webhook
// ปิดตัวเลือก "Verify JWT" และใส่ Secret ชื่อ LINE_CHANNEL_SECRET (Channel secret จาก LINE Developers)

const secret = Deno.env.get("LINE_CHANNEL_SECRET") ?? "";
const url = Deno.env.get("SUPABASE_URL") ?? "";
const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";

async function validSignature(body: string, sig: string | null): Promise<boolean> {
  if (!secret || !sig) return false;
  const k = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const mac = new Uint8Array(await crypto.subtle.sign("HMAC", k, new TextEncoder().encode(body)));
  const b64 = btoa(String.fromCharCode(...mac));
  if (b64.length !== sig.length) return false;
  let d = 0;
  for (let i = 0; i < b64.length; i++) d |= b64.charCodeAt(i) ^ sig.charCodeAt(i);
  return d === 0;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("ok");
  const body = await req.text();
  if (!(await validSignature(body, req.headers.get("x-line-signature")))) return new Response("bad signature", { status: 401 });
  const events = (JSON.parse(body).events ?? []) as Array<Record<string, any>>;
  for (const e of events) {
    const user = e.source?.userId;
    if (!user || e.source?.type !== "user") continue;
    const r = await fetch(`${url}/rest/v1/rpc/line_event`, {
      method: "POST",
      headers: { "Content-Type": "application/json", apikey: key, Authorization: `Bearer ${key}` },
      body: JSON.stringify({
        p_user: user,
        p_type: e.type,
        p_text: e.message?.type === "text" ? e.message.text : null,
        p_reply: e.replyToken ?? null,
      }),
    });
    if (!r.ok) console.error("line_event", r.status, await r.text());
  }
  return new Response("ok");
});
