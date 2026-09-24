-- 02 전처리 집행·분석 마트 구축·통합 검증
-- 생성 DDL은 기존 정의를 보존하고, 기본 실행은 기존 마트의 smoke check만 수행한다.
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

-- name: raw_session_reconciliation | raw 유효 세션·카운트·revenue·strict/inclusive 통합 검증
WITH valid_sessions AS (
    SELECT user_session
    FROM events
    WHERE user_session IS NOT NULL
    GROUP BY user_session
    HAVING COUNT(DISTINCT user_id) = 1
       AND TIMESTAMPDIFF(SECOND, MIN(event_time), MAX(event_time)) <= 86400
), event_totals AS (
    SELECT
        SUM(e.event_type = 'view') AS raw_views,
        SUM(e.event_type = 'cart') AS raw_carts,
        SUM(e.event_type = 'remove_from_cart') AS raw_removes,
        SUM(e.event_type = 'purchase') AS raw_purchases,
        SUM(IF(e.event_type = 'purchase' AND e.price > 0, e.price, 0)) AS raw_revenue
    FROM events e
    JOIN valid_sessions v ON e.user_session = v.user_session
    WHERE e.price >= 0
), bounds AS (
    SELECT
        e.user_session,
        MIN(CASE WHEN e.event_type = 'view' THEN e.event_time END) AS first_view_at,
        MAX(CASE WHEN e.event_type = 'cart' THEN e.event_time END) AS last_cart_at,
        MAX(CASE WHEN e.event_type = 'purchase' THEN e.event_time END) AS last_purchase_at
    FROM events e
    JOIN valid_sessions v ON e.user_session = v.user_session
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
    (SELECT COUNT(*) FROM valid_sessions) AS raw_유효세션수,
    MAX(t.raw_views) AS raw_views,
    MAX(t.raw_carts) AS raw_carts,
    MAX(t.raw_removes) AS raw_removes,
    MAX(t.raw_purchases) AS raw_purchases,
    MAX(t.raw_revenue) AS raw_revenue,
    SUM(b.first_view_at IS NOT NULL) AS view_units,
    SUM(b.first_view_at IS NOT NULL
        AND b.last_cart_at > b.first_view_at) AS strict_stage2,
    SUM(b.first_view_at IS NOT NULL
        AND b.last_cart_at >= b.first_view_at) AS inclusive_stage2,
    COALESCE(SUM(s.strict_stage3), 0) AS strict_stage3,
    COALESCE(SUM(s.inclusive_stage3), 0) AS inclusive_stage3
FROM bounds b
LEFT JOIN stage3 s ON b.user_session = s.user_session
CROSS JOIN event_totals t

-- name: mart_session_reconciliation | mart_session 카운트·revenue·strict 플래그·논리 통합 검증
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

-- name: raw_session_product_reconciliation | raw 세션·상품 행수·카운트·strict/inclusive 통합 검증
WITH bounds AS (
    SELECT
        e.user_session,
        e.product_id,
        SUM(e.event_type = 'view') AS views,
        SUM(e.event_type = 'cart') AS carts,
        SUM(e.event_type = 'purchase') AS purchases,
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
    COUNT(*) AS raw_행수,
    SUM(b.views) AS raw_views,
    SUM(b.carts) AS raw_carts,
    SUM(b.purchases) AS raw_purchases,
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

-- name: mart_session_product_reconciliation | mart_session_product 카운트·strict 플래그·논리 통합 검증
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

-- name: create_mart_user_product_session | 대표 첫 구매용 세션·상품 마트 생성 (docs/metrics.md 방침 집행)
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

-- name: raw_user_product_session_reconciliation | raw 집계와 대표 첫 구매 마트의 행수·카운트·시각 대조
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

-- name: raw_user_product_before_purchase_reconciliation | 최초 구매 전 행동 시각 raw 대조
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

-- name: mart_user_product_session_reconciliation | 대표 첫 구매 마트 카운트·시각·플래그 논리 통합 검증
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

-- name: mart_inventory_smoke | 세 마트의 정확한 행 수와 기본 논리 위반 저비용 확인
SELECT
    'mart_session' AS table_name,
    COUNT(*) AS row_count,
    SUM(CASE WHEN
        user_session IS NULL
        OR user_id IS NULL
        OR session_start > session_end
        OR duration_sec < 0
        OR total_events < 0
        OR views < 0 OR carts < 0 OR removes < 0 OR purchases < 0
        OR has_cart_after_view NOT IN (0, 1)
        OR has_purchase_after_view_cart NOT IN (0, 1)
        OR (has_cart_after_view = 1 AND views = 0)
        OR (has_purchase_after_view_cart = 1 AND has_cart_after_view = 0)
        OR (has_purchase_after_view_cart = 1 AND purchases = 0)
        THEN 1 ELSE 0 END) AS basic_logic_violations
FROM mart_session
UNION ALL
SELECT
    'mart_session_product' AS table_name,
    COUNT(*) AS row_count,
    SUM(CASE WHEN
        user_session IS NULL
        OR product_id IS NULL
        OR views < 0 OR carts < 0 OR purchases < 0
        OR has_cart_after_view NOT IN (0, 1)
        OR has_purchase_after_view_cart NOT IN (0, 1)
        OR (has_cart_after_view = 1 AND views = 0)
        OR (has_purchase_after_view_cart = 1 AND has_cart_after_view = 0)
        OR (has_purchase_after_view_cart = 1 AND purchases = 0)
        THEN 1 ELSE 0 END) AS basic_logic_violations
FROM mart_session_product
UNION ALL
SELECT
    'mart_user_product_session' AS table_name,
    COUNT(*) AS row_count,
    SUM(CASE WHEN
        user_session IS NULL OR user_id IS NULL OR product_id IS NULL
        OR session_start > session_end
        OR views < 0 OR carts < 0 OR removes < 0 OR purchases < 0
        OR (views = 0 AND (first_view_at IS NOT NULL OR last_view_at IS NOT NULL))
        OR (views > 0 AND (first_view_at IS NULL OR last_view_at IS NULL))
        OR (carts = 0 AND (first_cart_at IS NOT NULL OR last_cart_at IS NOT NULL))
        OR (carts > 0 AND (first_cart_at IS NULL OR last_cart_at IS NULL))
        OR (purchases = 0 AND (first_purchase_at IS NOT NULL OR last_purchase_at IS NOT NULL))
        OR (purchases > 0 AND (first_purchase_at IS NULL OR last_purchase_at IS NULL))
        OR first_view_at > last_view_at
        OR first_cart_at > last_cart_at
        OR first_purchase_at > last_purchase_at
        OR last_cart_before_first_purchase_at >= first_purchase_at
        OR has_cart_after_view NOT IN (0, 1)
        OR has_purchase_after_view_cart NOT IN (0, 1)
        OR has_view_cart_before_first_purchase NOT IN (0, 1)
        OR (has_purchase_after_view_cart = 1 AND has_cart_after_view = 0)
        THEN 1 ELSE 0 END) AS basic_logic_violations
FROM mart_user_product_session
ORDER BY table_name

-- name: mart_schema_contract | 세 마트의 컬럼·PK·인덱스 계약 확인
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
