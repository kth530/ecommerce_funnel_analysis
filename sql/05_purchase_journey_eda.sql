-- 05 세션 간 구매 여정 EDA
-- 분석 집계는 검증된 mart_session·mart_session_product만 소비한다.
-- 이 파일의 선행 행동은 이전 세션의 session_end가 현재 session_start보다 빠른 경우만 인정한다.
-- 이벤트의 정확한 시간 순서와 세션 간 장바구니 상태는 아직 판정하지 않는다.

-- name: jn_unit_scope | 사용자·상품의 관측 세션 수 분포
-- 분석 단위는 사용자·상품(user_id × product_id)이다.
-- mart_session_product가 view·cart·purchase 중 하나 이상 있는 조합만 포함하므로 remove-only 조합은 범위 밖이다.
WITH user_product_summary AS (
    SELECT
        m.user_id,
        sp.product_id,
        COUNT(*) AS 관측세션수,
        SUM(sp.views > 0) AS view도달_세션수,
        SUM(sp.carts > 0) AS cart도달_세션수,
        SUM(sp.purchases > 0) AS purchase도달_세션수
    FROM mart_session_product sp
    JOIN mart_session m ON sp.user_session = m.user_session
    GROUP BY m.user_id, sp.product_id
)
SELECT
    CASE
        WHEN 관측세션수 = 1 THEN '1세션'
        WHEN 관측세션수 = 2 THEN '2세션'
        WHEN 관측세션수 <= 5 THEN '3-5세션'
        ELSE '6+세션'
    END AS 관측세션구간,
    COUNT(*) AS 사용자상품_조합수,
    SUM(관측세션수) AS 세션상품_조합수,
    SUM(view도달_세션수) AS view도달_세션상품수,
    SUM(cart도달_세션수) AS cart도달_세션상품수,
    SUM(purchase도달_세션수) AS purchase도달_세션상품수
FROM user_product_summary
GROUP BY 관측세션구간
ORDER BY MIN(관측세션수)

-- name: jn_session_order_quality | 같은 사용자의 세션 시작 시각·시간 겹침 확인
-- 분석 단위는 세션이다. 같은 시각에 시작했거나 이전 세션이 끝나기 전에 시작한 세션을 센다.
WITH ordered AS (
    SELECT
        user_id,
        user_session,
        session_start,
        session_end,
        COUNT(*) OVER (
            PARTITION BY user_id, session_start
        ) AS 같은시각시작_세션수,
        MAX(session_end) OVER (
            PARTITION BY user_id
            ORDER BY session_start, user_session
            ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
        ) AS 이전세션중_가장늦은종료시각
    FROM mart_session
)
SELECT
    COUNT(*) AS 전체세션수,
    SUM(같은시각시작_세션수 > 1) AS 같은시각시작_주의세션수,
    SUM(이전세션중_가장늦은종료시각 >= session_start) AS 이전세션과_시간겹침_세션수,
    SUM(같은시각시작_세션수 > 1
        OR 이전세션중_가장늦은종료시각 >= session_start) AS 순서판별_주의세션수
FROM ordered

