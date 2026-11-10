-- VOY 패치: 링크 글 미리보기 사진 (2026-11-11)
-- Supabase → SQL Editor → New query 에 전체 붙여넣고 Run (여러 번 실행해도 안전)
alter table public.posts add column if not exists link_image text;   -- 첨부 링크의 대표 사진(미리보기) 주소
grant select (link_image) on public.posts to authenticated;

create or replace view public.posts_v as
  select p.id, p.board_id, p.title, p.body, p.link_url, p.images, p.pdf, p.is_pinned, p.month_key, p.month_seq,
         p.author_nickname, p.author_role, p.like_count, p.dislike_count, p.comment_count, p.created_at, p.updated_at,
         (p.user_id = auth.uid()) as mine,
         case when s.sup then p.user_id end as user_id,
         case when s.sup then coalesce(nullif(concat_ws(' ', pr.org_branch, pr.work_branch), ''), p.author_dept) end as author_dept,
         p.link_title, p.link_image
  from public.posts p cross join (select public.is_super() as sup) s
  left join public.profiles pr on s.sup and pr.id = p.user_id
  where auth.uid() is not null;
revoke all on public.posts_v from anon;
grant select on public.posts_v to authenticated;

notify pgrst, 'reload schema';
