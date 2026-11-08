-- =====================================================================
--  Voice of YUHAN — Supabase 스키마 2/2 (1/2를 먼저 실행한 뒤 이 파일을 실행하세요)
-- =====================================================================
-- ---------- 가입 코드 ----------
create or replace function public.signup_code_required() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select value #>> '{}' from public.settings where key = 'signup_code'), '') <> ''
$$;

create or replace function public.check_signup_code(code text) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select value #>> '{}' from public.settings where key = 'signup_code'), '') in ('', coalesce(code,''))
$$;

-- ---------- 계정 생성 (내부 전용 — 외부 호출 차단) ----------
create or replace function public._create_auth_user(p_email text, p_password text, p_meta jsonb) returns uuid
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := gen_random_uuid();
begin
  perform set_config('voy.trusted', '1', true);
  insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
                          raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                          confirmation_token, email_change, email_change_token_new, recovery_token)
  values ('00000000-0000-0000-0000-000000000000', uid, 'authenticated', 'authenticated', lower(p_email),
          extensions.crypt(p_password, extensions.gen_salt('bf')), now(),
          '{"provider":"email","providers":["email"]}'::jsonb, coalesce(p_meta, '{}'::jsonb), now(), now(), '', '', '', '');
  update auth.users set email_change_token_current = '', phone_change = '', phone_change_token = '', reauthentication_token = '' where id = uid;
  insert into auth.identities (id, user_id, provider_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
  values (gen_random_uuid(), uid, uid::text,
          jsonb_build_object('sub', uid::text, 'email', lower(p_email), 'email_verified', true), 'email', now(), now(), now());
  perform set_config('voy.trusted', '0', true);
  return uid;
end $$;
revoke all on function public._create_auth_user(text, text, jsonb) from public, anon, authenticated;

-- ---------- 회원 일괄 등록/수정 (엑셀 업로드) ----------
-- rows: [{email, real_name, emp_no, category, org_branch, work_branch, sales_office, position, duty, password?, reset_pw?}]
create or replace function public.admin_upsert_members(rows jsonb) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare r jsonb; em text; uid uuid; res jsonb := '[]'::jsonb; pw text; meta jsonb; prole text; nk text; nmsg text;
begin
  if not public.has_perm('members') then raise exception '회원 관리 권한이 없습니다'; end if;
  for r in select * from jsonb_array_elements(rows) loop
    em := lower(btrim(coalesce(r->>'email', '')));
    begin
      if em !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then
        res := res || jsonb_build_object('email', em, 'status', 'error', 'msg', '이메일 형식 오류'); continue;
      end if;
      select id into uid from auth.users where email = em;
      -- 닉네임(선택): 다른 곳에서 쓰던 닉네임을 그대로 이어서 쓰도록. 2~12자, 다른 회원과 겹치면 자동 생성으로 대체
      nk := nullif(btrim(coalesce(r->>'nickname', '')), ''); nmsg := null;
      if nk is not null and char_length(nk) not between 2 and 12 then nmsg := '닉네임 2~12자 아님 → ' || case when uid is null then '자동 생성' else '기존 닉네임 유지' end; nk := null; end if;
      if nk is not null and exists (select 1 from public.profiles where nickname = nk and id is distinct from uid) then
        nmsg := '닉네임 [' || nk || '] 이미 사용 중 → ' || case when uid is null then '자동 생성' else '기존 닉네임 유지' end; nk := null; end if;
      if uid is null then
        pw := coalesce(nullif(btrim(r->>'password'), ''), nullif(btrim(r->>'emp_no'), ''));
        if pw is null or char_length(pw) < 4 then
          res := res || jsonb_build_object('email', em, 'status', 'error', 'msg', '초기 비밀번호 또는 사번이 필요합니다'); continue;
        end if;
        meta := (r - 'password' - 'reset_pw' - 'nickname') || jsonb_build_object('login_id', em, 'role', 'user', 'must_change_pw', true)
                || case when nk is not null then jsonb_build_object('nickname', nk) else '{}'::jsonb end;
        perform public._create_auth_user(em, pw, meta);
        res := res || jsonb_build_object('email', em, 'status', 'created', 'msg', nmsg);
      else
        select role into prole from public.profiles where id = uid;
        if prole in ('admin','super') then
          res := res || jsonb_build_object('email', em, 'status', 'error', 'msg', '관리자 계정은 [관리자 계정] 메뉴에서 수정하세요'); continue;
        end if;
        update public.profiles set
          real_name    = coalesce(nullif(r->>'real_name', ''), real_name),
          emp_no       = coalesce(nullif(r->>'emp_no', ''), emp_no),
          category     = coalesce(nullif(r->>'category', ''), category),
          org_branch   = coalesce(nullif(r->>'org_branch', ''), org_branch),
          work_branch  = coalesce(nullif(r->>'work_branch', ''), work_branch),
          sales_office = coalesce(nullif(r->>'sales_office', ''), sales_office),
          position     = coalesce(nullif(r->>'position', ''), position),
          duty         = coalesce(nullif(r->>'duty', ''), duty)
        where id = uid;
        if nk is not null then update public.profiles set nickname = nk where id = uid and nickname is distinct from nk; end if;
        if coalesce((r->>'reset_pw')::boolean, false) then
          pw := coalesce(nullif(btrim(r->>'password'), ''), (select emp_no from public.profiles where id = uid));
          update auth.users set encrypted_password = extensions.crypt(pw, extensions.gen_salt('bf')), updated_at = now() where id = uid;
          update public.profiles set must_change_pw = true where id = uid;
        end if;
        res := res || jsonb_build_object('email', em, 'status', 'updated', 'msg', nmsg);
      end if;
    exception when others then
      res := res || jsonb_build_object('email', em, 'status', 'error', 'msg', sqlerrm);
    end;
  end loop;
  return res;
end $$;

-- ---------- 관리자 계정 추가 (최고관리자 전용) ----------
create or replace function public.admin_create_admin(p_login text, p_password text, p_details jsonb, p_perms jsonb) returns uuid
language plpgsql security definer set search_path = public, extensions as $$
declare lid text := lower(btrim(p_login));
begin
  if not public.is_super() then raise exception '최고관리자만 관리자 계정을 추가할 수 있습니다'; end if;
  if lid !~ '^[a-z0-9._-]{3,20}$' then raise exception '아이디는 영문 소문자·숫자·._- 3~20자'; end if;
  if char_length(coalesce(p_password, '')) < 6 then raise exception '비밀번호는 6자 이상이어야 합니다'; end if;
  if exists(select 1 from auth.users where email = lid || '@voy-community.app') then raise exception '이미 있는 아이디입니다'; end if;
  return public._create_auth_user(lid || '@voy-community.app', p_password,
    coalesce(p_details, '{}'::jsonb) || jsonb_build_object('login_id', lid, 'role', 'admin', 'perms', coalesce(p_perms, '[]'::jsonb)));
end $$;

-- ---------- 비밀번호 초기화 / 계정 삭제 ----------
create or replace function public.admin_reset_password(target uuid, new_password text) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare trole text;
begin
  select role into trole from public.profiles where id = target;
  if not (public.is_super() or (public.has_perm('members') and trole = 'user')) then raise exception '권한이 없습니다'; end if;
  if trole = 'super' and target <> auth.uid() then raise exception '최고관리자 비밀번호는 본인만 변경할 수 있습니다'; end if;
  if char_length(new_password) < 4 then raise exception '비밀번호는 4자 이상이어야 합니다'; end if;
  update auth.users set encrypted_password = extensions.crypt(new_password, extensions.gen_salt('bf')), updated_at = now() where id = target;
  update public.profiles set must_change_pw = (trole = 'user') where id = target;
end $$;

create or replace function public.admin_delete_user(target uuid) returns void
language plpgsql security definer set search_path = public as $$
declare trole text;
begin
  select role into trole from public.profiles where id = target;
  if trole = 'super' then raise exception '최고관리자 계정은 삭제할 수 없습니다'; end if;
  if not (public.is_super() or (public.has_perm('members') and trole = 'user')) then raise exception '권한이 없습니다'; end if;
  if target = auth.uid() then raise exception '본인 계정은 삭제할 수 없습니다'; end if;
  delete from auth.users where id = target;
end $$;

-- ---------- 푸시 구독 저장/해제 ----------
create or replace function public.save_push_subscription(p_endpoint text, p_p256dh text, p_auth text, p_ua text) returns void
language sql security definer set search_path = public as $$
  insert into public.push_subscriptions(endpoint, user_id, p256dh, auth, ua)
  values (p_endpoint, auth.uid(), p_p256dh, p_auth, p_ua)
  on conflict (endpoint) do update set user_id = auth.uid(), p256dh = excluded.p256dh, auth = excluded.auth, ua = excluded.ua, created_at = now()
$$;
create or replace function public.delete_push_subscription(p_endpoint text) returns void
language sql security definer set search_path = public as $$
  delete from public.push_subscriptions where endpoint = p_endpoint and user_id = auth.uid()
$$;

revoke execute on function public.save_push_subscription(text, text, text, text) from anon;
revoke execute on function public.delete_push_subscription(text) from anon;
revoke execute on function public.admin_upsert_members(jsonb) from anon;
revoke execute on function public.admin_create_admin(text, text, jsonb, jsonb) from anon;

-- ---------- 새 글 → 푸시 발송 (Edge Function 호출, 실패해도 글 등록은 정상) ----------
create extension if not exists pg_net with schema extensions;
create or replace function public.notify_new_post() returns trigger
language plpgsql security definer set search_path = public, extensions as $$
declare u text; sec text;
begin
  select value into u   from public.app_secrets where key = 'push_url';
  select value into sec from public.app_secrets where key = 'push_secret';
  if u is not null and sec is not null then
    perform net.http_post(url := u, body := jsonb_build_object('post_id', new.id),
                          headers := jsonb_build_object('Content-Type', 'application/json', 'x-push-secret', sec));
  end if;
  return null;
exception when others then return null;
end $$;
drop trigger if exists posts_push on public.posts;
create trigger posts_push after insert on public.posts for each row execute function public.notify_new_post();

create or replace function public.admin_month_counter(mk text) returns int
language sql stable security definer set search_path = public as $$
  select case when public.is_admin() then coalesce((select val from public.counters where key = 'p' || mk), 0) else null end
$$;

-- ---------- RLS ----------
alter table public.settings         enable row level security;
alter table public.boards           enable row level security;
alter table public.profiles         enable row level security;
alter table public.nickname_history enable row level security;
alter table public.counters         enable row level security;
alter table public.posts            enable row level security;
alter table public.comments         enable row level security;
alter table public.reactions        enable row level security;
alter table public.like_log         enable row level security;
alter table public.events           enable row level security;
alter table public.popups           enable row level security;
alter table public.surveys          enable row level security;
alter table public.survey_responses enable row level security;
alter table public.survey_draws     enable row level security;
alter table public.survey_analysis  enable row level security;
alter table public.push_subscriptions enable row level security;
alter table public.app_secrets      enable row level security;

do $$ declare r record; begin
  for r in select policyname, tablename from pg_policies
           where schemaname = 'public'
             and tablename in ('settings','boards','profiles','nickname_history','counters','posts','comments','reactions','like_log','events','popups','push_subscriptions','app_secrets','surveys','survey_responses','survey_draws','survey_analysis')
  loop execute format('drop policy if exists %I on public.%I', r.policyname, r.tablename); end loop;
end $$;

-- settings: 가입코드는 관리자만 조회
create policy settings_read  on public.settings for select using (key <> 'signup_code' or public.is_admin());
create policy settings_write on public.settings for all    using (public.has_perm('settings')) with check (public.has_perm('settings'));

create policy boards_read  on public.boards for select using (true);
create policy boards_write on public.boards for all    using (public.has_perm('settings')) with check (public.has_perm('settings'));

-- profiles: 실명/사번은 본인과 관리자만
create policy profiles_read   on public.profiles for select using (id = auth.uid() or public.is_super() or public.has_perm('members'));
create policy profiles_update on public.profiles for update
  using      (id = auth.uid() or public.is_super() or (public.has_perm('members') and role = 'user'))
  with check (id = auth.uid() or public.is_super() or (public.has_perm('members') and role = 'user'));
create policy profiles_delete on public.profiles for delete using (public.is_super() or (public.has_perm('members') and role = 'user'));

create policy nh_read on public.nickname_history for select using (user_id = auth.uid() or public.is_admin());

create policy posts_read   on public.posts for select to authenticated using (true);
create policy posts_insert on public.posts for insert to authenticated with check (user_id = auth.uid());
create policy posts_update on public.posts for update to authenticated using (user_id = auth.uid() or public.has_perm('posts'));
create policy posts_delete on public.posts for delete to authenticated using (user_id = auth.uid() or public.has_perm('posts'));

create policy comments_read   on public.comments for select to authenticated using (true);
create policy comments_insert on public.comments for insert to authenticated with check (user_id = auth.uid());
create policy comments_update on public.comments for update to authenticated using (user_id = auth.uid() or public.has_perm('comments'));
create policy comments_delete on public.comments for delete to authenticated using (user_id = auth.uid() or public.has_perm('comments'));

-- reactions: 본인 것만 조회 (누가 어떤 글에 좋아요 했는지 비공개), 쓰기는 toggle_like 함수로만
create policy reactions_read   on public.reactions for select to authenticated using (user_id = auth.uid());
-- like_log: 정책 없음 = 직접 조회 불가 (admin_like_counts 집계로만 확인)

-- events(당첨 번호): 관리자만
create policy events_admin on public.events for all using (public.has_perm('events')) with check (public.has_perm('events'));

-- popups: 로그인 회원은 조회, 등록·수정은 관리자만
create policy popups_read  on public.popups for select to authenticated using (true);
create policy popups_write on public.popups for all using (public.has_perm('popups')) with check (public.has_perm('popups'));

create policy push_own on public.push_subscriptions for select using (user_id = auth.uid());

-- 리서치: 회원은 노출된 설문만 보고, 진행 중인 설문에 본인 계정으로 1회 제출
create policy surveys_read  on public.surveys for select to authenticated using ((is_published and public.survey_targets_me(id)) or public.has_perm('research'));
create policy surveys_write on public.surveys for all using (public.has_perm('research')) with check (public.has_perm('research'));
create policy sresp_insert  on public.survey_responses for insert to authenticated with check (user_id = auth.uid() and public.survey_is_open(survey_id) and public.survey_targets_me(survey_id));
create policy sana_all      on public.survey_analysis for all using (public.has_perm('research')) with check (public.has_perm('research'));
create policy sresp_read    on public.survey_responses for select to authenticated using (public.has_perm('research'));
create policy sresp_delete  on public.survey_responses for delete to authenticated using (public.has_perm('research'));
-- survey_draws: 정책 없음 (추첨 함수로만)

-- =====================================================================
--  ★ 익명 보호: 글·댓글의 작성자 계정(user_id)과 소속(author_dept)은 최고관리자(admin)만 조회
--    · 원본 테이블에서 두 컬럼의 조회 권한 자체를 회수 (API로 직접 요청해도 거부)
--    · 화면은 posts_v / comments_v 뷰를 사용: 본인 글 여부(mine)만 알려주고, 계정·소속은 admin에게만 채워줌
-- =====================================================================
revoke select on public.posts from anon, authenticated;
grant select (id, board_id, title, body, link_url, link_title, images, pdf, is_pinned, month_key, month_seq, author_nickname, author_role,
              like_count, dislike_count, comment_count, created_at, updated_at) on public.posts to authenticated;
revoke select on public.comments from anon, authenticated;
grant select (id, post_id, body, images, month_key, month_seq, author_nickname, author_role, created_at, updated_at) on public.comments to authenticated;

create or replace view public.posts_v as
  select p.id, p.board_id, p.title, p.body, p.link_url, p.images, p.pdf, p.is_pinned, p.month_key, p.month_seq,
         p.author_nickname, p.author_role, p.like_count, p.dislike_count, p.comment_count, p.created_at, p.updated_at,
         (p.user_id = auth.uid()) as mine,
         case when s.sup then p.user_id end as user_id,
         case when s.sup then coalesce(nullif(concat_ws(' ', pr.org_branch, pr.work_branch), ''), p.author_dept) end as author_dept,   -- 예) Clinic3부 서부지점 · 최고관리자 외에는 관리자 글 포함 항상 null
         p.link_title
  from public.posts p cross join (select public.is_super() as sup) s
  left join public.profiles pr on s.sup and pr.id = p.user_id
  where auth.uid() is not null;
