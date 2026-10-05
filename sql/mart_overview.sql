-- 포트폴리오 마트 정의와 검산 SQL. notebooks/03_mart_overview.ipynb 대응.
-- create_* 블록은 기존 02의 DROP/CREATE를 포함한 기록이다. 이번 작업에서 실행하지 않는다.
-- 현재 저장된 마트를 재생성하려고 이 파일 전체를 실행하면 기존 테이블을 교체하므로 주의한다.
-- 전처리 규칙: user_session 비결측·단일 user_id·지속시간 <= 86400초,
-- 이벤트 카운트는 price >= 0, 순차 행동은 strict event_time < event_time.
-- mart_user_product_session도 실제 grain은 user_session × product_id 1행이다.

-- ==================================================
-- 1. mart_session 생성: 유효 세션 1행
-- ==================================================


-- name: create_mart_session | 기존 세션 마트 생성 DDL
-- 출처: sql/02_preprocessing_mart.sql, 쿼리 본문 재사용.
-- 목적/연결: 노트북 §2 마트 설계.
-- grain: user_session. 분모: 유효 세션.
-- 처리 방침의 단일 원천은 docs/metrics.md. 이 스크립트가 그 방침을 집행한다.
-- 세션 단위 1행. 분석 노트북(03 이후)은 events가 아니라 이 마트만 소비한다.
-- 순차 플래그는 strict(event_time < event_time) 기준이며, 상품 동일 조건은 적용하지 않는다.
SET SESSION group_concat_max_len = 1000000;

DROP TEMPORARY TABLE IF EXISTS tmp_mart_session_base;
DROP TEMPORARY TABLE IF EXISTS tmp_session_cart;
DROP TEMPORARY TABLE IF EXISTS tmp_session_purchase;
DROP TABLE IF EXISTS mart_session;

CREATE TEMPORARY TABLE tmp_mart_session_base ENGINE=InnoDB AS
SELECT
    user_session,
    MIN(user_id) AS user_id,                                 -- 단일 user_id는 HAVING로 보장되므로 MIN=해당 user
    MIN(event_time) AS session_start,
    MAX(event_time) AS session_end,
    TIMESTAMPDIFF(SECOND, MIN(event_time), MAX(event_time)) AS duration_sec,
    -- metrics.md 방침(이벤트 카운트): price < 0 제외, price = 0 포함
    SUM(price >= 0) AS total_events,
    SUM(event_type = 'view' AND price >= 0) AS views,
    SUM(event_type = 'cart' AND price >= 0) AS carts,
    SUM(event_type = 'remove_from_cart' AND price >= 0) AS removes,
    SUM(event_type = 'purchase' AND price >= 0) AS purchases,
    -- 진입·이탈 유형: 세션 내 시간순 첫/마지막 이벤트 (GROUP_CONCAT 첫 토큰, 절단돼도 첫 토큰은 보존)
    SUBSTRING_INDEX(GROUP_CONCAT(event_type ORDER BY event_time ASC SEPARATOR ','), ',', 1) AS first_event_type,
    SUBSTRING_INDEX(GROUP_CONCAT(event_type ORDER BY event_time DESC SEPARATOR ','), ',', 1) AS last_event_type,
    -- metrics.md 방침(revenue): event_type='purchase' AND price > 0 의 price 합 (price = 0 제외)
    SUM(IF(event_type = 'purchase' AND price > 0, price, 0)) AS revenue,
    -- strict 순차 판별의 시작점. 최종 마트에는 시각을 저장하지 않고 플래그만 남긴다.
    MIN(CASE WHEN event_type = 'view' AND price >= 0 THEN event_time END) AS first_view_at
FROM events
WHERE user_session IS NOT NULL                               -- metrics.md 방침: user_session NOT NULL (WHERE)
GROUP BY user_session
HAVING COUNT(DISTINCT user_id) = 1                           -- metrics.md 방침: 세션당 단일 user_id (HAVING)
   AND TIMESTAMPDIFF(SECOND, MIN(event_time), MAX(event_time)) <= 86400;  -- metrics.md 방침: 지속시간 ≤ 1일 (HAVING)

ALTER TABLE tmp_mart_session_base ADD PRIMARY KEY (user_session);

