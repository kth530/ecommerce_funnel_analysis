-- 포트폴리오 데이터 오버뷰 SQL. notebooks/02_data_overview.ipynb 대응.
-- 기존 저장 결과를 인용하므로 이번 개정에서 아래 원본 집계를 재실행하지 않는다.
-- 원본 00/01의 정의를 바꾸지 않았고 mart/ETL 생성문은 없다.

-- ==================================================
-- 1. 원본 규모·기간·기본 품질
-- ==================================================


-- name: base_scalars | 전체 이벤트 규모·기간·결측·가격 부호
-- 출처: sql/01_raw_eda.sql, 쿼리 본문 재사용.
-- 목적/연결: 노트북 §1 데이터 오버뷰.
-- grain: 원본 이벤트 1행. 분모: events 전체 행.
-- 분석 단위: 이벤트 1행. 분모: events 전체 행. 관측 기간은 MIN/MAX(event_time)으로 계산한다.
SELECT
    COUNT(*) AS 행수,
    MIN(event_time) AS 시작,
    MAX(event_time) AS 종료,
    SUM(category_code IS NULL) AS null_category_code,
    SUM(brand IS NULL) AS null_brand,
    SUM(user_session IS NULL) AS null_user_session,
    SUM(category_id IS NULL) AS null_category_id,
    SUM(price IS NULL) AS null_price,
    SUM(price < 0) AS price_음수,
    SUM(price = 0) AS price_0원,
    SUM(price > 0) AS price_정상
FROM events

-- ==================================================
-- 2. 이벤트 유형 분포
-- ==================================================


-- name: daily_trend | 검증된 일자×유형 캐시에서 이벤트 유형 구성 도출
-- 출처: sql/01_raw_eda.sql, 쿼리 본문 재사용.
-- 목적/연결: 노트북 §1. 일자별 행을 event_type으로 합해 유형별 건수를 표시한다.
-- grain: 일자 × event_type. 분모: 해당 일자·유형의 events 행.
-- 분석 단위: 일자 × event_type. 분모: 해당 일자·유형의 events 행.
-- 고유 사용자 수는 수집 이상 판정에 사용되지 않아 반복 DISTINCT 집계에서 제외한다.
SELECT
    DATE(event_time) AS event_date,
    event_type,
    COUNT(*) AS event_count,
    SUM(price <= 0) AS zero_neg_count
FROM events
GROUP BY DATE(event_time), event_type
ORDER BY event_date, event_type

-- ==================================================
-- 3. 식별자 수
-- ==================================================


-- name: distinct_users | 전체 기간 고유 사용자
-- 출처: sql/01_raw_eda.sql, 쿼리 본문 재사용.
-- 목적/연결: 노트북 §1 데이터 오버뷰.
-- grain: user_id. 분모: events에서 관찰된 사용자.
-- 분석 단위: 사용자. 분모: events 전체 행에서 식별된 user_id. idx_user_time 선두 컬럼을 사용한다.
SELECT COUNT(DISTINCT user_id) AS 고유_사용자
FROM events

-- name: overview_raw_product_count | 전체 기간 고유 상품
-- 출처: final_analysis/03_overview.sql, 쿼리 본문 재사용.
-- 목적/연결: 노트북 §1 데이터 오버뷰.
-- grain: product_id. 분모: events에서 관찰된 상품.
SELECT COUNT(DISTINCT product_id) AS raw_product_count
FROM events

-- name: distinct_sessions | 전체 기간 비결측 고유 세션
-- 출처: sql/01_raw_eda.sql, 쿼리 본문 재사용.
-- 목적/연결: 노트북 §1 데이터 오버뷰.
-- grain: user_session. 분모: user_session 비결측 events.
-- 분석 단위: 세션. 분모: user_session IS NOT NULL인 events. idx_repeat_events 선두 컬럼을 사용한다.
SELECT COUNT(DISTINCT user_session) AS 고유_세션
FROM events

-- ==================================================
-- 4. 저장 스키마 확인
-- ==================================================


-- name: overview_event_columns | 원본 events 컬럼명·MySQL 저장 타입 확인
-- 출처: notebooks/00_elt_pipeline.ipynb의 events DDL을 메타데이터로 확인하는 최소 조회.
-- 목적/연결: 노트북 §1의 9열·주요 dtype 표. grain: 컬럼 1행. 분모: 해당 DB의 events 컬럼.
SELECT
    column_name,
    data_type,
    column_type,
    is_nullable,
    ordinal_position
FROM information_schema.columns
WHERE table_schema = DATABASE()
  AND table_name = 'events'
ORDER BY ordinal_position
