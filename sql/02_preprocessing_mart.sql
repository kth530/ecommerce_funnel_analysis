-- 02 전처리 집행·분석 마트 구축·검증
-- name: create_mart_session | mart_session 생성 (docs/metrics.md 방침 집행)
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

-- name: raw_valid_count | 검증a: raw(events)에서 유효 세션 조건으로 직접 센 세션 수
SELECT COUNT(*) AS n
FROM (
    SELECT user_session
    FROM events
    WHERE user_session IS NOT NULL
    GROUP BY user_session
    HAVING COUNT(DISTINCT user_id) = 1
       AND TIMESTAMPDIFF(SECOND, MIN(event_time), MAX(event_time)) <= 86400
) v

-- name: raw_type_counts | 검증b: raw에서 유효 세션 범위·price>=0 유형별 건수
SELECT
    e.event_type,
    COUNT(*) AS 건수
FROM events e
JOIN mart_session m ON e.user_session = m.user_session
WHERE e.price >= 0
GROUP BY e.event_type
ORDER BY e.event_type

-- name: raw_revenue | 검증c: raw에서 유효 세션 범위·purchase·price>0 revenue 합
SELECT SUM(e.price) AS revenue
FROM events e
JOIN mart_session m ON e.user_session = m.user_session
WHERE e.event_type = 'purchase'
   AND e.price > 0

-- name: raw_ordered_counts | 검증d: raw에서 strict·inclusive 순차 도달 독립 계산
WITH bounds AS (
    SELECT
        e.user_session,
        MIN(CASE WHEN e.event_type = 'view' THEN e.event_time END) AS first_view_at,
        MAX(CASE WHEN e.event_type = 'cart' THEN e.event_time END) AS last_cart_at,
        MAX(CASE WHEN e.event_type = 'purchase' THEN e.event_time END) AS last_purchase_at
    FROM events e
    JOIN mart_session m ON e.user_session = m.user_session
    WHERE e.price >= 0
      AND e.event_type IN ('view', 'cart', 'purchase')
    GROUP BY e.user_session
), stage3 AS (
    SELECT
        b.user_session,
        MAX(e.event_time > b.first_view_at
            AND e.event_time < b.last_purchase_at) AS strict_stage3,
        MAX(e.event_time >= b.first_view_at
            AND e.event_time <= b.last_purchase_at) AS inclusive_stage3
    FROM bounds b
    JOIN events e ON e.user_session = b.user_session
    WHERE e.event_type = 'cart'
      AND e.price >= 0
      AND b.first_view_at IS NOT NULL
      AND b.last_purchase_at IS NOT NULL
    GROUP BY b.user_session
)
SELECT
    SUM(b.first_view_at IS NOT NULL) AS view_units,
    SUM(b.first_view_at IS NOT NULL
        AND b.last_cart_at > b.first_view_at) AS strict_stage2,
    SUM(b.first_view_at IS NOT NULL
        AND b.last_cart_at >= b.first_view_at) AS inclusive_stage2,
    COALESCE(SUM(s.strict_stage3), 0) AS strict_stage3,
    COALESCE(SUM(s.inclusive_stage3), 0) AS inclusive_stage3
FROM bounds b
LEFT JOIN stage3 s ON b.user_session = s.user_session

-- name: mart_rowcount | 마트 행수
SELECT COUNT(*) AS n
FROM mart_session

-- name: mart_type_counts | 마트 유형별 카운트 합 (검증b 대조용)
SELECT
    SUM(views) AS view,
    SUM(carts) AS cart,
    SUM(removes) AS remove_from_cart,
    SUM(purchases) AS purchase
FROM mart_session

-- name: mart_revenue | 마트 revenue 합 (검증c 대조용)
SELECT SUM(revenue) AS revenue
FROM mart_session