CREATE TEMPORARY TABLE tmp_session_cart ENGINE=InnoDB AS
SELECT
    e.user_session,
    MIN(e.event_time) AS first_cart_after_view_at
FROM events e
JOIN tmp_mart_session_base b ON e.user_session = b.user_session
WHERE e.event_type = 'cart'
  AND e.price >= 0
  AND e.event_time > b.first_view_at                         -- metrics.md 방침: strict(<), 동일 시각 제외
GROUP BY e.user_session;

ALTER TABLE tmp_session_cart ADD PRIMARY KEY (user_session);

CREATE TEMPORARY TABLE tmp_session_purchase ENGINE=InnoDB AS
SELECT
    e.user_session,
    MIN(e.event_time) AS first_purchase_after_view_cart_at
FROM events e
JOIN tmp_session_cart c ON e.user_session = c.user_session
WHERE e.event_type = 'purchase'
  AND e.price >= 0
  AND e.event_time > c.first_cart_after_view_at              -- metrics.md 방침: strict(<), 동일 시각 제외
GROUP BY e.user_session;

ALTER TABLE tmp_session_purchase ADD PRIMARY KEY (user_session);

CREATE TABLE mart_session AS
SELECT
    b.user_session,
    b.user_id,
    b.session_start,
    b.session_end,
    b.duration_sec,
    b.total_events,
    b.views,
    b.carts,
    b.removes,
    b.purchases,
    b.first_event_type,
    b.last_event_type,
    b.revenue,
    IF(c.user_session IS NOT NULL, 1, 0) AS has_cart_after_view,
    IF(p.user_session IS NOT NULL, 1, 0) AS has_purchase_after_view_cart
FROM tmp_mart_session_base b
LEFT JOIN tmp_session_cart c ON b.user_session = c.user_session
LEFT JOIN tmp_session_purchase p ON b.user_session = p.user_session;

ALTER TABLE mart_session ADD PRIMARY KEY (user_session);

CREATE INDEX idx_mart_user ON mart_session (user_id);

CREATE INDEX idx_mart_start ON mart_session (session_start);

DROP TEMPORARY TABLE tmp_session_purchase;
DROP TEMPORARY TABLE tmp_session_cart;
DROP TEMPORARY TABLE tmp_mart_session_base;

-- ==================================================
-- 2. mart_session_product 생성: 유효 세션×상품 1행
-- ==================================================


-- name: create_mart_session_product | 기존 동일 상품 세션 마트 생성 DDL
-- 출처: sql/02_preprocessing_mart.sql, 쿼리 본문 재사용.
-- 목적/연결: 노트북 §2 마트 설계.
-- grain: user_session × product_id. 분모: 조회·담기·구매 중 하나가 있는 유효 세션×상품.
-- 처리 방침의 단일 원천은 docs/metrics.md. 이 스크립트가 그 방침을 집행한다.
-- 세션·상품 단위 1행. 동일 상품 순차 퍼널은 이 마트를 소비한다.
-- 순차 플래그는 strict(event_time < event_time) 기준이며, 세션 경계를 넘지 않는다.
DROP TEMPORARY TABLE IF EXISTS tmp_mart_session_product_base;
DROP TEMPORARY TABLE IF EXISTS tmp_session_product_cart;
DROP TEMPORARY TABLE IF EXISTS tmp_session_product_purchase;
DROP TABLE IF EXISTS mart_session_product;

CREATE TEMPORARY TABLE tmp_mart_session_product_base ENGINE=InnoDB AS
SELECT
    e.user_session,
    e.product_id,
    SUM(e.event_type = 'view') AS views,
    SUM(e.event_type = 'cart') AS carts,
    SUM(e.event_type = 'purchase') AS purchases,
    -- strict 순차 판별의 시작점. 최종 마트에는 시각을 저장하지 않고 플래그만 남긴다.
    MIN(CASE WHEN e.event_type = 'view' THEN e.event_time END) AS first_view_at
FROM events e
JOIN mart_session m ON e.user_session = m.user_session
WHERE e.price >= 0                                           -- metrics.md 방침: price < 0 제외, price = 0 포함
  AND e.event_type IN ('view', 'cart', 'purchase')
  AND e.product_id IS NOT NULL
