# Cosmetics E-Commerce Behavior Analysis

## 프로젝트 목적

코스메틱 이커머스 이벤트 로그에서 `view → cart → purchase` 전환 흐름을 정의하고, 이탈이 집중되는 구간과 상품군을 파악해 개선 우선순위와 후속 검증안을 제안한다.

- 데이터 출처: https://www.kaggle.com/datasets/mkechinov/ecommerce-events-history-in-cosmetics-shop
- 현재 단계: 02·03 완결(mart_session 4,499,479행, raw 대조 검증 a-c 통과, 심화 EDA 실행·결론 작성). 05 구매 여정은 조건부 유지 — 04 완성 후 04에 없는 독립 인사이트 2개 미만이면 04에 흡수. 다음: 04 퍼널 — 직행 세션(선행 view 없는 cart/purchase 시작 세션) 처리 방침이 첫 설계 결정.
- 분석 결과가 나오기 전에는 수치·결론·성과를 미리 작성하지 않는다.

## 환경

### Python / Jupyter

- 가상환경: conda `ml_env` (`/opt/anaconda3/envs/ml_env`)
- Python: 3.10.19 (`/opt/anaconda3/envs/ml_env/bin/python`)
- Jupyter 커널: `ml_env` (등록 완료). 모든 노트북 kernelspec은 `ml_env`로 고정한다.
- 코드 실행·패키지 검증은 `ml_env`에서만 한다. base·system·타 환경에 설치하지 않는다.
- `ml_env`를 삭제·재생성·이름 변경하지 않는다.
- 필요한 패키지가 없으면 임의 설치하지 말고 패키지명·목적·설치 명령을 먼저 보고한다.

### DB

- MySQL 8.0.34 Community Server가 `/usr/local/mysql`에 설치되어 있다. 새로 설치하지 않는다.
- 연결 라이브러리: SQLAlchemy 2.0 + PyMySQL (`ml_env`에 설치됨).
- 기준 프로젝트와 분리된 전용 DB를 사용하고, 기존 DB·테이블은 수정·삭제하지 않는다.
- 접속 정보는 `.env`로 관리하고 Git에서 제외한다.

다음 저장소를 구조·문체·SQL·노트북 작성 방식의 기준으로 사용한다.
(로컬에서는 이 저장소와 같은 상위 폴더에 위치)

- 이커머스: [dacon_e_commerce](https://github.com/kth530/dacon_e_commerce)
- 패션 플랫폼: [fashion_platform_analysis](https://github.com/kth530/fashion_platform_analysis)

기준 프로젝트는 읽기 전용이다. 사용자가 명시적으로 요청하지 않는 한 어떤 파일도 수정하지 않는다.

## 작업 시작 순서

1. 기준 프로젝트의 `CLAUDE.md`, README, 노트북, SQL, docs, 시각화 방식을 확인한다.
2. 두 프로젝트의 공통 규칙과 프로젝트 고유 규칙을 구분한다.
3. 코스메틱 데이터 스키마·기간·이벤트 품질을 실제 파일로 검증한다.
4. 폴더 구조, 노트북 번호, SQL 파일, 핵심 지표 정의를 제안한다.
5. 사용자 승인 후 분석 파일을 생성한다.

설계 승인 전에는 노트북·SQL·README를 임의로 대량 생성하지 않는다. 선택이 필요한 규칙은 임의로 결정하지 말고 차이와 권장안을 먼저 보고한다.

## 편집 원칙

- 사용자가 직접 수정한 셀과 문서는 명시적 요청 없이 변경하지 않는다.
- 원본 데이터는 수정하지 않고 별도 경로에 보존한다.
- 기존 변경을 덮어쓰거나 관련 없는 파일을 정리하지 않는다.
- 마크다운 수치는 노트북의 실제 실행 결과와 일치시킨다.
- 계산되지 않은 수치, 목표, 매출 효과를 임의로 만들지 않는다.
- 관찰 데이터의 연관성을 인과관계로 표현하지 않는다.
- 사용자·세션·이벤트 단위를 혼용하지 않고 모든 지표에 분모와 관측 기간을 명시한다.
- 동일 지표를 SQL과 Python에서 서로 다르게 정의하지 않는다.
- 하드코딩된 사용자 절대경로, 비밀번호, API 키를 코드에 넣지 않는다.
- 대용량 원본·중간 데이터와 `.env`는 Git에서 제외한다.

## 분석 범위

- 데이터 구조 및 품질 점검
- 이벤트 중복·누락·비정상 순서 확인
- 사용자 및 세션 기준 퍼널
- 카테고리·브랜드·가격대별 전환 차이
- 구매 전 행동 순서와 반복 방문
- 핵심 이탈 지점의 개선 우선순위
- 근거가 가장 강한 개선안 하나의 후속 A/B 테스트 설계

A/B 테스트는 분석마다 붙이지 않는다. 실험·노출 로그가 없으면 실행 성과가 아니라 향후 검증 설계로 명시한다.

## Rules

작업 대상 파일에 따라 다음 규칙 문서를 적용한다.
(규칙 문서는 `.claude/rules/`에 포함되어 있다.)

- 노트북 작성: `.claude/rules/notebook-workflow.md`
- SQL 작성: `.claude/rules/sql-conventions.md`
- 지표·통계·시각화: `.claude/rules/analysis-conventions.md`
- 마크다운·인사이트: `.claude/rules/markdown-conventions.md`

## 확장 기준

- 반복 가능한 배포·검증 절차가 생기기 전에는 Skill을 만들지 않는다.
- 독립적으로 격리할 작업이 생기기 전에는 Subagent를 추가하지 않는다.
- 반드시 막아야 할 파일 변경이나 명령이 구체화되기 전에는 Hook을 추가하지 않는다.
- 단순한 문체 변경만을 위해 Output style 또는 System prompt를 추가하지 않는다.
