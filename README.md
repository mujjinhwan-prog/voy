# Voice of YUHAN (VOY™) 커뮤니티

사내 익명 커뮤니티 · GitHub Pages + Supabase

## 폴더 구성
| 경로 | 내용 |
|---|---|
| `index.html` | 회원 커뮤니티 (로그인 · 피드 · 글쓰기 · 랭킹 · 설문) |
| `admin/index.html` | 관리자 콘솔 (게시글·댓글·회원·관리자 계정·순위·이벤트·팝업·리서치·설정) |
| `manifest.webmanifest`, `sw.js`, `icons/` | 앱 설치(PWA) · 새 글 알림 |
| `yhdbt/` `yhwn/` `brp/` `yhfriend/` `soc/` | 오른쪽 바로가기 메뉴 페이지 |
| `setup/` | Supabase 설정 파일 (사이트 동작에는 필요 없음) |

## 처음 한 번 설정
1. Supabase SQL Editor에 `setup/voy_schema.sql` 전체를 붙여넣고 Run
2. Authentication → Sign In / Providers → **Allow new users to sign up 끄기**
3. `index.html`, `admin/index.html` 안의 `SUPABASE_URL`, `SUPABASE_ANON_KEY` 값 입력 (Project Settings → API)
4. 관리자 페이지 `admin/` 에서 **admin / admin1234** 로그인 → 비밀번호 즉시 변경
5. 회원 관리 → 엑셀 일괄 등록 (`setup/VOY_회원명단_양식.xlsx`)
6. (선택) 새 글 푸시 알림: `setup/supabase-function/README.txt` 참고

> ⚠️ VAPID 비밀키·PUSH_SECRET(keys.txt)은 이 저장소에 올리지 마세요. Supabase Edge Function Secrets에만 넣습니다.

## 익명 보호
작성자 계정·소속은 DB 뷰에서 **최고관리자(admin)에게만** 내려갑니다. 다른 회원·일반 관리자는 API로 직접 요청해도 볼 수 없습니다.