GROUP BY e.user_session, e.product_id;

ALTER TABLE tmp_mart_session_product_base ADD PRIMARY KEY (user_session, product_id);

CREATE TEMPORARY TABLE tmp_session_product_cart ENGINE=InnoDB AS
SELECT
    e.user_session,
    e.product_id,
    MIN(e.event_time) AS first_cart_after_view_at
FROM events e
JOIN tmp_mart_session_product_base b
  ON e.user_session = b.user_session
 AND e.product_id = b.product_id
WHERE e.event_type = 'cart'
  AND e.price >= 0
  AND e.event_time > b.first_view_at                         -- metrics.md 방침: strict(<), 동일 시각 제외
GROUP BY e.user_session, e.product_id;

ALTER TABLE tmp_session_product_cart ADD PRIMARY KEY (user_session, product_id);

CREATE TEMPORARY TABLE tmp_session_product_purchase ENGINE=InnoDB AS
SELECT
    e.user_session,
    e.product_id,
    MIN(e.event_time) AS first_purchase_after_view_cart_at
FROM events e
JOIN tmp_session_product_cart c
  ON e.user_session = c.user_session
 AND e.product_id = c.product_id
WHERE e.event_type = 'purchase'
  AND e.price >= 0
  AND e.event_time > c.first_cart_after_view_at              -- metrics.md 방침: strict(<), 동일 시각 제외
GROUP BY e.user_session, e.product_id;

ALTER TABLE tmp_session_product_purchase ADD PRIMARY KEY (user_session, product_id);

CREATE TABLE mart_session_product AS
SELECT
    b.user_session,
    b.product_id,
    b.views,
    b.carts,
    b.purchases,
    IF(c.user_session IS NOT NULL, 1, 0) AS has_cart_after_view,
    IF(p.user_session IS NOT NULL, 1, 0) AS has_purchase_after_view_cart
FROM tmp_mart_session_product_base b
LEFT JOIN tmp_session_product_cart c
  ON b.user_session = c.user_session
 AND b.product_id = c.product_id
LEFT JOIN tmp_session_product_purchase p
  ON b.user_session = p.user_session
 AND b.product_id = p.product_id;

ALTER TABLE mart_session_product ADD PRIMARY KEY (user_session, product_id);

CREATE INDEX idx_msp_product ON mart_session_product (product_id);

DROP TEMPORARY TABLE tmp_session_product_purchase;
DROP TEMPORARY TABLE tmp_session_product_cart;
DROP TEMPORARY TABLE tmp_mart_session_product_base;

-- ==================================================
-- 3. mart_user_product_session 생성: 실제 grain은 유효 세션×상품 1행
-- ==================================================


-- name: create_mart_user_product_session | 기존 구매 전 행동 시각 보존 마트 DDL
-- 출처: sql/02_preprocessing_mart.sql, 쿼리 본문 재사용.
-- 목적/연결: 노트북 §2 마트 설계.
-- grain: user_session × product_id; user_id는 연결 속성. 분모: remove-only 포함 유효 세션×상품.
-- 처리 방침의 단일 원천은 docs/metrics.md. 이 스크립트가 그 방침을 집행한다.
-- 분석 단위는 유효 세션·상품(user_session × product_id) 1행이다.
-- view·cart·remove·purchase의 최초·최종 시각을 보존해 05에서 raw를 다시 조회하지 않는다.
-- 구매 전 행동은 strict(event_time < first_purchase_at) 기준이며 동일 시각은 제외한다.
DROP TEMPORARY TABLE IF EXISTS tmp_user_product_session_base;
DROP TEMPORARY TABLE IF EXISTS tmp_user_product_before_purchase;
DROP TABLE IF EXISTS mart_user_product_session;

