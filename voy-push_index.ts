// Supabase Edge Function: voy-push
// ① kind=direct: 지정한 회원에게만 (Voice 심사 요청)  ② 새 글이 올라오면(DB 트리거가 호출) 알림을 켠 회원 중 그 글의 커뮤니티(ETC/OTC)를 볼 수 있는 사람에게만 웹 푸시를 보냅니다.
// 필요한 Secrets: VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY, PUSH_SECRET  (SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY는 자동 제공)
import webpush from "npm:web-push@3.6.7";
import { createClient } from "npm:@supabase/supabase-js@2";

const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
webpush.setVapidDetails("mailto:voy@yuhan.co.kr", Deno.env.get("VAPID_PUBLIC_KEY")!, Deno.env.get("VAPID_PRIVATE_KEY")!);

Deno.serve(async (req) => {
  if (req.headers.get("x-push-secret") !== Deno.env.get("PUSH_SECRET")) return new Response("forbidden", { status: 403 });
  const msg = await req.json().catch(() => ({}));
  // ① 특정 회원에게만 (Voice 심사 요청 등)
  if (msg.kind === "direct") {
    const ids: string[] = Array.isArray(msg.user_ids) ? msg.user_ids : [];
    if (!ids.length) return Response.json({ sent: 0, removed: 0 });
    const { data: subs } = await sb.from("push_subscriptions").select("endpoint,p256dh,auth,user_id").in("user_id", ids);
    return Response.json(await sendAll(subs ?? [], JSON.stringify({ title: msg.title ?? "VOY™", body: msg.body ?? "", url: msg.url ?? "./", test: !!msg.test })));
  }
  // ② 새 글 알림
  const { post_id } = msg;
  const { data: post } = await sb.from("posts").select("id,title,board_id,user_id,org").eq("id", post_id).maybeSingle();
  if (!post) return new Response("post not found", { status: 404 });
  const { data: board } = await sb.from("boards").select("name").eq("id", post.board_id).maybeSingle();

  let q = sb.from("push_subscriptions").select("endpoint,p256dh,auth,user_id");
  if (post.user_id) q = q.neq("user_id", post.user_id);          // 글쓴이 본인에게는 보내지 않음
  const { data: all } = await q;
  // ETC 글은 ETC를 볼 수 있는 사람에게만, OTC 글은 OTC를 볼 수 있는 사람에게만 (admin·통합 회원은 둘 다)
  const org = post.org ?? "etc";
  const ids = [...new Set((all ?? []).map((s) => s.user_id).filter(Boolean))];
  const { data: profs } = ids.length ? await sb.from("profiles").select("id,role,org,cross_org").in("id", ids) : { data: [] };
  const sees = new Map((profs ?? []).map((p) => [p.id, p.role === "super" || p.role === "admin" || p.cross_org ? ["etc", "otc"]
    : p.role === "e_admin" ? ["etc"] : p.role === "o_admin" ? ["otc"] : [p.org ?? "etc"]]));
  const subs = (all ?? []).filter((s) => (sees.get(s.user_id) ?? []).includes(org));

  const payload = JSON.stringify({
    title: "🔔 VOY™ 새 글이 올라왔어요",
    body: `[${board?.name ?? "게시판"}] ${post.title}`,
    url: `./#/post/${post.id}`,
  });
  return Response.json(await sendAll(subs, payload));
});

async function sendAll(subs: { endpoint: string; p256dh: string; auth: string }[], payload: string) {
  let sent = 0, removed = 0;
  const failed: { code: number | null; msg: string; host: string }[] = [];
  await Promise.all(subs.map(async (s) => {
    try {
      await webpush.sendNotification({ endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } }, payload, { TTL: 60 * 60 * 24, urgency: "high" });
      sent++;
    } catch (e) {
      const er = e as { statusCode?: number; body?: string; message?: string };
      const code = er.statusCode ?? null;
      if (code === 404 || code === 410) { await sb.from("push_subscriptions").delete().eq("endpoint", s.endpoint); removed++; }
      else failed.push({ code, msg: String(er.body || er.message || "").slice(0, 160), host: (() => { try { return new URL(s.endpoint).host; } catch { return ""; } })() });
    }
  }));
  return { targets: subs.length, sent, removed, failed };   // 발송 결과 (관리자 콘솔·알림 도우미에서 확인)
}
