// Supabase Edge Function: voy-push
// 새 글이 올라오면(DB 트리거가 호출) 알림을 켠 모든 회원에게 웹 푸시를 보냅니다.
// 필요한 Secrets: VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY, PUSH_SECRET  (SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY는 자동 제공)
import webpush from "npm:web-push@3.6.7";
import { createClient } from "npm:@supabase/supabase-js@2";

const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
webpush.setVapidDetails("mailto:voy@yuhan.co.kr", Deno.env.get("VAPID_PUBLIC_KEY")!, Deno.env.get("VAPID_PRIVATE_KEY")!);

Deno.serve(async (req) => {
  if (req.headers.get("x-push-secret") !== Deno.env.get("PUSH_SECRET")) return new Response("forbidden", { status: 403 });
  const { post_id } = await req.json().catch(() => ({}));
  const { data: post } = await sb.from("posts").select("id,title,board_id,user_id").eq("id", post_id).maybeSingle();
  if (!post) return new Response("post not found", { status: 404 });
  const { data: board } = await sb.from("boards").select("name").eq("id", post.board_id).maybeSingle();

  let q = sb.from("push_subscriptions").select("endpoint,p256dh,auth,user_id");
  if (post.user_id) q = q.neq("user_id", post.user_id);          // 글쓴이 본인에게는 보내지 않음
  const { data: subs } = await q;

  const payload = JSON.stringify({
    title: "🔔 VOY™ 새 글이 올라왔어요",
    body: `[${board?.name ?? "게시판"}] ${post.title}`,
    url: `./#/post/${post.id}`,
  });
  let sent = 0, removed = 0;
  await Promise.all((subs ?? []).map(async (s) => {
    try {
      await webpush.sendNotification({ endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } }, payload, { TTL: 60 * 60 * 24 });
      sent++;
    } catch (e) {
      const code = (e as { statusCode?: number }).statusCode;
      if (code === 404 || code === 410) { await sb.from("push_subscriptions").delete().eq("endpoint", s.endpoint); removed++; }
    }
  }));
  return Response.json({ sent, removed });
});