CREATE TEMPORARY TABLE tmp_user_product_session_base ENGINE=InnoDB AS
SELECT
    e.user_session,
    e.product_id,
    m.user_id,
    m.session_start,
    m.session_end,
    SUM(e.event_type = 'view') AS views,
    SUM(e.event_type = 'cart') AS carts,
    SUM(e.event_type = 'remove_from_cart') AS removes,
    SUM(e.event_type = 'purchase') AS purchases,
    MIN(CASE WHEN e.event_type = 'view' THEN e.event_time END) AS first_view_at,
    MAX(CASE WHEN e.event_type = 'view' THEN e.event_time END) AS last_view_at,
    MIN(CASE WHEN e.event_type = 'cart' THEN e.event_time END) AS first_cart_at,
    MAX(CASE WHEN e.event_type = 'cart' THEN e.event_time END) AS last_cart_at,
    MIN(CASE WHEN e.event_type = 'remove_from_cart' THEN e.event_time END) AS first_remove_at,
    MAX(CASE WHEN e.event_type = 'remove_from_cart' THEN e.event_time END) AS last_remove_at,
    MIN(CASE WHEN e.event_type = 'purchase' THEN e.event_time END) AS first_purchase_at,
    MAX(CASE WHEN e.event_type = 'purchase' THEN e.event_time END) AS last_purchase_at,
    -- metrics.md 방침(revenue): purchase·price>0만 합산한다.
    SUM(IF(e.event_type = 'purchase' AND e.price > 0, e.price, 0)) AS revenue
FROM events e
JOIN mart_session m ON e.user_session = m.user_session
WHERE e.price >= 0                                           -- metrics.md 방침: price<0 제외, price=0 포함
  AND e.event_type IN ('view', 'cart', 'remove_from_cart', 'purchase')
  AND e.product_id IS NOT NULL
GROUP BY
    e.user_session,
    e.product_id,
    m.user_id,
    m.session_start,
    m.session_end;

ALTER TABLE tmp_user_product_session_base
    ADD PRIMARY KEY (user_session, product_id);

CREATE TEMPORARY TABLE tmp_user_product_before_purchase ENGINE=InnoDB AS
SELECT
    e.user_session,
    e.product_id,
    MAX(CASE
        WHEN e.event_type = 'view' AND e.event_time < b.first_purchase_at
        THEN e.event_time
    END) AS last_view_before_first_purchase_at,
    MAX(CASE
        WHEN e.event_type = 'cart' AND e.event_time < b.first_purchase_at
        THEN e.event_time
    END) AS last_cart_before_first_purchase_at,
    MAX(CASE
        WHEN e.event_type = 'remove_from_cart' AND e.event_time < b.first_purchase_at
        THEN e.event_time
    END) AS last_remove_before_first_purchase_at
FROM events e
JOIN tmp_user_product_session_base b
  ON e.user_session = b.user_session
 AND e.product_id = b.product_id
WHERE b.first_purchase_at IS NOT NULL
  AND e.price >= 0
  AND e.event_type IN ('view', 'cart', 'remove_from_cart')
GROUP BY e.user_session, e.product_id;

ALTER TABLE tmp_user_product_before_purchase
    ADD PRIMARY KEY (user_session, product_id);

CREATE TABLE mart_user_product_session AS
SELECT
    b.user_session,
    b.product_id,
    b.user_id,
    b.session_start,
    b.session_end,
    b.views,
    b.carts,
    b.removes,
    b.purchases,
    b.first_view_at,
    b.last_view_at,
    b.first_cart_at,
    b.last_cart_at,
    b.first_remove_at,
    b.last_remove_at,
    b.first_purchase_at,
    b.last_purchase_at,
    a.last_view_before_first_purchase_at,
    a.last_cart_before_first_purchase_at,
    a.last_remove_before_first_purchase_at,
    b.revenue,
    IF(COALESCE(sp.has_cart_after_view, 0) = 1, 1, 0) AS has_cart_after_view,
    IF(COALESCE(sp.has_purchase_after_view_cart, 0) = 1, 1, 0)
        AS has_purchase_after_view_cart,
    IF(
        b.first_view_at < a.last_cart_before_first_purchase_at,
        1,
        0
    ) AS has_view_cart_before_first_purchase
FROM tmp_user_product_session_base b
LEFT JOIN tmp_user_product_before_purchase a
  ON b.user_session = a.user_session
 AND b.product_id = a.product_id
LEFT JOIN mart_session_product sp
  ON b.user_session = sp.user_session
 AND b.product_id = sp.product_id;