-- name: mart_ordered_counts | 마트 strict 순차 플래그 합 (검증d 대조용)
SELECT
    SUM(views > 0) AS view_units,
    SUM(has_cart_after_view) AS strict_stage2,
    SUM(has_purchase_after_view_cart) AS strict_stage3
FROM mart_session

-- name: mart_ordered_logic | 검증e: 순차 플래그 값·포함 관계
SELECT
    SUM(has_cart_after_view NOT IN (0, 1)) AS invalid_cart_flag,
    SUM(has_purchase_after_view_cart NOT IN (0, 1)) AS invalid_purchase_flag,
    SUM(has_cart_after_view = 1 AND views = 0) AS cart_without_view,
    SUM(has_purchase_after_view_cart = 1 AND has_cart_after_view = 0) AS purchase_without_cart,
    SUM(has_purchase_after_view_cart = 1 AND purchases = 0) AS purchase_without_event
FROM mart_session

-- name: create_mart_session_product | mart_session_product 생성 (docs/metrics.md 방침 집행)
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

-- name: raw_session_product_count | 검증a: raw에서 유효 세션 범위·세션·상품 조합 수
SELECT COUNT(*) AS n
FROM (
    SELECT
        e.user_session,
        e.product_id
    FROM events e
    JOIN mart_session m ON e.user_session = m.user_session
    WHERE e.price >= 0
      AND e.event_type IN ('view', 'cart', 'purchase')
      AND e.product_id IS NOT NULL
    GROUP BY e.user_session, e.product_id
) v

-- name: raw_session_product_type_counts | 검증b: raw에서 유효 세션 범위·price>=0 유형별 건수
SELECT
    e.event_type,
    COUNT(*) AS 건수
FROM events e
JOIN mart_session m ON e.user_session = m.user_session
WHERE e.price >= 0
  AND e.event_type IN ('view', 'cart', 'purchase')
  AND e.product_id IS NOT NULL
GROUP BY e.event_type
ORDER BY e.event_type

-- name: raw_session_product_ordered_counts | 검증c: raw에서 동일 상품 strict·inclusive 순차 도달 독립 계산
WITH bounds AS (
    SELECT
        e.user_session,
        e.product_id,
        MIN(CASE WHEN e.event_type = 'view' THEN e.event_time END) AS first_view_at,
        MAX(CASE WHEN e.event_type = 'cart' THEN e.event_time END) AS last_cart_at,
        MAX(CASE WHEN e.event_type = 'purchase' THEN e.event_time END) AS last_purchase_at
    FROM events e
    JOIN mart_session m ON e.user_session = m.user_session
    WHERE e.price >= 0
      AND e.event_type IN ('view', 'cart', 'purchase')
      AND e.product_id IS NOT NULL
    GROUP BY e.user_session, e.product_id
), stage3 AS (
    SELECT
        b.user_session,
        b.product_id,
        MAX(e.event_time > b.first_view_at
            AND e.event_time < b.last_purchase_at) AS strict_stage3,
        MAX(e.event_time >= b.first_view_at
            AND e.event_time <= b.last_purchase_at) AS inclusive_stage3
    FROM bounds b
    JOIN events e
      ON e.user_session = b.user_session
     AND e.product_id = b.product_id
    WHERE e.event_type = 'cart'
      AND e.price >= 0
      AND b.first_view_at IS NOT NULL
      AND b.last_purchase_at IS NOT NULL
    GROUP BY b.user_session, b.product_id
)
SELECT
    SUM(b.first_view_at IS NOT NULL) AS view_units,
    SUM(b.first_view_at IS NOT NULL
        AND b.last_cart_at > b.first_view_at) AS strict_stage2,
    SUM(b.first_view_at IS NOT NULL
        AND b.last_cart_at >= b.first_view_at) AS inclusive_stage2,
    COALESCE(SUM(s.strict_stage3), 0) AS strict_stage3,
    COALESCE(SUM(s.inclusive_stage3), 0) AS inclusive_stage3
