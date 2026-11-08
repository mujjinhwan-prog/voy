-- =====================================================================
--  ※ 이 파일은 1/2입니다. 실행 후 voy_schema_2of2.sql 을 이어서 실행하세요.
--  Voice of YUHAN 커뮤니티 — Supabase 스키마 (SQL Editor에 통째로 붙여넣고 Run)
--  · 로그인: 회사 이메일(@yuhan.co.kr) + 비밀번호 / 관리자: 아이디(admin 등) + 비밀번호
--  · 최고관리자 admin / admin1234 자동 생성 (로그인 후 비밀번호 꼭 변경)
--  · 회원은 관리자 페이지 [엑셀 일괄 등록]으로 생성 (초기 비밀번호 = 사번, 첫 로그인 시 변경)
--  · 회원/닉네임(형용사+동물+2자리숫자, 월 1회 변경)
--  · 게시판 5개, 게시글(월별 번호 YYMM_NN), 댓글, 좋아요/싫어요
--  · 점수(좋아요·댓글 가중치), 히든보이스 이벤트(관리자 지정 N번째 글)
--  재실행해도 안전하도록 작성 (if not exists / or replace)
--  ※ 실행 후: Authentication → Sign In / Providers → 'Allow new users to sign up' 끄기 (회원은 관리자만 등록)
-- =====================================================================

create extension if not exists pgcrypto with schema extensions;

-- ---------- 공통 ----------
create or replace function public.kst_month() returns text
language sql stable as $$ select to_char(now() at time zone 'Asia/Seoul', 'YYMM') $$;

-- ---------- 테이블 ----------
create table if not exists public.settings (
  key        text primary key,
  value      jsonb not null,
  updated_at timestamptz not null default now()
);

create table if not exists public.boards (
  id         text primary key,
  name       text not null,
  color      text not null default '#7bcf7f',
  sort       int  not null default 0,
  admin_only boolean not null default false
);

create table if not exists public.profiles (
  id             uuid primary key references auth.users(id) on delete cascade,
  login_id       text unique not null,
  real_name      text,
  emp_no         text,
  dept           text,
  branch         text,
  role           text not null default 'user' check (role in ('user','admin','super')),
  status         text not null default 'active' check (status in ('active','blocked')),
  nickname       text unique not null,
  nickname_month text,                       -- 마지막으로 '본인이' 닉네임을 바꾼 달(YYMM)
  created_at     timestamptz not null default now(),
  last_seen      timestamptz not null default now()
);

-- 세부정보·권한 컬럼 (기존 설치본에도 추가되도록 alter 사용)
alter table public.profiles add column if not exists email          text;
alter table public.profiles add column if not exists category       text;   -- 구분
alter table public.profiles add column if not exists org_branch     text;   -- 조직지점
alter table public.profiles add column if not exists work_branch    text;   -- 근무지점
alter table public.profiles add column if not exists sales_office   text;   -- 영업소
alter table public.profiles add column if not exists position       text;   -- 직위
alter table public.profiles add column if not exists duty           text;   -- 직책
alter table public.profiles add column if not exists perms          jsonb not null default '[]';  -- 관리자 메뉴 권한
alter table public.profiles add column if not exists must_change_pw boolean not null default false;
alter table public.profiles drop constraint if exists profiles_role_check;
alter table public.profiles add constraint profiles_role_check check (role in ('user','admin','super'));

create table if not exists public.nickname_history (
  id         bigserial primary key,
  user_id    uuid references public.profiles(id) on delete cascade,
  nickname   text not null,
  month_key  text not null,
  created_at timestamptz not null default now()
);

create table if not exists public.counters (
  key text primary key,
  val int  not null default 0
);