ALTER TABLE mart_user_product_session
    ADD PRIMARY KEY (user_session, product_id);

CREATE INDEX idx_mups_user_product_start
    ON mart_user_product_session (user_id, product_id, session_start, user_session);

CREATE INDEX idx_mups_product_start
    ON mart_user_product_session (product_id, session_start);

CREATE INDEX idx_mups_first_purchase
    ON mart_user_product_session (first_purchase_at);

DROP TEMPORARY TABLE tmp_user_product_before_purchase;
DROP TEMPORARY TABLE tmp_user_product_session_base;

-- ==================================================
-- 4. 마트 행 수·grain 및 기본 논리 검산 (읽기 전용)
-- ==================================================


-- name: mart_inventory | 세 마트 저장 행 수
-- 출처: sql/03_mart_eda.sql, 쿼리 본문 재사용.
-- 목적/연결: 노트북 §2 마트 표.
-- grain: 마트별 1행. 분모: 각 마트 전체 행.
-- 분석 단위: mart_session은 유효 방문, 나머지는 유효 방문 × 상품
-- 분모: 각 마트에 저장된 전체 행
-- 하류 사용: mart_session·mart_session_product는 04, mart_user_product_session은 05
SELECT
    'mart_session' AS 마트,
    COUNT(*) AS 실제_행수
FROM mart_session
UNION ALL
SELECT
    'mart_session_product' AS 마트,
    COUNT(*) AS 실제_행수
FROM mart_session_product
UNION ALL
SELECT
    'mart_user_product_session' AS 마트,
    COUNT(*) AS 실제_행수
FROM mart_user_product_session

-- name: mart_session_reconciliation | 행 수·복합키 중복·기본 플래그 확인
-- 출처: sql/02_preprocessing_mart.sql, 쿼리 본문 재사용.
-- 목적/연결: 노트북 §2 grain 검산.
-- grain: user_session. 분모: mart_session 전체 행.
SELECT
    COUNT(*) AS 마트_행수,
    COUNT(*) - COUNT(DISTINCT user_session) AS 기본키_중복,
    SUM(views) AS 마트_views,
    SUM(carts) AS 마트_carts,
    SUM(removes) AS 마트_removes,
    SUM(purchases) AS 마트_purchases,
    SUM(revenue) AS 마트_revenue,
    SUM(views > 0) AS view_units,
    SUM(has_cart_after_view) AS strict_stage2,
    SUM(has_purchase_after_view_cart) AS strict_stage3,
    SUM(has_cart_after_view NOT IN (0, 1)) AS invalid_cart_flag,
    SUM(has_purchase_after_view_cart NOT IN (0, 1)) AS invalid_purchase_flag,
    SUM(has_cart_after_view = 1 AND views = 0) AS cart_without_view,
    SUM(has_purchase_after_view_cart = 1 AND has_cart_after_view = 0) AS purchase_without_cart,
    SUM(has_purchase_after_view_cart = 1 AND purchases = 0) AS purchase_without_event
FROM mart_session

-- name: mart_session_product_reconciliation | 행 수·복합키 중복·기본 플래그 확인
-- 출처: sql/02_preprocessing_mart.sql, 쿼리 본문 재사용.
-- 목적/연결: 노트북 §2 grain 검산.
-- grain: user_session × product_id. 분모: mart_session_product 전체 행.
SELECT
    COUNT(*) AS 마트_행수,
    COUNT(*) - COUNT(DISTINCT user_session, product_id) AS 복합키_중복,
    SUM(views) AS 마트_views,
    SUM(carts) AS 마트_carts,
    SUM(purchases) AS 마트_purchases,
    SUM(views > 0) AS view_units,
    SUM(has_cart_after_view) AS strict_stage2,
    SUM(has_purchase_after_view_cart) AS strict_stage3,
    SUM(has_cart_after_view NOT IN (0, 1)) AS invalid_cart_flag,
    SUM(has_purchase_after_view_cart NOT IN (0, 1)) AS invalid_purchase_flag,
    SUM(has_cart_after_view = 1 AND views = 0) AS cart_without_view,
    SUM(has_purchase_after_view_cart = 1 AND has_cart_after_view = 0) AS purchase_without_cart,
    SUM(has_purchase_after_view_cart = 1 AND purchases = 0) AS purchase_without_event
