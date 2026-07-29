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