create or replace view public.comments_v as
  select c.id, c.post_id, c.body, c.images, c.month_key, c.month_seq, c.author_nickname, c.author_role, c.created_at, c.updated_at,
         (c.user_id = auth.uid()) as mine,
         case when s.sup then c.user_id end as user_id,
         case when s.sup then coalesce(nullif(concat_ws(' ', pr.org_branch, pr.work_branch), ''), c.author_dept) end as author_dept
  from public.comments c cross join (select public.is_super() as sup) s
  left join public.profiles pr on s.sup and pr.id = c.user_id
  where auth.uid() is not null;
revoke all on public.posts_v, public.comments_v from anon;

-- 관리자 글은 글번호에서 제외 (이미 올라간 관리자 글의 번호도 지움 · 회원 글 번호는 히든보이스 이벤트 보호를 위해 그대로 유지)
update public.posts set month_seq = null where author_role = 'admin' and month_seq is not null;
-- [선택] 이번 달 회원 글 번호를 001부터 빈칸 없이 다시 매기려면, 아래 4줄 맨 앞의 '-- ' 를 지우고 그 4줄만 선택해서 실행
--        ※ 히든보이스 당첨 번호가 바뀔 수 있으니 이벤트 진행 중인 달에는 실행하지 마세요
-- with r as (select id, row_number() over (order by id) n from public.posts where month_key = public.kst_month() and author_role <> 'admin')
-- update public.posts p set month_seq = r.n from r where p.id = r.id;
-- insert into public.counters(key, val) select 'p' || public.kst_month(), coalesce(max(month_seq), 0) from public.posts where month_key = public.kst_month()
--   on conflict (key) do update set val = excluded.val;
grant select on public.posts_v, public.comments_v to authenticated;