FROM mart_session_product

-- name: mart_user_product_session_reconciliation | 행 수·복합키 중복·기본 플래그 확인
-- 출처: sql/02_preprocessing_mart.sql, 쿼리 본문 재사용.
-- 목적/연결: 노트북 §2 grain 검산.
-- grain: user_session × product_id. 분모: mart_user_product_session 전체 행.
SELECT
    COUNT(*) AS 마트_행수,
    COUNT(*) - COUNT(DISTINCT user_session, product_id) AS 복합키_중복,
    SUM(purchases > 0) AS 마트_구매행수,
    SUM(views) AS 마트_views,
    SUM(carts) AS 마트_carts,
    SUM(removes) AS 마트_removes,
    SUM(purchases) AS 마트_purchases,
    SUM(revenue) AS 마트_revenue,
    SUM((views = 0 AND (first_view_at IS NOT NULL OR last_view_at IS NOT NULL))
        OR (views > 0 AND (first_view_at IS NULL OR last_view_at IS NULL))) AS view_시각오류,
    SUM((carts = 0 AND (first_cart_at IS NOT NULL OR last_cart_at IS NOT NULL))
        OR (carts > 0 AND (first_cart_at IS NULL OR last_cart_at IS NULL))) AS cart_시각오류,
    SUM((removes = 0 AND (first_remove_at IS NOT NULL OR last_remove_at IS NOT NULL))
        OR (removes > 0 AND (first_remove_at IS NULL OR last_remove_at IS NULL))) AS remove_시각오류,
    SUM((purchases = 0 AND (first_purchase_at IS NOT NULL OR last_purchase_at IS NOT NULL))
        OR (purchases > 0 AND (first_purchase_at IS NULL OR last_purchase_at IS NULL))) AS purchase_시각오류,
    SUM(first_view_at > last_view_at OR first_cart_at > last_cart_at
        OR first_remove_at > last_remove_at OR first_purchase_at > last_purchase_at) AS 최초최종_역전,
    SUM(last_view_before_first_purchase_at >= first_purchase_at
        OR last_cart_before_first_purchase_at >= first_purchase_at
        OR last_remove_before_first_purchase_at >= first_purchase_at) AS 구매전시각_오류,
    SUM(has_cart_after_view NOT IN (0, 1)
        OR has_purchase_after_view_cart NOT IN (0, 1)
        OR has_view_cart_before_first_purchase NOT IN (0, 1)) AS 플래그값_오류,
    SUM(has_purchase_after_view_cart = 1 AND has_cart_after_view = 0) AS 순차포함관계_오류,
    SUM(has_view_cart_before_first_purchase = 1
        AND (first_view_at IS NULL
             OR last_cart_before_first_purchase_at IS NULL
             OR first_purchase_at IS NULL)) AS 최초구매경로_오류
FROM mart_user_product_session

-- name: mart_schema_contract | 세 마트 PK·컬럼·인덱스 계약
-- 출처: sql/02_preprocessing_mart.sql, 쿼리 본문 재사용.
-- 목적/연결: 노트북 §2 실제 grain 보조 검증.
-- grain: information_schema 컬럼 또는 인덱스 1행. 분모: 현재 데이터베이스의 세 마트 스키마.
SELECT
    'COLUMN' AS contract_type,
    table_name AS mart_table,
    column_name AS object_name,
    ordinal_position AS contract_position,
    column_name AS contract_column
FROM information_schema.columns
WHERE table_schema = DATABASE()
  AND table_name IN (
      'mart_session',
      'mart_session_product',
      'mart_user_product_session'
  )
UNION ALL
SELECT
    'INDEX' AS contract_type,
    table_name AS mart_table,
    index_name AS object_name,
    seq_in_index AS contract_position,
    column_name AS contract_column
FROM information_schema.statistics
WHERE table_schema = DATABASE()
  AND table_name IN (
      'mart_session',
      'mart_session_product',
      'mart_user_product_session'
  )
ORDER BY mart_table, contract_type, object_name, contract_position