create table if not exists public.posts (
  id              bigserial primary key,            -- 누적 번호
  user_id         uuid references public.profiles(id) on delete set null,
  board_id        text references public.boards(id),
  title           text not null,
  body            text not null default '',
  link_url        text,
  images          jsonb not null default '[]',      -- [{url,name}]
  pdf             jsonb,                            -- {url,name,size}
  is_pinned       boolean not null default false,
  month_key       text,                             -- YYMM
  month_seq       int,                              -- 이번달 번호
  author_nickname text,                             -- 작성 당시 닉네임(익명 유지)
  author_dept     text,
  author_role     text,
  like_count      int not null default 0,
  dislike_count   int not null default 0,
  comment_count   int not null default 0,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
alter table public.posts add column if not exists link_title text;   -- 첨부 링크의 페이지 제목
create index if not exists posts_month_idx on public.posts(month_key, month_seq);
create index if not exists posts_user_idx  on public.posts(user_id);

create table if not exists public.comments (
  id              bigserial primary key,
  post_id         bigint references public.posts(id) on delete cascade,
  user_id         uuid references public.profiles(id) on delete set null,
  body            text not null,
  month_key       text,
  month_seq       int,
  author_nickname text,
  author_dept     text,
  author_role     text,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
create index if not exists comments_post_idx on public.comments(post_id);
alter table public.comments add column if not exists images jsonb not null default '[]';   -- 댓글 첨부 이미지 [{url,name,path}]

create table if not exists public.reactions (
  post_id    bigint references public.posts(id) on delete cascade,
  user_id    uuid references public.profiles(id) on delete cascade,
  type       text not null check (type in ('like','dislike')),
  created_at timestamptz not null default now(),
  primary key (post_id, user_id)
);

-- 좋아요: 1인 1회(최고관리자 admin만 무제한 → qty 누적), 싫어요 기능 없음
alter table public.reactions add column if not exists qty int not null default 1;
delete from public.reactions where type = 'dislike';

-- 좋아요 클릭 기록 (회원별 월간 좋아요 수 집계용 · 어느 글에 눌렀는지는 관리자에게도 노출하지 않음)
create table if not exists public.like_log (
  id         bigserial primary key,
  user_id    uuid references public.profiles(id) on delete cascade,
  post_id    bigint references public.posts(id) on delete set null,
  month_key  text not null,
  created_at timestamptz not null default now()
);
create index if not exists like_log_user_month_idx on public.like_log(user_id, month_key);
insert into public.like_log(user_id, post_id, month_key, created_at)
  select r.user_id, r.post_id, to_char(r.created_at at time zone 'Asia/Seoul', 'YYMM'), r.created_at
  from public.reactions r where r.type = 'like' and not exists (select 1 from public.like_log);

create table if not exists public.events (
  id         bigserial primary key,
  month_key  text unique not null,               -- YYMM
  numbers    int[] not null,                     -- 당첨 글번호 (예: {8,33,40})
  status     text not null default 'active' check (status in ('active','closed')),
  memo       text,
  created_at timestamptz not null default now()
);

create table if not exists public.popups (
  id         bigserial primary key,
  title      text not null default '',
  media_url  text not null,
  media_type text not null check (media_type in ('image','video')),
  media_path text,
  media_name text,
  media_size bigint,
  link_url   text,
  start_at   date,
  end_at     date,
  active     boolean not null default true,
  sort       int not null default 0,
  created_at timestamptz not null default now()
);

-- 웹 푸시(새 글 알림) 구독
create table if not exists public.push_subscriptions (
  endpoint   text primary key,
  user_id    uuid references public.profiles(id) on delete cascade,
  p256dh     text not null,
  auth       text not null,
  ua         text,
  created_at timestamptz not null default now()
);

-- 서버 비밀값 (푸시 함수 주소·비밀키) — 정책 없음 = 클라이언트에서 절대 조회 불가
create table if not exists public.app_secrets (
  key   text primary key,
  value text not null
);

-- ---------- 리서치(설문) — 회원은 닉네임 입력 없이 로그인 계정으로 1인 1회 참여 ----------
create table if not exists public.surveys (
  id            bigserial primary key,
  title         text not null default '',
  description   text not null default '',
  questions     jsonb not null default '[]',     -- [{id, type:'choice'|'text', text, choices:[], required}]
  start_at      timestamptz,
  end_at        timestamptz,
  manual_status text not null default 'auto' check (manual_status in ('auto','forceOpen','forceClosed')),
  is_published  boolean not null default false,  -- 회원 리서치 목록에 노출
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
create table if not exists public.survey_responses (
  id           bigserial primary key,
  survey_id    bigint not null references public.surveys(id) on delete cascade,
  user_id      uuid references public.profiles(id) on delete set null,
  answers      jsonb not null default '{}',
  submitted_at timestamptz not null default now(),
  unique (survey_id, user_id)
);
create index if not exists survey_responses_sid_idx on public.survey_responses(survey_id);
-- 조사 대상(범위·표기·인원)
alter table public.surveys add column if not exists target       jsonb not null default '{"field":"all","values":[]}';
alter table public.surveys add column if not exists target_label text not null default '';
alter table public.surveys add column if not exists result_count int;      -- 결과 표시 인원(관리자 조정). 비우면 실제 응답 수
alter table public.surveys add column if not exists target_count int;      -- 비우면 대상 범위의 회원 수로 자동 계산
-- 주관식 의견 묶기(대표 문구·기타 의견) — 관리자만
create table if not exists public.survey_analysis (
  survey_id  bigint primary key references public.surveys(id) on delete cascade,
  data       jsonb not null default '{}',
  updated_at timestamptz not null default now()
);
create table if not exists public.survey_draws (
  survey_id    bigint primary key references public.surveys(id) on delete cascade,
  winner_count int not null,
  winner_ids   uuid[] not null default '{}',
  drawn_at     timestamptz not null default now()
);

-- ---------- 기본 데이터 ----------
insert into public.settings(key, value) values
  ('score',       '{"like":1,"comment":2}'),
  ('depts',       '["Clinic1부","Clinic2부","Clinic3부","Clinic4부","Hospital1부","Hospital2부","Hospital3부","Hospital4부","Hospital5부","영업기획팀"]'),
  ('signup_code', '""')
on conflict (key) do nothing;

insert into public.boards(id, name, color, sort, admin_only) values
  ('success', '성공디테일',        '#4ade80', 1, false),
  ('tool',    'MR Tool 추천',      '#60a5fa', 2, false),
  ('now',     '오늘 그리고 지금...', '#c084fc', 3, false),
  ('suggest', '건의, 제안합니다',   '#fb923c', 4, false),
  ('notice',  '영업기획팀',         '#38bdf8', 5, true)
on conflict (id) do nothing;

-- ---------- 권한 헬퍼 ----------
-- role: super(최고관리자 admin 1명, 모든 권한) / admin(부여된 메뉴만) / user
create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists(select 1 from public.profiles where id = auth.uid() and role in ('admin','super'))
$$;

create or replace function public.is_super() returns boolean
language sql stable security definer set search_path = public as $$
  select exists(select 1 from public.profiles where id = auth.uid() and role = 'super')
$$;

-- 메뉴 권한: posts, comments, members, rank, events, popups, settings
create or replace function public.has_perm(p text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists(select 1 from public.profiles where id = auth.uid()
                and (role = 'super' or (role = 'admin' and perms ? p)))
$$;

create or replace function public.is_privileged() returns boolean
language sql stable security definer set search_path = public as $$
  select auth.uid() is null                                   -- SQL Editor / 서비스키
      or coalesce(current_setting('voy.sys', true), '') = '1' -- 내부 카운트 갱신
      or public.is_admin()
$$;

-- ---------- 닉네임 생성: 형용사 + 동물 + 2자리 숫자 ----------
create or replace function public.gen_nickname() returns text
language plpgsql volatile security definer set search_path = public as $$
declare
  adj text[] := array['사랑스러운','유쾌한','든든한','활기찬','밝은','용감한','씩씩한','다정한','상냥한','명랑한',
                      '슬기로운','부지런한','느긋한','당당한','반짝이는','포근한','따뜻한','재빠른','신중한','엉뚱한',
                      '귀여운','멋진','행복한','즐거운','싱그러운','튼튼한','꼼꼼한','차분한','유능한','열정적인',
                      '수줍은','친절한','성실한','현명한','빛나는','상큼한','듬직한','늠름한','다정다감한','호탕한'];
  ani text[] := array['강아지','고양이','고래','물범','매','하늘소','판다','수달','펭귄','다람쥐',
                      '토끼','여우','코알라','부엉이','돌고래','사자','호랑이','기린','햄스터','알파카',
                      '너구리','사슴','오리','거북이','미어캣','치타','라쿤','곰','참새','두더지',
                      '고슴도치','캥거루','플라밍고','올빼미','앵무새','해달','얼룩말','하마','황새','다람쥐'];
  n text; tries int := 0;
begin
  loop
    n := adj[1 + floor(random() * array_length(adj,1))::int]
      || ani[1 + floor(random() * array_length(ani,1))::int]
      || (10 + floor(random() * 90))::int::text;
    exit when not exists (select 1 from public.profiles where nickname = n);
    tries := tries + 1;
    if tries > 60 then n := n || floor(random()*10)::int::text; exit; end if;
  end loop;
  return n;
end $$;

-- ---------- 계정 생성 시 프로필 자동 생성 ----------
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  m jsonb := coalesce(new.raw_user_meta_data, '{}'::jsonb);
  trusted boolean := coalesce(current_setting('voy.trusted', true), '') = '1';   -- 관리자 RPC로 만든 계정만 역할/권한 반영
  nick text; rl text; em text := lower(new.email);
begin
  rl := case when trusted and m->>'role' in ('user','admin','super') then m->>'role' else 'user' end;
  nick := nullif(btrim(coalesce(m->>'nickname','')), '');
  if nick is null or not trusted or char_length(nick) not between 2 and 12 or exists(select 1 from public.profiles where nickname = nick) then nick := public.gen_nickname(); end if;
  insert into public.profiles(id, login_id, email, real_name, emp_no, category, org_branch, work_branch, sales_office, position, duty,
                              dept, role, perms, must_change_pw, nickname)
  values (new.id,
          coalesce(nullif(m->>'login_id',''), case when em like '%@voy-community.app' then split_part(em, '@', 1) else em end),
          em, m->>'real_name', m->>'emp_no', m->>'category', m->>'org_branch', m->>'work_branch', m->>'sales_office', m->>'position', m->>'duty',
          coalesce(nullif(m->>'org_branch',''), m->>'dept'), rl,
          case when trusted and jsonb_typeof(m->'perms') = 'array' then m->'perms' else '[]'::jsonb end,
          trusted and coalesce((m->>'must_change_pw')::boolean, false),
          nick);
  insert into public.nickname_history(user_id, nickname, month_key) values (new.id, nick, public.kst_month());
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------- 프로필 수정 보호 (닉네임 월 1회, 권한 필드 잠금) ----------
create or replace function public.profiles_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare mk text := public.kst_month(); priv boolean := public.is_privileged(); sup boolean := auth.uid() is null or public.is_super();
begin
  if new.nickname is distinct from old.nickname then
    new.nickname := btrim(new.nickname);
    if char_length(new.nickname) < 2 or char_length(new.nickname) > 12 then
      raise exception '닉네임은 2~12자로 입력해주세요';
    end if;
    if not priv then
      if old.nickname_month = mk then
        raise exception '이번 달에는 이미 닉네임을 변경했습니다 (매월 1일 초기화)';
      end if;
      new.nickname_month := mk;
    end if;
    insert into public.nickname_history(user_id, nickname, month_key) values (new.id, new.nickname, mk);
  elsif not priv then
    new.nickname_month := old.nickname_month;
  end if;

  new.login_id := old.login_id; new.email := old.email; new.created_at := old.created_at;
  if old.role = 'super' then new.role := 'super'; end if;                -- 최고관리자는 강등 불가
  if not sup then new.role := old.role; new.perms := old.perms; end if;   -- 역할·권한 변경은 최고관리자만
  if new.role = 'super' and old.role <> 'super' and auth.uid() is not null then new.role := old.role; end if;
  new.dept := coalesce(nullif(new.org_branch, ''), new.dept);

  if not priv then
    new.status := old.status;
    new.real_name := old.real_name; new.emp_no := old.emp_no; new.category := old.category; new.org_branch := old.org_branch;
    new.work_branch := old.work_branch; new.sales_office := old.sales_office; new.position := old.position; new.duty := old.duty;
    new.dept := old.dept; new.branch := old.branch;
    new.must_change_pw := old.must_change_pw and new.must_change_pw;     -- 본인은 '변경 완료(false)'로만 바꿀 수 있음
  end if;
  return new;
end $$;

drop trigger if exists profiles_guard on public.profiles;
create trigger profiles_guard before update on public.profiles
  for each row execute function public.profiles_guard();

-- ---------- 게시글: 작성자 스냅샷 + 월별 번호 ----------
create or replace function public.posts_before_insert() returns trigger
language plpgsql security definer set search_path = public as $$
declare pr public.profiles; mk text := public.kst_month();
begin
  select * into pr from public.profiles where id = auth.uid();
  if pr.id is null then raise exception '로그인이 필요합니다'; end if;
  if pr.status = 'blocked' then raise exception '글쓰기가 제한된 계정입니다'; end if;
  if coalesce((select admin_only from public.boards where id = new.board_id), false) and pr.role not in ('admin','super') then
    raise exception '관리자 전용 게시판입니다';
  end if;
  new.user_id := pr.id;
  new.author_nickname := pr.nickname;
  new.author_dept := coalesce(nullif(pr.org_branch, ''), pr.dept);
  new.author_role := case when pr.role in ('admin','super') then 'admin' else 'user' end;
  new.month_key := mk;
  if pr.role in ('admin','super') then
    new.month_seq := null;   -- 관리자 글은 글번호(YYMM_NNN)에 포함하지 않음
  else
    insert into public.counters(key, val) values ('p' || mk, 1)
      on conflict (key) do update set val = public.counters.val + 1
      returning val into new.month_seq;
  end if;
  new.like_count := 0; new.dislike_count := 0; new.comment_count := 0;
  new.created_at := now(); new.updated_at := now();
  if pr.role not in ('admin','super') then new.is_pinned := false; end if;
  return new;
end $$;

drop trigger if exists posts_before_insert on public.posts;
create trigger posts_before_insert before insert on public.posts
  for each row execute function public.posts_before_insert();

create or replace function public.posts_before_update() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is not null and not public.is_privileged() then   -- SQL Editor(관리 작업)에서는 제한 없음
    new.user_id := old.user_id; new.month_key := old.month_key; new.month_seq := old.month_seq;
    new.author_nickname := old.author_nickname; new.author_dept := old.author_dept; new.author_role := old.author_role;
    new.like_count := old.like_count; new.dislike_count := old.dislike_count; new.comment_count := old.comment_count;
    new.is_pinned := old.is_pinned; new.created_at := old.created_at;
  end if;
  if coalesce(current_setting('voy.sys', true), '') <> '1' then new.updated_at := now(); end if;
  return new;
end $$;

drop trigger if exists posts_before_update on public.posts;
create trigger posts_before_update before update on public.posts
  for each row execute function public.posts_before_update();

-- ---------- 댓글 ----------
create or replace function public.comments_before_insert() returns trigger
language plpgsql security definer set search_path = public as $$
declare pr public.profiles; mk text := public.kst_month();
begin
  select * into pr from public.profiles where id = auth.uid();
  if pr.id is null then raise exception '로그인이 필요합니다'; end if;
  if pr.status = 'blocked' then raise exception '댓글 작성이 제한된 계정입니다'; end if;
  new.user_id := pr.id;
  new.author_nickname := pr.nickname; new.author_dept := coalesce(nullif(pr.org_branch, ''), pr.dept);
  new.author_role := case when pr.role in ('admin','super') then 'admin' else 'user' end;
  new.month_key := mk;
  insert into public.counters(key, val) values ('c' || mk, 1)
    on conflict (key) do update set val = public.counters.val + 1
    returning val into new.month_seq;
  new.created_at := now(); new.updated_at := now();
  return new;
end $$;

drop trigger if exists comments_before_insert on public.comments;
create trigger comments_before_insert before insert on public.comments
  for each row execute function public.comments_before_insert();

create or replace function public.comments_before_update() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_privileged() then
    new.post_id := old.post_id; new.user_id := old.user_id; new.month_key := old.month_key; new.month_seq := old.month_seq;
    new.author_nickname := old.author_nickname; new.author_dept := old.author_dept; new.author_role := old.author_role;
    new.created_at := old.created_at;
  end if;
  new.updated_at := now();
  return new;
end $$;

drop trigger if exists comments_before_update on public.comments;
create trigger comments_before_update before update on public.comments
  for each row execute function public.comments_before_update();

-- ---------- 좋아요/싫어요/댓글 수 자동 집계 ----------
create or replace function public.sync_post_counts(pid bigint) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform set_config('voy.sys', '1', true);
  update public.posts set
    like_count    = (select coalesce(sum(qty), 0) from public.reactions where post_id = pid and type = 'like'),
    dislike_count = 0,
    comment_count = (select count(*) from public.comments  where post_id = pid)
  where id = pid;
  perform set_config('voy.sys', '0', true);
end $$;

create or replace function public.trg_sync_counts() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform public.sync_post_counts(coalesce(new.post_id, old.post_id));
  return null;
end $$;

drop trigger if exists reactions_sync on public.reactions;
create trigger reactions_sync after insert or update or delete on public.reactions
  for each row execute function public.trg_sync_counts();

drop trigger if exists comments_sync on public.comments;
create trigger comments_sync after insert or delete on public.comments
  for each row execute function public.trg_sync_counts();

-- ---------- 좋아요 누르기/취소 (1인 1회 토글 · 최고관리자는 누를 때마다 +1) ----------
create or replace function public.toggle_like(p_post bigint) returns json
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); mine boolean; lc int; cc int; myq int;
begin
  if uid is null then raise exception '로그인이 필요합니다'; end if;
  if not exists (select 1 from public.posts where id = p_post) then raise exception '삭제되었거나 없는 글입니다'; end if;
  if public.is_super() then
    insert into public.reactions(post_id, user_id, type, qty) values (p_post, uid, 'like', 1)
      on conflict (post_id, user_id) do update set qty = public.reactions.qty + 1, type = 'like';
    insert into public.like_log(user_id, post_id, month_key) values (uid, p_post, public.kst_month());
    mine := true;
  elsif exists (select 1 from public.reactions where post_id = p_post and user_id = uid) then
    delete from public.reactions where post_id = p_post and user_id = uid;
    delete from public.like_log where id = (select id from public.like_log where user_id = uid and post_id = p_post order by id desc limit 1);
    mine := false;
  else
    insert into public.reactions(post_id, user_id, type, qty) values (p_post, uid, 'like', 1);
    insert into public.like_log(user_id, post_id, month_key) values (uid, p_post, public.kst_month());
    mine := true;
  end if;
  select like_count, comment_count into lc, cc from public.posts where id = p_post;
  select qty into myq from public.reactions where post_id = p_post and user_id = uid;
  return json_build_object('mine', mine, 'like_count', lc, 'comment_count', cc, 'my_qty', coalesce(myq, 0));
end $$;
revoke execute on function public.toggle_like(bigint) from anon;

-- 회원별·월별 좋아요 클릭 수 (관리자 전용, 대상 글 정보 없음)
create or replace function public.admin_like_counts() returns table(user_id uuid, month_key text, cnt bigint)
language sql stable security definer set search_path = public as $$
  select l.user_id, l.month_key, count(*) from public.like_log l
  where (public.is_super() or public.has_perm('members')) and l.user_id is not null
  group by l.user_id, l.month_key
$$;
revoke execute on function public.admin_like_counts() from anon;

-- ---------- 리서치 함수 ----------
create or replace function public.survey_is_open(sid bigint) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.surveys s where s.id = sid and s.is_published and jsonb_array_length(s.questions) > 0
    and case s.manual_status when 'forceOpen' then true when 'forceClosed' then false
        else (s.start_at is null or now() >= s.start_at) and (s.end_at is null or now() <= s.end_at) end)
$$;
-- 이 설문의 대상인지 (전체 또는 지정한 구분·조직지점·근무지점·영업소·직위·직책 값에 해당)
create or replace function public.survey_targets_me(sid bigint) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select case when coalesce(s.target->>'field', 'all') = 'all' or jsonb_array_length(coalesce(s.target->'values', '[]')) = 0 then true
    else exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'user' and
      (case s.target->>'field' when 'category' then p.category when 'org_branch' then p.org_branch when 'work_branch' then p.work_branch
         when 'sales_office' then p.sales_office when 'position' then p.position when 'duty' then p.duty end) in (select jsonb_array_elements_text(s.target->'values')))
    end from public.surveys s where s.id = sid), false)
