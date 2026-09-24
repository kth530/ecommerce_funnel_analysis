-- 04 세션 퍼널 초기 진단
-- 이 파일은 세션 경계 안의 strict 순차 퍼널과 세션 경계 품질만 진단한다.
-- 후속 05는 user_id × product_id의 최초 view를 기준으로 30일 대표 첫 구매를 분석한다.
-- 두 분석은 단위·분모·관측창이 다르므로 수치의 직접 비교나 증감률 계산을 하지 않는다.

-- name: fn_session_funnel | 방문 단위 조회→담기→구매 순차 퍼널
-- 분석 단위·분모: user_session, mart_session의 유효 세션 전체.
-- 시간 순서: 같은 세션에서 view_at < cart_at < purchase_at인 strict 플래그를 사용한다.
-- 상품 동일성은 요구하지 않으므로 05의 사용자·상품 30일 대표 첫 구매 cohort와 직접 비교하지 않는다.
SELECT
    SUM(views > 0) AS view_도달,
    SUM(has_cart_after_view) AS view_cart_순차,
    SUM(has_purchase_after_view_cart) AS view_cart_purchase_순차,
    COUNT(*) AS 유효세션
FROM mart_session

-- name: fn_boundary | 방문 단위 선형 퍼널 밖의 경계 규모
-- 분석 단위·분모: user_session, mart_session의 유효 세션 전체.
-- 시간 순서: 존재 여부와 strict view→cart 플래그를 분리하며 각 조건은 서로 겹칠 수 있다.
-- 이 쿼리는 세션 퍼널의 한계만 보여주며, 정확한 구매 경로는 05의 대표 첫 구매 네 경로가 대체한다.
SELECT
    SUM(views = 0 AND carts > 0) AS view없이_cart,
    SUM(views = 0 AND purchases > 0) AS view없이_purchase,
    SUM(views > 0 AND carts > 0 AND has_cart_after_view = 0)
        AS view_cart있으나_순서미확인,
    COUNT(*) AS 유효세션
FROM mart_session

-- name: fn_product_funnel | 같은 방문·같은 상품 조회→담기→구매 순차 퍼널
-- 분석 단위·분모: user_session × product_id, mart_session_product 전체 조합.
-- 시간 순서: 같은 세션·같은 상품에서 view_at < cart_at < purchase_at인 strict 플래그를 사용한다.
-- 05는 여러 세션을 합친 user_id × product_id와 30일 관측창을 사용하므로 직접 비교하지 않는다.
SELECT
    SUM(views > 0) AS view_도달,
    SUM(has_cart_after_view) AS view_cart_순차,
    SUM(has_purchase_after_view_cart) AS view_cart_purchase_순차,
    SUM(views = 0 AND carts > 0) AS view없이_cart,
    SUM(views = 0 AND purchases > 0) AS view없이_purchase,
    SUM(views > 0 AND carts > 0 AND has_cart_after_view = 0)
        AS view_cart있으나_순서미확인,
    COUNT(*) AS session_product수
FROM mart_session_product

-- name: fn_user_product_session_scope | 동일 사용자·상품의 관측 세션 수 분포
-- 분석 단위·분모: user_id × product_id, mart_session_product에서 관찰된 전체 조합.
-- 시간 순서를 판정하지 않고 한 사용자·상품이 몇 개 세션에 나타났는지만 센다.
-- 구매 여부와 30일 관측 조건을 적용하지 않으므로 05의 대표 첫 구매 cohort와 직접 비교하지 않는다.
WITH user_product_summary AS (
    SELECT
        session.user_id,
        product.product_id,
        COUNT(*) AS 관측세션수
    FROM mart_session_product product
    JOIN mart_session session
      ON product.user_session = session.user_session
    GROUP BY session.user_id, product.product_id
)
SELECT
    CASE
        WHEN 관측세션수 = 1 THEN '1세션'
        WHEN 관측세션수 = 2 THEN '2세션'
        WHEN 관측세션수 <= 5 THEN '3-5세션'
        ELSE '6+세션'
    END AS 관측세션구간,
    COUNT(*) AS 사용자상품_조합수,
    SUM(관측세션수) AS 세션상품_조합수
FROM user_product_summary
GROUP BY 관측세션구간
ORDER BY MIN(관측세션수)