-- 설문 응답도 익명: 누가 어떤 답을 했는지(user_id)는 조회 불가, 답변 내용만 집계용으로 조회
revoke select on public.survey_responses from anon, authenticated;
grant select (id, survey_id, answers, submitted_at) on public.survey_responses to authenticated;

-- 회원 랭킹 (닉네임·점수만, 계정·소속 없이)
create or replace function public.get_ranking(mk text) returns table(nickname text, posts bigint, likes bigint, comments bigint, score bigint, is_me boolean)
language sql stable security definer set search_path = public as $$
  with w as (select (value->>'like')::int as lw, (value->>'comment')::int as cw from public.settings where key = 'score'),
  g as (select user_id, count(*) as posts, sum(like_count)::bigint as likes, sum(comment_count)::bigint as comments,
               (array_agg(author_nickname order by id desc))[1] as nickname
        from public.posts
        where coalesce(author_role, 'user') <> 'admin' and user_id is not null and (coalesce(mk, '') = '' or month_key = mk)
        group by user_id)
  select g.nickname, g.posts, g.likes, g.comments,
         (g.likes * coalesce(w.lw, 3) + g.comments * coalesce(w.cw, 1))::bigint, g.user_id = auth.uid()
  from g left join w on true
  where public.is_admin()          -- 랭킹은 관리자만 (일반 회원 화면에는 집계 노출 안 함)
  order by 5 desc, 2 desc