FROM bounds b
LEFT JOIN stage3 s
  ON b.user_session = s.user_session
 AND b.product_id = s.product_id

-- name: mart_session_product_count | 마트 세션·상품 행수
SELECT COUNT(*) AS n
FROM mart_session_product

-- name: mart_session_product_type_counts | 마트 유형별 카운트 합 (검증b 대조용)
SELECT
    SUM(views) AS view,
    SUM(carts) AS cart,
    SUM(purchases) AS purchase
FROM mart_session_product

-- name: mart_session_product_ordered_counts | 마트 strict 순차 플래그 합 (검증c 대조용)
SELECT
    SUM(views > 0) AS view_units,
    SUM(has_cart_after_view) AS strict_stage2,
    SUM(has_purchase_after_view_cart) AS strict_stage3
FROM mart_session_product

-- name: mart_session_product_logic | 검증d: 순차 플래그 값·포함 관계
SELECT
    SUM(has_cart_after_view NOT IN (0, 1)) AS invalid_cart_flag,
    SUM(has_purchase_after_view_cart NOT IN (0, 1)) AS invalid_purchase_flag,
    SUM(has_cart_after_view = 1 AND views = 0) AS cart_without_view,
    SUM(has_purchase_after_view_cart = 1 AND has_cart_after_view = 0) AS purchase_without_cart,
    SUM(has_purchase_after_view_cart = 1 AND purchases = 0) AS purchase_without_event
FROM mart_session_product

-- name: mart_session_product_key | 검증e: 복합 기본키 구성
SELECT
    COUNT(*) AS pk_columns
FROM information_schema.statistics
WHERE table_schema = DATABASE()
  AND table_name = 'mart_session_product'
  AND index_name = 'PRIMARY'

-- name: create_mart_user_product_session | 구매 여정용 세션·상품 마트 생성 (docs/metrics.md 방침 집행)
-- 처리 방침의 단일 원천은 docs/metrics.md. 이 스크립트가 그 방침을 집행한다.
-- 분석 단위는 유효 세션·상품(user_session × product_id) 1행이다.
-- view·cart·remove·purchase의 최초·최종 시각을 보존해 06에서 raw를 다시 조회하지 않는다.
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

-- name: raw_user_product_session_reconciliation | 검증a: raw 집계와 여정 마트의 행수·카운트·시각 대조
WITH raw_grouped AS (
    SELECT
        e.user_session,
        e.product_id,
        MIN(e.user_id) AS user_id,
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
        SUM(IF(e.event_type = 'purchase' AND e.price > 0, e.price, 0)) AS revenue
    FROM events e
    JOIN mart_session m ON e.user_session = m.user_session
    WHERE e.price >= 0
      AND e.event_type IN ('view', 'cart', 'remove_from_cart', 'purchase')
      AND e.product_id IS NOT NULL
    GROUP BY e.user_session, e.product_id
)
SELECT
    COUNT(*) AS raw_행수,
    SUM(r.views) AS raw_views,
    SUM(r.carts) AS raw_carts,
    SUM(r.removes) AS raw_removes,
    SUM(r.purchases) AS raw_purchases,
    SUM(r.revenue) AS raw_revenue,
    SUM(j.user_session IS NULL) AS 마트누락_행수,
    SUM(NOT (j.user_id <=> r.user_id)) AS user_id_불일치,
    SUM(j.views <> r.views OR j.carts <> r.carts
        OR j.removes <> r.removes OR j.purchases <> r.purchases) AS 카운트_불일치,
    SUM(NOT (j.first_view_at <=> r.first_view_at)
        OR NOT (j.last_view_at <=> r.last_view_at)
        OR NOT (j.first_cart_at <=> r.first_cart_at)
        OR NOT (j.last_cart_at <=> r.last_cart_at)
        OR NOT (j.first_remove_at <=> r.first_remove_at)
        OR NOT (j.last_remove_at <=> r.last_remove_at)
        OR NOT (j.first_purchase_at <=> r.first_purchase_at)
        OR NOT (j.last_purchase_at <=> r.last_purchase_at)) AS 시각_불일치,
    SUM(ABS(j.revenue - r.revenue) > 0.0001) AS revenue_불일치