$$;
-- 대상 선택용: 항목별 값과 회원 수 (리서치 권한자)
create or replace function public.admin_target_options() returns json
language sql stable security definer set search_path = public as $$
  select case when not public.has_perm('research') then null else json_build_object(
    'total', (select count(*) from public.profiles where role = 'user'),
    'category',     (select coalesce(json_agg(json_build_object('v', v, 'n', n) order by v), '[]') from (select category v, count(*) n from public.profiles where role = 'user' and coalesce(category, '') <> '' group by 1) t),
    'org_branch',   (select coalesce(json_agg(json_build_object('v', v, 'n', n) order by v), '[]') from (select org_branch v, count(*) n from public.profiles where role = 'user' and coalesce(org_branch, '') <> '' group by 1) t),
    'work_branch',  (select coalesce(json_agg(json_build_object('v', v, 'n', n) order by v), '[]') from (select work_branch v, count(*) n from public.profiles where role = 'user' and coalesce(work_branch, '') <> '' group by 1) t),
    'sales_office', (select coalesce(json_agg(json_build_object('v', v, 'n', n) order by v), '[]') from (select sales_office v, count(*) n from public.profiles where role = 'user' and coalesce(sales_office, '') <> '' group by 1) t),
    'position',     (select coalesce(json_agg(json_build_object('v', v, 'n', n) order by v), '[]') from (select position v, count(*) n from public.profiles where role = 'user' and coalesce(position, '') <> '' group by 1) t),
    'duty',         (select coalesce(json_agg(json_build_object('v', v, 'n', n) order by v), '[]') from (select duty v, count(*) n from public.profiles where role = 'user' and coalesce(duty, '') <> '' group by 1) t)) end