$$;
revoke execute on function public.get_ranking(text) from anon;

-- ---------- 이달의 Voice 시상 ----------
--  심사 시상(본사 심의): grand 최우수 · excellent 우수 · merit 장려  — 관리자가 '글'에서 선정
--  결과 시상(집계)    : popular 인기 · reaction 리액션 · big Big Voice
--  이벤트            : nth N번째 Voice(히든보이스) · survey 설문 이벤트 당첨
--  한 항목에 여러 명 선정 가능 · 관리자가 [게시]해야 회원 화면에 '닉네임만' 공개
create table if not exists public.voice_awards (
  month_key  text not null,
  category   text not null,
  user_id    uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (month_key, category, user_id)
);
alter table public.voice_awards add column if not exists post_id  bigint references public.posts(id) on delete set null;
alter table public.voice_awards add column if not exists nickname text;   -- 그 달의 닉네임 (선정 시점에 고정)
alter table public.voice_awards add column if not exists note     text;   -- 예) 설문 제목
alter table public.voice_awards drop constraint if exists voice_awards_category_check;
alter table public.voice_awards add constraint voice_awards_category_check
  check (category in ('grand','excellent','merit','popular','reaction','big','nth','survey'));
alter table public.voice_awards enable row level security;
drop policy if exists va_none on public.voice_awards;
create policy va_none on public.voice_awards for select using (false);   -- 직접 조회 금지 (아래 함수로만)
revoke all on public.voice_awards from anon, authenticated;

