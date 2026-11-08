-- =====================================================================
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
  ('score',       '{"like":3,"comment":1}'),
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
  if nick is null or not trusted or exists(select 1 from public.profiles where nickname = nick) then nick := public.gen_nickname(); end if;
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
declare r jsonb; em text; uid uuid; res jsonb := '[]'::jsonb; pw text; meta jsonb; prole text;
begin
  if not public.has_perm('members') then raise exception '회원 관리 권한이 없습니다'; end if;
  for r in select * from jsonb_array_elements(rows) loop
    em := lower(btrim(coalesce(r->>'email', '')));
    begin
      if em !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then
        res := res || jsonb_build_object('email', em, 'status', 'error', 'msg', '이메일 형식 오류'); continue;
      end if;
      select id into uid from auth.users where email = em;
      if uid is null then
        pw := coalesce(nullif(btrim(r->>'password'), ''), nullif(btrim(r->>'emp_no'), ''));
        if pw is null or char_length(pw) < 4 then
          res := res || jsonb_build_object('email', em, 'status', 'error', 'msg', '초기 비밀번호 또는 사번이 필요합니다'); continue;
        end if;
        meta := (r - 'password' - 'reset_pw') || jsonb_build_object('login_id', em, 'role', 'user', 'must_change_pw', true);
        perform public._create_auth_user(em, pw, meta);
        res := res || jsonb_build_object('email', em, 'status', 'created');
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
        if coalesce((r->>'reset_pw')::boolean, false) then
          pw := coalesce(nullif(btrim(r->>'password'), ''), (select emp_no from public.profiles where id = uid));
          update auth.users set encrypted_password = extensions.crypt(pw, extensions.gen_salt('bf')), updated_at = now() where id = uid;
          update public.profiles set must_change_pw = true where id = uid;
        end if;
        res := res || jsonb_build_object('email', em, 'status', 'updated');
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
  select coalesce((value->>'like')::int, 3), coalesce((value->>'comment')::int, 1) into lw, cw from public.settings where key = 'score';
  lw := coalesce(lw, 3); cw := coalesce(cw, 1);
  return query
  with pp as (select x.user_id uid, count(*) pn, coalesce(sum(x.like_count), 0) pl, coalesce(sum(x.comment_count), 0) pc
              from public.posts x where x.month_key = mk and coalesce(x.author_role, 'user') <> 'admin' and x.user_id is not null group by x.user_id),
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