$$;
-- 추첨 후보: 응답자 닉네임 + 익명 토큰 (어떤 답을 했는지와 연결되지 않음)
create or replace function public.admin_survey_candidates(sid bigint) returns table(token text, nickname text)
language sql stable security definer set search_path = public as $$
  select md5(sid::text || ':' || r.user_id::text), p.nickname
  from public.survey_responses r join public.profiles p on p.id = r.user_id
  where public.has_perm('research') and r.survey_id = sid
  order by p.nickname
$$;
revoke execute on function public.admin_target_options() from anon;
revoke execute on function public.admin_survey_candidates(bigint) from anon;

-- 내가 참여한 설문 id 목록
create or replace function public.my_survey_ids() returns setof bigint
language sql stable security definer set search_path = public as $$
  select survey_id from public.survey_responses where user_id = auth.uid()
$$;
-- 당첨자 추첨 (응답자 중 무작위, 같은 설문 재추첨 시 덮어씀)
drop function if exists public.admin_draw_survey(bigint, int);
create or replace function public.admin_draw_survey(sid bigint, n int, exclude text[] default '{}') returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.has_perm('research') then raise exception '리서치 권한이 없습니다'; end if;
  if n < 1 then raise exception '당첨 인원은 1명 이상'; end if;
  insert into public.survey_draws(survey_id, winner_count, winner_ids, drawn_at)
  values (sid, n, coalesce((select array_agg(user_id) from (select user_id from public.survey_responses
           where survey_id = sid and user_id is not null and not (md5(sid::text || ':' || user_id::text) = any(coalesce(exclude, '{}')))
           order by random() limit n) t), '{}'), now())
  on conflict (survey_id) do update set winner_count = excluded.winner_count, winner_ids = excluded.winner_ids, drawn_at = excluded.drawn_at;
