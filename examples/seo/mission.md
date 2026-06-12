**임무**: https://realty.daangn.com (당근부동산, 프로덕션) 의 SEO를 점진적으로 강화한다.

**발굴 방법**: page-type 1개를 골라 audit 한다. 최근 안 한 타입을 rotate (직전 audit 타입은 run-log 이슈 최신 코멘트로 추적).
- 도구: `claude-seo` 스킬(seo-audit / seo-technical / seo-schema / seo-sitemap / seo-content / seo-geo) 또는 seo 관련 스킬 활용.
- 라이브 페이지는 WebFetch(Googlebot 관점)로 확인, 구현 근거는 `client/apps/realty-web` 코드를 grep해서 잡는다.

**page-type 순환**:
① 지역 색인 (`/map/$city`, `/map/$city/$district`)
② 단지 상세 (`/complexes/$id`)
③ 매물 상세 (`/articles/$id`)
④ 학군/유치원 색인
⑤ 거래방식(직거래/중개) 색인
⑥ sitemap 커버리지

**좋은 work item** = 구체적이고 배포 가능한 SEO 갭: 누락된 structured data(JSON-LD)/canonical/noindex, 크롤러 internal link 부재(onClick→`<a href>`), heading 계층(h1/h2) 부재·역전, thin content, sitemap 누락 등.

**human-gate로 표시할 것**: BE 스키마 변경이 필요하거나, noindex 페이지로의 투기성 링크 등 사람 판단이 필요한 것 — 구현하지 말고 본문에 "human-gate" 명시.

작업 완료되면 /gbase:go 스킬 사용. 최대한 interactive 없이 자동으로 돌고, 꼭 필요한 경우만 사람 개입 요청.