create table if not exists public.voice_award_pub (
  month_key    text primary key,
  published    boolean not null default false,
  published_at timestamptz
);
alter table public.voice_award_pub enable row level security;
drop policy if exists vap_none on public.voice_award_pub;
create policy vap_none on public.voice_award_pub for select using (false);
revoke all on public.voice_award_pub from anon, authenticated;

-- 그 달에 쓰던 닉네임
create or replace function public.month_nickname(uid uuid, mk text) returns text
language sql stable security definer set search_path = public as $$
  select coalesce((select h.nickname from public.nickname_history h where h.user_id = uid and h.month_key = mk order by h.created_at desc limit 1),
                  (select p.author_nickname from public.posts p where p.user_id = uid and p.month_key = mk order by p.id desc limit 1),
                  (select c.author_nickname from public.comments c where c.user_id = uid and c.month_key = mk order by c.id desc limit 1),
                  (select nickname from public.profiles where id = uid));
$$;
revoke execute on function public.month_nickname(uuid, text) from anon, authenticated;

-- 결과 시상 후보 집계: 계정 id 대신 토큰(md5)을 주고, 실명·사번·소속은 최고관리자에게만
drop function if exists public.admin_voice_stats(text);
create or replace function public.admin_voice_stats(mk text)
returns table(token text, nickname text, posts bigint, comments_written bigint, likes bigint, comments_received bigint, score bigint,
              real_name text, emp_no text, dept text, picked text[])
