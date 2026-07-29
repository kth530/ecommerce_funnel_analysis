-- 04 퍼널 EDA 집계
-- name: fn_session_funnel | 세션 전체 strict 순차 퍼널
-- 분석 단위는 세션. 분자는 항상 직전 단계 분모의 부분집합이다.
SELECT
    SUM(views > 0) AS view_도달,
    SUM(has_cart_after_view) AS view_cart_순차,
    SUM(has_purchase_after_view_cart) AS view_cart_purchase_순차,
    COUNT(*) AS 유효세션
FROM mart_session

-- name: fn_remove_signal | strict cart 순차 도달 세션의 remove 동반 여부
-- remove_from_cart는 순차 퍼널 단계나 이탈 판정값이 아니라 동일 세션에서 함께 관찰된 보조 신호다.
-- removes > 0은 세션 내 발생 여부만 뜻하며 view·cart 사이, cart 이후, purchase 전후를 구분하지 않는다.
SELECT
    SUM(has_cart_after_view) AS view_cart_순차,
    SUM(has_cart_after_view = 1 AND removes > 0) AS 순차cart중_제거발생,
    SUM(has_cart_after_view = 1 AND has_purchase_after_view_cart = 0) AS 순차cart_미구매,
    SUM(has_cart_after_view = 1
        AND has_purchase_after_view_cart = 0
        AND removes > 0) AS 순차cart미구매중_제거발생
FROM mart_session

-- name: fn_boundary | view → cart → purchase 순서와 다른 세션 규모
-- first_event_type은 판정에 사용하지 않는다. 각 집계는 독립 조건이므로 서로 겹칠 수 있다.
SELECT
    SUM(views = 0 AND carts > 0) AS view없이_cart,
    SUM(views = 0 AND purchases > 0) AS view없이_purchase,
    SUM(views > 0 AND carts > 0 AND has_cart_after_view = 0) AS view_cart있으나_순서미확인,
    SUM(has_cart_after_view = 1
        AND purchases > 0
        AND has_purchase_after_view_cart = 0) AS purchase있으나_순차purchase아님,
    SUM(carts = 0 AND purchases = 0 AND removes > 0) AS cart없는_제거세션,
    SUM(views = 0) AS view_미도달_전체,
    COUNT(*) AS 유효세션
FROM mart_session

-- name: fn_seg_dow | 요일별 strict 순차 퍼널 (세션 단위, session_start 기준, 1=일 ~ 7=토)
SELECT
    DAYOFWEEK(session_start) AS 요일번호,
    SUM(views > 0) AS view_도달,
    SUM(has_cart_after_view) AS view_cart_순차,
    SUM(has_purchase_after_view_cart) AS view_cart_purchase_순차,
    COUNT(*) AS 세션수
FROM mart_session
GROUP BY 요일번호
ORDER BY 요일번호

-- name: fn_seg_month | 월별 strict 순차 퍼널과 관측 범위 (세션 단위, session_start 기준)
-- 양끝 월의 완결 여부를 확인할 수 있도록 월별 MIN·MAX session_start와 관측 일수를 함께 반환한다.
SELECT
    DATE_FORMAT(session_start, '%Y-%m') AS 월,
    MIN(session_start) AS 관측시작,
    MAX(session_start) AS 관측종료,
    COUNT(DISTINCT DATE(session_start)) AS 관측일수,
    SUM(views > 0) AS view_도달,
    SUM(has_cart_after_view) AS view_cart_순차,
    SUM(has_purchase_after_view_cart) AS view_cart_purchase_순차,
    COUNT(*) AS 세션수
FROM mart_session
GROUP BY 월
ORDER BY 월

-- name: fn_seg_events | total_events 구간별 strict 순차 퍼널 (세션 단위)
SELECT
    CASE
        WHEN total_events <= 1 THEN '0-1'
        WHEN total_events <= 3 THEN '2-3'
        WHEN total_events <= 10 THEN '4-10'
        WHEN total_events <= 50 THEN '11-50'
        ELSE '51+'
    END AS 구간,
    SUM(views > 0) AS view_도달,
    SUM(has_cart_after_view) AS view_cart_순차,
    SUM(has_purchase_after_view_cart) AS view_cart_purchase_순차,
    COUNT(*) AS 세션수
FROM mart_session
GROUP BY 구간
ORDER BY MIN(total_events)

-- name: fn_seg_views | view 횟수 구간별 strict view→cart 전환 (세션 단위)
-- 분모는 view 도달(views > 0) 세션만 사용한다. views는 cart·purchase를 포함하지 않는 상류 노출 횟수다.
SELECT
    CASE
        WHEN views = 1 THEN '1'
        WHEN views <= 3 THEN '2-3'
        WHEN views <= 10 THEN '4-10'
        WHEN views <= 30 THEN '11-30'
        ELSE '31+'
    END AS 구간,
    COUNT(*) AS 세션수,
    SUM(has_cart_after_view) AS view_cart_순차