-- name: jn_prior_coverage | cart·purchase 전에 동일 상품 행동이 있었는지 확인
-- 분석 단위는 cart 또는 purchase가 있는 세션·상품 조합이다.
-- 현재 세션보다 먼저 완전히 끝난 세션만 이전 세션으로 인정한다.
WITH session_product_base AS (
    SELECT
        m.user_id,
        sp.product_id,
        sp.user_session,
        m.session_start,
        m.session_end,
        sp.views,
        sp.carts,
        sp.purchases,
        sp.has_cart_after_view,
        sp.has_purchase_after_view_cart
    FROM mart_session_product sp
    JOIN mart_session m ON sp.user_session = m.user_session
), prior_session_check AS (
    SELECT
        session_product_base.*,
        -- 현재 행보다 앞선 view 세션들의 session_end 중 가장 최근 시각
        MAX(CASE WHEN views > 0 THEN session_end END) OVER (
            PARTITION BY user_id, product_id
            ORDER BY session_start, user_session
            ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
        ) AS 이전_view세션_최근종료시각,
        -- 현재 행보다 앞선 cart 세션들의 session_end 중 가장 최근 시각
        MAX(CASE WHEN carts > 0 THEN session_end END) OVER (
            PARTITION BY user_id, product_id
            ORDER BY session_start, user_session
            ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
        ) AS 이전_cart세션_최근종료시각,
        -- 현재 행보다 앞선 view → cart 완료 세션들의 session_end 중 가장 최근 시각
        MAX(CASE WHEN has_cart_after_view = 1 THEN session_end END) OVER (
            PARTITION BY user_id, product_id
            ORDER BY session_start, user_session
            ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
        ) AS 이전_view후cart세션_최근종료시각
    FROM session_product_base
)
SELECT
    SUM(carts > 0) AS cart가_있는_세션상품수,
    SUM(carts > 0 AND has_cart_after_view = 1) AS 같은세션에서_view후_cart확인수,
    SUM(carts > 0 AND has_cart_after_view = 0) AS 같은세션에서_선행view없는_cart수,
    SUM(carts > 0
        AND has_cart_after_view = 0
        AND 이전_view세션_최근종료시각 < session_start)
        AS 이전에끝난세션_view확인_cart수,
    SUM(carts > 0
        AND has_cart_after_view = 0
        AND COALESCE(이전_view세션_최근종료시각 < session_start, 0) = 0)
        AS 현재와이전세션_선행view미확인_cart수,
    SUM(purchases > 0) AS purchase가_있는_세션상품수,
    SUM(purchases > 0 AND has_purchase_after_view_cart = 1)
        AS 같은세션에서_view_cart_purchase순차확인수,
    SUM(purchases > 0 AND has_purchase_after_view_cart = 0)
        AS 같은세션에서_완전순차미확인_purchase수,
    SUM(purchases > 0
        AND has_purchase_after_view_cart = 0
        AND 이전_view세션_최근종료시각 < session_start)
        AS 이전에끝난세션_view확인_purchase수,
    SUM(purchases > 0
        AND has_purchase_after_view_cart = 0
        AND 이전_cart세션_최근종료시각 < session_start)
        AS 이전에끝난세션_cart확인_purchase수,
    SUM(purchases > 0
        AND has_purchase_after_view_cart = 0
        AND 이전_view후cart세션_최근종료시각 < session_start)
        AS 이전에끝난세션_view_cart순차확인_purchase수
FROM prior_session_check

-- name: jn_prior_sensitivity | 겹치는 세션 포함 여부에 따른 이전 view 확인 범위
-- 분석 단위는 같은 세션에서 선행 view가 확인되지 않은 cart 세션·상품 조합이다.
-- 보수 기준은 앞선 view 세션이 모두 현재 세션 전에 끝난 경우, 느슨한 기준은 view 세션이 먼저 시작한 경우다.
WITH session_product_base AS (
    SELECT
        m.user_id,
        sp.product_id,
        sp.user_session,
        m.session_start,
        m.session_end,
        sp.views,
        sp.carts,
        sp.has_cart_after_view
    FROM mart_session_product sp
    JOIN mart_session m ON sp.user_session = m.user_session
), previous_view_check AS (
    SELECT
        session_product_base.*,
        MAX(CASE WHEN views > 0 THEN session_end END) OVER (
            PARTITION BY user_id, product_id
            ORDER BY session_start, user_session
            ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
        ) AS 이전_view세션_최근종료시각,
        MIN(CASE WHEN views > 0 THEN session_start END) OVER (
            PARTITION BY user_id, product_id
            ORDER BY session_start, user_session
            ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
        ) AS 이전_view세션_최초시작시각
    FROM session_product_base
), cart_target AS (
    SELECT
        DATE_FORMAT(session_start, '%Y-%m') AS 기준월,
        session_start,
        이전_view세션_최근종료시각,
        이전_view세션_최초시작시각
    FROM previous_view_check
    WHERE carts > 0
      AND has_cart_after_view = 0
)
SELECT
    COALESCE(기준월, '전체') AS 기준월,
    COUNT(*) AS 선행view미확인_cart수,
    SUM(COALESCE(이전_view세션_최근종료시각 < session_start, 0))
        AS 보수기준_이전view확인수,
    SUM(COALESCE(이전_view세션_최초시작시각 < session_start, 0))
        AS 느슨기준_이전view확인수