language plpgsql stable security definer set search_path = public as $$
declare sup boolean := public.is_super(); lw int; cw int;
begin
  if not public.has_perm('rank') then raise exception '순위·점수 관리 권한이 없습니다'; end if;
  select coalesce((value->>'like')::int, 1), coalesce((value->>'comment')::int, 2) into lw, cw from public.settings where key = 'score';
  lw := coalesce(lw, 1); cw := coalesce(cw, 2);
  return query
  -- 인기 Voice 점수: 본인을 뺀 좋아요(관리자 좋아요 포함 · 최고관리자는 누른 횟수만큼) × A + 본인·관리자를 뺀 다른 회원 댓글(한 글에 같은 사람은 1번) × B
  with mp as (select x.id, x.user_id from public.posts x where x.month_key = mk and coalesce(x.author_role, 'user') <> 'admin' and x.user_id is not null),
       adm as (select id from public.profiles where role in ('admin','super')),
       vl as (select mp.user_id uid, coalesce(sum(r.qty), 0) n from public.reactions r join mp on mp.id = r.post_id
              where r.type = 'like' and r.user_id <> mp.user_id group by mp.user_id),
       vc as (select t.uid, count(*) n from (select distinct mp.user_id uid, c.post_id, c.user_id from public.comments c join mp on mp.id = c.post_id
              where c.user_id is not null and c.user_id <> mp.user_id and c.user_id not in (select id from adm)) t group by t.uid),
       pp as (select mp.user_id uid, count(*) pn, coalesce(max(vl.n), 0) pl, coalesce(max(vc.n), 0) pc
              from mp left join vl on vl.uid = mp.user_id left join vc on vc.uid = mp.user_id group by mp.user_id),
       cc as (select y.user_id uid, count(*) cn from public.comments y
              where y.month_key = mk and coalesce(y.author_role, 'user') <> 'admin' and y.user_id is not null group by y.user_id),
       uu as (select pp.uid from pp union select cc.uid from cc)
  select md5(mk || uu.uid::text), public.month_nickname(uu.uid, mk),
         coalesce(pp.pn, 0)::bigint, coalesce(cc.cn, 0)::bigint, coalesce(pp.pl, 0)::bigint, coalesce(pp.pc, 0)::bigint,
         (coalesce(pp.pl, 0) * lw + coalesce(pp.pc, 0) * cw)::bigint,
         case when sup then pr.real_name end, case when sup then pr.emp_no end,
         case when sup then nullif(concat_ws(' ', pr.org_branch, pr.work_branch), '') end,
         coalesce((select array_agg(a.category order by a.category) from public.voice_awards a where a.month_key = mk and a.user_id = uu.uid), '{}'::text[])
  from uu join public.profiles pr on pr.id = uu.uid
  left join pp on pp.uid = uu.uid left join cc on cc.uid = uu.uid
  where pr.role = 'user';
end $$;
revoke execute on function public.admin_voice_stats(text) from anon;
-- 점수 기준: 예전 기본값(좋아요 3·댓글 1)을 쓰고 있으면 새 기준(좋아요 1·댓글 2)으로 변경 (관리자가 직접 바꾼 값은 그대로)
update public.settings set value = '{"like":1,"comment":2}'::jsonb where key = 'score' and value = '{"like":3,"comment":1}'::jsonb;

-- 이벤트 시상 후보: 그 달 닉네임이 있는 회원 전체 + 설문 당첨 이력
create or replace function public.admin_award_candidates(mk text)
returns table(token text, nickname text, survey_wins text[], real_name text, emp_no text, dept text)
language plpgsql stable security definer set search_path = public as $$
declare sup boolean := public.is_super();
begin
  if not public.has_perm('rank') then raise exception '순위·점수 관리 권한이 없습니다'; end if;
  return query
  select md5(mk || pr.id::text), public.month_nickname(pr.id, mk),
         coalesce((select array_agg(s.title order by d.drawn_at) from public.survey_draws d join public.surveys s on s.id = d.survey_id
                   where pr.id = any(d.winner_ids) and to_char(d.drawn_at at time zone 'Asia/Seoul', 'YYMM') >= mk), '{}'::text[]),
         case when sup then pr.real_name end, case when sup then pr.emp_no end,
         case when sup then nullif(concat_ws(' ', pr.org_branch, pr.work_branch), '') end
  from public.profiles pr where pr.role = 'user' and pr.status <> 'deleted';