FROM mart_session
WHERE views > 0
GROUP BY 구간
ORDER BY MIN(views)

-- name: fn_seg_visit | 사용자당 관측 세션 수별 strict 순차 퍼널 (세션 단위)
-- 사용자를 관측 기간 내 총 세션 1개와 2개 이상으로 나누며, 신규 여부나 개별 세션의 방문 차수를 뜻하지 않는다.
SELECT
    CASE WHEN uc.n = 1 THEN '1세션 사용자' ELSE '2+세션 사용자' END AS 세그먼트,
    COUNT(DISTINCT m.user_id) AS 사용자수,
    SUM(m.views > 0) AS view_도달,
    SUM(m.has_cart_after_view) AS view_cart_순차,
    SUM(m.has_purchase_after_view_cart) AS view_cart_purchase_순차,
    COUNT(*) AS 세션수
FROM mart_session m
JOIN (
    SELECT user_id, COUNT(*) AS n
    FROM mart_session
    GROUP BY user_id
) uc ON m.user_id = uc.user_id
GROUP BY 세그먼트

-- name: create_mart_product | mart_product 생성 (docs/metrics.md 방침 집행)
-- 상품(product_id) 단위 1행. 04의 상품 속성은 이 마트에서 가져온다.
-- raw(events)는 이 생성·검증 블록에서만 사용하고 분석 집계는 마트만 소비한다.
DROP TABLE IF EXISTS mart_product;

CREATE TABLE mart_product AS
WITH product_base AS (
    SELECT
        product_id,
        SUM(event_type = 'view') AS views,
        SUM(event_type = 'cart') AS carts,
        SUM(event_type = 'purchase') AS purchases,
        AVG(CASE WHEN price > 0 THEN price END) AS avg_price,
        SUM(CASE WHEN event_type = 'purchase' AND price > 0
                 THEN price ELSE 0 END) AS revenue
    FROM events
    WHERE price >= 0
      AND product_id IS NOT NULL
    GROUP BY product_id
), category_counts AS (
    SELECT
        product_id,
        category_id,
        COUNT(*) AS event_count,
        MAX(event_time) AS last_seen_at
    FROM events
    WHERE price >= 0
      AND product_id IS NOT NULL
      AND category_id IS NOT NULL
    GROUP BY product_id, category_id
), category_ranked AS (
    SELECT
        product_id,
        category_id,
        COUNT(*) OVER (PARTITION BY product_id) AS category_id_count,
        ROW_NUMBER() OVER (
            PARTITION BY product_id
            ORDER BY event_count DESC, last_seen_at DESC, category_id ASC
        ) AS rn
    FROM category_counts
), brand_counts AS (
    SELECT
        product_id,
        brand,
        COUNT(*) AS event_count,
        MAX(event_time) AS last_seen_at
    FROM events
    WHERE price >= 0
      AND product_id IS NOT NULL
      AND NULLIF(brand, '') IS NOT NULL
    GROUP BY product_id, brand
), brand_ranked AS (
    SELECT
        product_id,
        brand,
        COUNT(*) OVER (PARTITION BY product_id) AS brand_count,
        ROW_NUMBER() OVER (
            PARTITION BY product_id
            ORDER BY event_count DESC, last_seen_at DESC, brand ASC
        ) AS rn
    FROM brand_counts
)
SELECT
    b.product_id,
    c.category_id,                                           -- metrics.md 방침: 최빈값 → 최근 관찰 → 값 오름차순
    COALESCE(br.brand, 'unknown') AS brand,                  -- 유효한 brand가 없으면 unknown
    COALESCE(c.category_id_count, 0) AS category_id_count,
    COALESCE(br.brand_count, 0) AS brand_count,
    b.views,
    b.carts,
    b.purchases,
    b.avg_price,                                             -- price = 0·음수 제외
    b.revenue
FROM product_base b
LEFT JOIN category_ranked c
  ON b.product_id = c.product_id
 AND c.rn = 1
LEFT JOIN brand_ranked br
  ON b.product_id = br.product_id
 AND br.rn = 1;

CREATE UNIQUE INDEX idx_mp_product ON mart_product (product_id);

CREATE INDEX idx_mp_category ON mart_product (category_id);

CREATE INDEX idx_mp_brand ON mart_product (brand);

-- name: prod_raw_count | 검증a: raw(events)에서 상품 수 (price>=0, product_id NOT NULL, 독립 계산)
SELECT COUNT(DISTINCT product_id) AS n
FROM events
WHERE price >= 0
  AND product_id IS NOT NULL

-- name: prod_raw_type | 검증b: raw 유형별 카운트 (price>=0, view/cart/purchase)
SELECT
    event_type,
    COUNT(*) AS 건수
FROM events
WHERE price >= 0
  AND product_id IS NOT NULL
  AND event_type IN ('view', 'cart', 'purchase')