FROM raw_grouped r
LEFT JOIN mart_user_product_session j
  ON r.user_session = j.user_session
 AND r.product_id = j.product_id;

-- name: raw_user_product_before_purchase_reconciliation | 검증b: 최초 구매 전 행동 시각 raw 대조
WITH raw_before_purchase AS (
    SELECT
        j.user_session,
        j.product_id,
        MAX(CASE
            WHEN e.event_type = 'view' AND e.event_time < j.first_purchase_at
            THEN e.event_time
        END) AS last_view_before_first_purchase_at,
        MAX(CASE
            WHEN e.event_type = 'cart' AND e.event_time < j.first_purchase_at
            THEN e.event_time
        END) AS last_cart_before_first_purchase_at,
        MAX(CASE
            WHEN e.event_type = 'remove_from_cart' AND e.event_time < j.first_purchase_at
            THEN e.event_time
        END) AS last_remove_before_first_purchase_at
    FROM mart_user_product_session j
    LEFT JOIN events e
      ON j.user_session = e.user_session
     AND j.product_id = e.product_id
     AND e.price >= 0
     AND e.event_type IN ('view', 'cart', 'remove_from_cart')
    WHERE j.first_purchase_at IS NOT NULL
    GROUP BY j.user_session, j.product_id
)
SELECT
    COUNT(*) AS raw_구매전행동_행수,
    SUM(NOT (j.last_view_before_first_purchase_at
        <=> r.last_view_before_first_purchase_at)
        OR NOT (j.last_cart_before_first_purchase_at
        <=> r.last_cart_before_first_purchase_at)
        OR NOT (j.last_remove_before_first_purchase_at
        <=> r.last_remove_before_first_purchase_at)) AS 구매전행동시각_불일치
FROM raw_before_purchase r
JOIN mart_user_product_session j
  ON r.user_session = j.user_session
 AND r.product_id = j.product_id;

-- name: mart_user_product_session_summary | 여정 마트 행수·카운트·revenue 합
SELECT
    COUNT(*) AS 마트_행수,
    SUM(purchases > 0) AS 마트_구매행수,
    SUM(views) AS 마트_views,
    SUM(carts) AS 마트_carts,
    SUM(removes) AS 마트_removes,
    SUM(purchases) AS 마트_purchases,
    SUM(revenue) AS 마트_revenue
FROM mart_user_product_session;

-- name: mart_user_product_session_flags | 검증c: 기존 동일 상품 순차 플래그와 대조
SELECT
    (SELECT SUM(has_cart_after_view) FROM mart_user_product_session) AS 여정마트_stage2,
    (SELECT SUM(has_cart_after_view) FROM mart_session_product) AS 기존마트_stage2,
    (SELECT SUM(has_purchase_after_view_cart) FROM mart_user_product_session) AS 여정마트_stage3,
    (SELECT SUM(has_purchase_after_view_cart) FROM mart_session_product) AS 기존마트_stage3;

-- name: mart_user_product_session_logic | 검증d: 시각·카운트·플래그 논리 관계
SELECT
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
FROM mart_user_product_session;

-- name: mart_user_product_session_key | 검증e: 복합 기본키·분석 인덱스 구성
SELECT
    SUM(index_name = 'PRIMARY') AS 기본키_열수,
    SUM(index_name = 'idx_mups_user_product_start') AS 사용자상품시각_인덱스열수,
    SUM(index_name = 'idx_mups_product_start') AS 상품시각_인덱스열수,
    SUM(index_name = 'idx_mups_first_purchase') AS 구매시각_인덱스열수
FROM information_schema.statistics
WHERE table_schema = DATABASE()
  AND table_name = 'mart_user_product_session';