end $$;
revoke execute on function public.admin_award_candidates(text) from anon;

-- 선정/해제 (회원 토큰으로)
drop function if exists public.admin_set_award(text, text, text, boolean);
create or replace function public.admin_set_award(mk text, cat text, tok text, on_ boolean, note_ text default null)
returns void language plpgsql security definer set search_path = public as $$
declare uid uuid;
begin
  if not public.has_perm('rank') then raise exception '순위·점수 관리 권한이 없습니다'; end if;
  if cat not in ('grand','excellent','merit','popular','reaction','big','nth','survey') then raise exception '잘못된 시상 항목'; end if;
  select id into uid from public.profiles where md5(mk || id::text) = tok;
  if uid is null then raise exception '대상 회원을 찾을 수 없습니다'; end if;
  if on_ then
    insert into public.voice_awards(month_key, category, user_id, nickname, note) values (mk, cat, uid, public.month_nickname(uid, mk), note_)
      on conflict (month_key, category, user_id) do update set note = coalesce(excluded.note, public.voice_awards.note);
  else delete from public.voice_awards where month_key = mk and category = cat and user_id = uid; end if;
end $$;
revoke execute on function public.admin_set_award(text, text, text, boolean, text) from anon;

-- 선정/해제 (게시글로 — 심사 시상·N번째 Voice)
create or replace function public.admin_set_award_post(mk text, cat text, pid bigint, on_ boolean)
returns void language plpgsql security definer set search_path = public as $$
declare po public.posts;
begin
  if not public.has_perm('rank') then raise exception '순위·점수 관리 권한이 없습니다'; end if;
  if cat not in ('grand','excellent','merit','popular','reaction','big','nth','survey') then raise exception '잘못된 시상 항목'; end if;
  select * into po from public.posts where id = pid;
  if po.id is null or po.user_id is null then raise exception '게시글(작성자)을 찾을 수 없습니다'; end if;
  if on_ then
    insert into public.voice_awards(month_key, category, user_id, post_id, nickname) values (mk, cat, po.user_id, po.id, coalesce(po.author_nickname, public.month_nickname(po.user_id, mk)))
      on conflict (month_key, category, user_id) do update set post_id = excluded.post_id, nickname = excluded.nickname;
  else delete from public.voice_awards where month_key = mk and category = cat and (post_id = pid or (post_id is null and user_id = po.user_id)); end if;
end $$;
revoke execute on function public.admin_set_award_post(text, text, bigint, boolean) from anon;