GROUP BY event_type
ORDER BY event_type

-- name: prod_raw_revenue | 검증c: raw revenue (purchase, price>0)
SELECT SUM(price) AS revenue
FROM events
WHERE event_type = 'purchase'
  AND price > 0
  AND product_id IS NOT NULL

-- name: prod_mart_count | 마트 상품 수 (검증a 대조용)
SELECT COUNT(*) AS n
FROM mart_product

-- name: prod_attribute_quality | 검증d: 대표 속성 방침과 다중값 규모
SELECT
    SUM(product_id IS NULL) AS product_id_NULL,
    SUM(category_id IS NULL OR category_id_count = 0) AS category_대표값오류,
    SUM(brand IS NULL) AS brand_대표값오류,
    SUM(category_id_count > 1) AS 다중category_상품,
    SUM(brand_count > 1) AS 다중brand_상품,
    SUM(brand = 'unknown') AS brand_unknown_상품
FROM mart_product

-- name: prod_mart_type | 마트 유형별 카운트 합 (검증b 대조용)
SELECT
    SUM(views) AS view,
    SUM(carts) AS cart,
    SUM(purchases) AS purchase
FROM mart_product

-- name: prod_mart_revenue | 마트 revenue 합 (검증c 대조용)
SELECT SUM(revenue) AS revenue
FROM mart_product

-- name: prod_join_check | mart_session_product와 mart_product 연결 완전성
SELECT
    COUNT(*) AS session_product수,
    SUM(p.product_id IS NULL) AS 상품속성_미연결
FROM mart_session_product sp
LEFT JOIN mart_product p ON sp.product_id = p.product_id

-- name: fn_product_funnel | 동일 상품 strict 순차 퍼널 (세션·상품 단위)
SELECT
    SUM(views > 0) AS view_도달,
    SUM(has_cart_after_view) AS view_cart_순차,
    SUM(has_purchase_after_view_cart) AS view_cart_purchase_순차,
    SUM(views = 0 AND carts > 0) AS view없이_cart,
    SUM(views = 0 AND purchases > 0) AS view없이_purchase,
    SUM(views > 0 AND carts > 0 AND has_cart_after_view = 0) AS view_cart있으나_순서미확인,
    COUNT(*) AS session_product수
FROM mart_session_product

-- name: fn_product_category | 카테고리별 동일 상품 strict 순차 퍼널
SELECT
    p.category_id,
    COUNT(DISTINCT sp.product_id) AS 상품수,
    SUM(sp.views > 0) AS view_도달,
    SUM(sp.has_cart_after_view) AS view_cart_순차,
    SUM(sp.has_purchase_after_view_cart) AS view_cart_purchase_순차,
    COUNT(*) AS session_product수
FROM mart_session_product sp
JOIN mart_product p ON sp.product_id = p.product_id
GROUP BY p.category_id

-- name: fn_product_category_revenue | 대표 카테고리별 전체 기간 상품 revenue
-- 분석 단위는 상품이며 session-product 퍼널 집계와 단위를 섞지 않고 별도 열로 제시한다.
SELECT
    category_id,
    COUNT(*) AS 상품수,
    SUM(revenue) AS revenue
FROM mart_product
GROUP BY category_id

-- name: fn_product_price | 가격대별 동일 상품 strict 순차 퍼널
SELECT
    CASE
        WHEN p.avg_price IS NULL THEN '가격미상'
        WHEN p.avg_price < 5 THEN '0-5'
        WHEN p.avg_price < 15 THEN '5-15'
        WHEN p.avg_price < 30 THEN '15-30'
        WHEN p.avg_price < 60 THEN '30-60'
        WHEN p.avg_price < 100 THEN '60-100'
        ELSE '100+'
    END AS 가격대,
    COUNT(DISTINCT sp.product_id) AS 상품수,
    SUM(sp.views > 0) AS view_도달,
    SUM(sp.has_cart_after_view) AS view_cart_순차,
    SUM(sp.has_purchase_after_view_cart) AS view_cart_purchase_순차,
    COUNT(*) AS session_product수
FROM mart_session_product sp
JOIN mart_product p ON sp.product_id = p.product_id
GROUP BY 가격대
ORDER BY MIN(p.avg_price)

-- name: fn_product_brand | brand 결측 여부별 동일 상품 strict 순차 퍼널
SELECT
    CASE WHEN p.brand = 'unknown' THEN 'unknown' ELSE 'known' END AS brand_구분,
    COUNT(DISTINCT sp.product_id) AS 상품수,
    SUM(sp.views > 0) AS view_도달,
    SUM(sp.has_cart_after_view) AS view_cart_순차,
    SUM(sp.has_purchase_after_view_cart) AS view_cart_purchase_순차,
    COUNT(*) AS session_product수
FROM mart_session_product sp
JOIN mart_product p ON sp.product_id = p.product_id
GROUP BY brand_구분