FROM cart_target
GROUP BY 기준월 WITH ROLLUP

-- name: jn_prior_gap | 이전 행동 세션과 현재 행동 세션 사이의 시간
-- 정확한 이벤트 간격이 아니라 이전 세션 종료와 현재 세션 시작 사이의 빈 시간을 계산한다.
WITH session_product_base AS (
    SELECT
        m.user_id,
        sp.product_id,
        sp.user_session,
        m.session_start,
        m.session_end,
        sp.views,
        sp.carts,
        sp.purchases,
        sp.has_cart_after_view,
        sp.has_purchase_after_view_cart
    FROM mart_session_product sp
    JOIN mart_session m ON sp.user_session = m.user_session
), previous_action_check AS (
    SELECT
        session_product_base.*,
        -- 현재 행보다 앞선 view 세션들의 session_end 중 가장 최근 시각
        MAX(CASE WHEN views > 0 THEN session_end END) OVER (
            PARTITION BY user_id, product_id
            ORDER BY session_start, user_session
            ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
        ) AS 이전_view세션_최근종료시각,
        -- 현재 행보다 앞선 view → cart 완료 세션들의 session_end 중 가장 최근 시각
        MAX(CASE WHEN has_cart_after_view = 1 THEN session_end END) OVER (
            PARTITION BY user_id, product_id
            ORDER BY session_start, user_session
            ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
        ) AS 이전_view후cart세션_최근종료시각
    FROM session_product_base
), session_gap AS (
    SELECT
        '이전 view → 현재 cart' AS 행동연결,
        TIMESTAMPDIFF(
            HOUR,
            이전_view세션_최근종료시각,
            session_start
        ) AS 세션사이_경과시간
    FROM previous_action_check
    WHERE carts > 0
      AND has_cart_after_view = 0
      AND 이전_view세션_최근종료시각 < session_start

    UNION ALL

    SELECT
        '이전 view→cart → 현재 purchase' AS 행동연결,
        TIMESTAMPDIFF(
            HOUR,
            이전_view후cart세션_최근종료시각,
            session_start
        ) AS 세션사이_경과시간
    FROM previous_action_check
    WHERE purchases > 0
      AND has_purchase_after_view_cart = 0
      AND 이전_view후cart세션_최근종료시각 < session_start
)
SELECT
    행동연결,
    CASE
        WHEN 세션사이_경과시간 < 24 THEN '24시간 미만'
        WHEN 세션사이_경과시간 < 96 THEN '1-3일'
        WHEN 세션사이_경과시간 < 192 THEN '4-7일'
        WHEN 세션사이_경과시간 < 360 THEN '8-14일'
        WHEN 세션사이_경과시간 < 744 THEN '15-30일'
        ELSE '31일 이상'
    END AS 기간구간,
    COUNT(*) AS 세션상품_조합수,
    MIN(세션사이_경과시간) AS 최소간격_시간,
    MAX(세션사이_경과시간) AS 최대간격_시간,
    AVG(세션사이_경과시간) AS 평균간격_시간
FROM session_gap
GROUP BY 행동연결, 기간구간
ORDER BY
    FIELD(
        행동연결,
        '이전 view → 현재 cart',
        '이전 view→cart → 현재 purchase'
    ),
    MIN(세션사이_경과시간)