-- 관리자용 선정 목록
create or replace function public.admin_get_awards(mk text)
returns table(category text, token text, nickname text, post_id bigint, post_title text, note text, real_name text, emp_no text, dept text, published boolean, published_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
declare sup boolean := public.is_super();
begin
  if not public.has_perm('rank') then raise exception '순위·점수 관리 권한이 없습니다'; end if;
  return query
  select a.category, md5(mk || a.user_id::text), a.nickname, a.post_id, po.title, a.note,
         case when sup then pr.real_name end, case when sup then pr.emp_no end,
         case when sup then nullif(concat_ws(' ', pr.org_branch, pr.work_branch), '') end,
         coalesce(pb.published, false), pb.published_at
  from public.voice_awards a join public.profiles pr on pr.id = a.user_id
  left join public.posts po on po.id = a.post_id
  left join public.voice_award_pub pb on pb.month_key = a.month_key
  where a.month_key = mk order by a.category, a.created_at;
end $$;
revoke execute on function public.admin_get_awards(text) from anon;

create or replace function public.admin_award_pub_state(mk text) returns json
language sql stable security definer set search_path = public as $$
  select case when not public.has_perm('rank') then null else
    coalesce((select json_build_object('published', published, 'published_at', published_at) from public.voice_award_pub where month_key = mk), json_build_object('published', false)) end
$$;
revoke execute on function public.admin_award_pub_state(text) from anon;

-- 게시 / 게시 취소
create or replace function public.admin_publish_awards(mk text, on_ boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.has_perm('rank') then raise exception '순위·점수 관리 권한이 없습니다'; end if;
  insert into public.voice_award_pub(month_key, published, published_at) values (mk, on_, case when on_ then now() end)
    on conflict (month_key) do update set published = excluded.published, published_at = excluded.published_at;
end $$;
revoke execute on function public.admin_publish_awards(text, boolean) from anon;

-- 회원 화면용: 게시된 달의 결과만, 닉네임으로만 (계정·실명·소속 없음)
create or replace function public.voice_awards_public(mk text)
returns table(category text, nickname text, post_id bigint, post_title text, note text)
language sql stable security definer set search_path = public as $$
  select a.category, a.nickname, a.post_id, po.title, a.note
  from public.voice_awards a
  join public.voice_award_pub pb on pb.month_key = a.month_key and pb.published
  left join public.posts po on po.id = a.post_id
  where a.month_key = mk and auth.uid() is not null
  order by a.category, a.created_at
$$;
revoke execute on function public.voice_awards_public(text) from anon;

create or replace function public.voice_award_months() returns setof text
language sql stable security definer set search_path = public as $$
  select month_key from public.voice_award_pub where published and auth.uid() is not null order by month_key desc
$$;
revoke execute on function public.voice_award_months() from anon;

-- ---------- 첨부파일 Storage (게시글 사진 2장·PDF 20MB, 팝업 이미지 10MB·동영상 50MB) ----------
insert into storage.buckets (id, name, public, file_size_limit)
values ('voy-files', 'voy-files', true, 52428800)
on conflict (id) do update set public = true, file_size_limit = 52428800;

drop policy if exists voy_files_read   on storage.objects;
drop policy if exists voy_files_upload on storage.objects;
drop policy if exists voy_files_delete on storage.objects;
create policy voy_files_read   on storage.objects for select using (bucket_id = 'voy-files');
create policy voy_files_upload on storage.objects for insert to authenticated with check (bucket_id = 'voy-files');
create policy voy_files_delete on storage.objects for delete to authenticated
  using (bucket_id = 'voy-files' and (owner = auth.uid() or public.is_admin()));

-- ---------- 로그인 오류 예방: SQL로 만든 계정의 빈 토큰 칸 채우기 (NULL이면 'Database error querying schema'로 로그인 실패) ----------
update auth.users set
  confirmation_token = coalesce(confirmation_token, ''), recovery_token = coalesce(recovery_token, ''),
  email_change = coalesce(email_change, ''), email_change_token_new = coalesce(email_change_token_new, ''),
  email_change_token_current = coalesce(email_change_token_current, ''), phone_change = coalesce(phone_change, ''),
  phone_change_token = coalesce(phone_change_token, ''), reauthentication_token = coalesce(reauthentication_token, '')
where confirmation_token is null or recovery_token is null or email_change is null or email_change_token_new is null
   or email_change_token_current is null or phone_change is null or phone_change_token is null or reauthentication_token is null;

-- ---------- 최고관리자 기본 계정: admin / admin1234 ----------
do $$
declare aid uuid;
begin
  select id into aid from auth.users where email = 'admin@voy-community.app';
  -- 계정은 있는데 프로필이 없으면(예전 실행 중 오류) 프로필을 다시 만듦
  if aid is not null and not exists (select 1 from public.profiles where id = aid) then
    insert into public.profiles(id, login_id, email, real_name, org_branch, dept, role, nickname)
    values (aid, 'admin', 'admin@voy-community.app', '최고관리자', '영업기획팀', '영업기획팀', 'super', public.gen_nickname());
  end if;
  if aid is not null then update public.profiles set role = 'super', login_id = 'admin' where id = aid; end if;
  if aid is null then
    perform public._create_auth_user('admin@voy-community.app', 'admin1234',
      jsonb_build_object('login_id', 'admin', 'role', 'super', 'real_name', '최고관리자', 'nickname', '영업기획팀', 'org_branch', '영업기획팀'));
  end if;
end $$;
-- [비밀번호를 잊었을 때만] 아래 한 줄의 맨 앞 -- 를 지우고 실행하면 admin 비밀번호가 admin1234로 돌아갑니다
-- update auth.users set encrypted_password = extensions.crypt('admin1234', extensions.gen_salt('bf')), updated_at = now() where email = 'admin@voy-community.app';

-- =====================================================================
--  [선택] 새 글 푸시 알림 연결 — Edge Function(voy-push) 배포 후 아래 2줄의 값을 바꿔 실행
--  insert into public.app_secrets values ('push_url',    'https://<프로젝트ID>.supabase.co/functions/v1/voy-push') on conflict (key) do update set value = excluded.value;
--  insert into public.app_secrets values ('push_secret', '<PUSH_SECRET과 같은 값>')                                on conflict (key) do update set value = excluded.value;
-- =====================================================================