end $$;
-- 추첨 결과: 닉네임은 리서치 권한자에게, 실명·사번·소속은 최고관리자에게만
create or replace function public.admin_get_draw(sid bigint) returns json
language sql stable security definer set search_path = public as $$
  select case when not public.has_perm('research') then null else (
    select json_build_object('drawn_at', d.drawn_at, 'winner_count', d.winner_count, 'winners',
      coalesce((select json_agg(json_build_object('nickname', p.nickname,
                 'real_name', case when public.is_super() then p.real_name end,
                 'emp_no',    case when public.is_super() then p.emp_no end,
                 'dept',      case when public.is_super() then concat_ws(' ', p.org_branch, p.work_branch) end) order by u.ord)
                from unnest(d.winner_ids) with ordinality u(uid, ord) join public.profiles p on p.id = u.uid), '[]'::json))
    from public.survey_draws d where d.survey_id = sid) end
$$;
revoke execute on function public.admin_draw_survey(bigint, int, text[]) from anon;
revoke execute on function public.admin_get_draw(bigint) from anon;
revoke execute on function public.my_survey_ids() from anon;

-- ---------- 히든보이스: 일반 사용자에겐 '당첨 번호'는 숨기고 당첨 글만 공개 ----------
create or replace function public.get_hidden_info() returns json
language sql stable security definer set search_path = public as $$
  select json_build_object(
    'current', (
      select json_build_object(
        'month_key', e.month_key,
        'active', e.status = 'active',
        'total', coalesce(array_length(e.numbers, 1), 0),
        'found', (select count(*) from public.posts p
                   where p.month_key = e.month_key and p.month_seq = any(e.numbers)
                     and coalesce(p.author_role, 'user') <> 'admin'))
      from public.events e where e.month_key = public.kst_month()),
    'winners', coalesce((
      select json_agg(json_build_object(
               'post_id', p.id, 'month_key', p.month_key, 'month_seq', p.month_seq,
               'rank', (select count(*) from unnest(e.numbers) n where n <= p.month_seq)))
      from public.events e
      join public.posts p on p.month_key = e.month_key and p.month_seq = any(e.numbers)
      where coalesce(p.author_role, 'user') <> 'admin'), '[]'::json)
  )
$$;

