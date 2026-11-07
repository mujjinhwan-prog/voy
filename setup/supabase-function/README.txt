VOY™ 새 글 알림(웹 푸시) 연결 방법 — 5분
=========================================
※ keys.txt 의 VAPID_PRIVATE_KEY / PUSH_SECRET 은 비밀값입니다. GitHub에 올리지 마세요.
   (VAPID_PUBLIC_KEY 는 이미 voy_index.html 에 들어가 있습니다)

1) Supabase 대시보드 → Edge Functions → [Deploy a new function] → [Via Editor]
   - 함수 이름: voy-push
   - index.ts 내용을 통째로 붙여넣고 Deploy
   - 함수 Settings(또는 Details)에서 "Verify JWT" / "Enforce JWT verification" 을 OFF
     (DB가 비밀키 헤더로 호출하므로 JWT 검사가 필요 없습니다)

2) Edge Functions → Secrets (Manage secrets) 에 3개 추가 (keys.txt 값 복사)
   VAPID_PUBLIC_KEY   = keys.txt 값
   VAPID_PRIVATE_KEY  = keys.txt 값
   PUSH_SECRET        = keys.txt 값

3) SQL Editor 에서 아래 2줄 실행 (<프로젝트ID>, <PUSH_SECRET> 바꿔서)
   insert into public.app_secrets values ('push_url', 'https://<프로젝트ID>.supabase.co/functions/v1/voy-push') on conflict (key) do update set value = excluded.value;
   insert into public.app_secrets values ('push_secret', '<PUSH_SECRET>') on conflict (key) do update set value = excluded.value;

4) 확인: 회원이 [내 정보 → 새 글 알림] 을 켠 뒤, 다른 계정으로 글을 쓰면
   휴대폰·PC에 🔔 알림이 오고 설치한 VOY™ 아이콘에 숫자 배지가 붙습니다.
   (Edge Functions → voy-push → Logs 에서 sent 숫자로 발송 수 확인 가능)
