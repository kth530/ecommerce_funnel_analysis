-- 06 세션 간 구매 여정 분석
-- 분석 집계는 02에서 raw 대조 검증을 통과한 mart_user_product_session과 기존 검증 마트만 소비한다.
-- 관측 첫 구매·반복 구매는 관측 기간 안의 구분이며 생애 구매 차수를 뜻하지 않는다.
-- 경로는 현재 최초 purchase보다 앞선 strict 행동만 연결하고, 이전 purchase에서 에피소드를 끊는다.

-- name: pj_session_benchmark | 04 세션 내 strict 3단계 완주율 기준값
-- 분석 단위는 view 도달 세션이다. 06의 사용자·상품 N일 지표와 정의가 다른 비교 기준이다.
SELECT
    SUM(views > 0) AS view도달_세션수,
    SUM(has_purchase_after_view_cart) AS 동일세션_view_cart_purchase수,
    SUM(has_purchase_after_view_cart) / SUM(views > 0) * 100
        AS 동일세션_view_cart_purchase완주율_pct
FROM mart_session;

-- name: pj_journey_scope | 06 구매 여정 마트 모집단 게이트
-- 분석 단위는 세션·상품이다. 배타적 경로 집계와 다중 purchase 규모를 대조한다.
SELECT
    COUNT(*) AS 전체_세션상품수,
    SUM(purchases > 0) AS 구매_세션상품수,
    SUM(purchases) AS purchase_이벤트수,
    SUM(purchases > 1) AS 다중purchase_세션상품수
FROM mart_user_product_session;

-- name: pj_user_product_window | 사용자·상품 최초 view 이후 1·7·30일 구매 도달
-- 분석 단위는 관측 기간 내 최초 view가 있는 사용자·상품(user_id × product_id)이다.
-- 각 N일 분모는 최초 view 이후 N일을 관측 종료일까지 모두 볼 수 있는 조합만 포함한다.
-- 다중 purchase 세션·상품은 first/last_purchase_at 중 최초 view 이후 시각으로 도달 여부를 보완한다.
WITH observation_period AS (
    SELECT MAX(session_end) AS 전체관측_종료시각
    FROM mart_user_product_session
), user_product_first_view AS (
    SELECT
        user_id,
        product_id,
        MIN(first_view_at) AS 사용자상품_최초view시각
    FROM mart_user_product_session
    WHERE first_view_at IS NOT NULL
    GROUP BY user_id, product_id
), user_product_purchase_after_view AS (
    SELECT
        first_view.user_id,
        first_view.product_id,
        first_view.사용자상품_최초view시각,
        MIN(CASE
            WHEN journey.first_purchase_at > first_view.사용자상품_최초view시각
                THEN journey.first_purchase_at
            WHEN journey.purchases > 1
             AND journey.last_purchase_at > first_view.사용자상품_최초view시각
                THEN journey.last_purchase_at
        END) AS 최초view이후_첫purchase시각,
        MAX(journey.purchases > 1
            AND journey.first_purchase_at <= first_view.사용자상품_최초view시각
            AND journey.last_purchase_at > first_view.사용자상품_최초view시각)
            AS 최초view경계_다중purchase_주의여부,
        CASE
            WHEN product.category_id = 1487580006300255120 THEN '04 우선진단 카테고리'
            ELSE '그 외 카테고리'
        END AS 카테고리구분
    FROM user_product_first_view first_view
    LEFT JOIN mart_user_product_session journey
      ON first_view.user_id = journey.user_id
     AND first_view.product_id = journey.product_id
     AND journey.last_purchase_at > first_view.사용자상품_최초view시각
    LEFT JOIN mart_product product ON first_view.product_id = product.product_id
    GROUP BY
        first_view.user_id,
        first_view.product_id,
        first_view.사용자상품_최초view시각,
        카테고리구분
)
SELECT
    COALESCE(카테고리구분, '전체') AS 카테고리구분,
    COUNT(*) AS view확인_사용자상품수,
    SUM(사용자상품_최초view시각 + INTERVAL 1 DAY <= 전체관측_종료시각)
        AS 1일구매판정가능_사용자상품수,
    SUM(사용자상품_최초view시각 + INTERVAL 1 DAY <= 전체관측_종료시각
        AND 최초view이후_첫purchase시각 <= 사용자상품_최초view시각 + INTERVAL 1 DAY)
        AS 1일_세션통합구매_사용자상품수,
    SUM(사용자상품_최초view시각 + INTERVAL 7 DAY <= 전체관측_종료시각)
        AS 7일구매판정가능_사용자상품수,
    SUM(사용자상품_최초view시각 + INTERVAL 7 DAY <= 전체관측_종료시각
        AND 최초view이후_첫purchase시각 <= 사용자상품_최초view시각 + INTERVAL 7 DAY)
        AS 7일_세션통합구매_사용자상품수,
    SUM(사용자상품_최초view시각 + INTERVAL 30 DAY <= 전체관측_종료시각)
        AS 30일구매판정가능_사용자상품수,
    SUM(사용자상품_최초view시각 + INTERVAL 30 DAY <= 전체관측_종료시각
        AND 최초view이후_첫purchase시각 <= 사용자상품_최초view시각 + INTERVAL 30 DAY)
        AS 30일_세션통합구매_사용자상품수,
    SUM(최초view경계_다중purchase_주의여부)
        AS 다중purchase_경계주의_사용자상품수
FROM user_product_purchase_after_view
CROSS JOIN observation_period
GROUP BY 카테고리구분 WITH ROLLUP
ORDER BY FIELD(COALESCE(카테고리구분, '전체'), '전체', '04 우선진단 카테고리', '그 외 카테고리');

-- name: pj_user_product_same_session_funnel | 동일 분모의 04식 동일 세션 3단계 완주
-- 분석 단위는 최초 view가 있는 사용자·상품(user_id × product_id)이다.
-- 각 N일 구매 판정 가능 조합을 공통 분모로 두고, 같은 세션·동일 상품에서
-- strict view→cart→첫 purchase가 N일 안에 확인된 조합을 분자로 센다.
-- has_view_cart_before_first_purchase를 사용해 최초 purchase까지의 3단계 순서를 확정한다.
WITH observation_period AS (
    SELECT MAX(session_end) AS 전체관측_종료시각
    FROM mart_user_product_session
), user_product_first_view AS (
    SELECT
        user_id,
        product_id,
        MIN(first_view_at) AS 사용자상품_최초view시각
    FROM mart_user_product_session
    WHERE first_view_at IS NOT NULL
    GROUP BY user_id, product_id
), same_session_stage3 AS (
    SELECT
        first_view.user_id,
        first_view.product_id,
        first_view.사용자상품_최초view시각,
        MIN(CASE
            WHEN journey.has_view_cart_before_first_purchase = 1
             AND journey.first_purchase_at > first_view.사용자상품_최초view시각
                THEN journey.first_purchase_at
        END) AS 동일세션_3단계_첫완주시각
    FROM user_product_first_view first_view
    LEFT JOIN mart_user_product_session journey
      ON first_view.user_id = journey.user_id
     AND first_view.product_id = journey.product_id
     AND journey.first_purchase_at > first_view.사용자상품_최초view시각
    GROUP BY
        first_view.user_id,
        first_view.product_id,
        first_view.사용자상품_최초view시각
), window_counts AS (
    SELECT
        '1일' AS 관측창,
        1 AS 관측창_정렬,
        SUM(사용자상품_최초view시각 + INTERVAL 1 DAY <= 전체관측_종료시각)
            AS 구매판정가능_사용자상품조합수,
        SUM(사용자상품_최초view시각 + INTERVAL 1 DAY <= 전체관측_종료시각
            AND 동일세션_3단계_첫완주시각 <= 사용자상품_최초view시각 + INTERVAL 1 DAY)
            AS 동일세션_3단계완주_사용자상품조합수
    FROM same_session_stage3
    CROSS JOIN observation_period

    UNION ALL

    SELECT
        '7일' AS 관측창,
        7 AS 관측창_정렬,
        SUM(사용자상품_최초view시각 + INTERVAL 7 DAY <= 전체관측_종료시각)
            AS 구매판정가능_사용자상품조합수,
        SUM(사용자상품_최초view시각 + INTERVAL 7 DAY <= 전체관측_종료시각
            AND 동일세션_3단계_첫완주시각 <= 사용자상품_최초view시각 + INTERVAL 7 DAY)
            AS 동일세션_3단계완주_사용자상품조합수
    FROM same_session_stage3
    CROSS JOIN observation_period

    UNION ALL

    SELECT
        '30일' AS 관측창,
        30 AS 관측창_정렬,
        SUM(사용자상품_최초view시각 + INTERVAL 30 DAY <= 전체관측_종료시각)
            AS 구매판정가능_사용자상품조합수,
        SUM(사용자상품_최초view시각 + INTERVAL 30 DAY <= 전체관측_종료시각
            AND 동일세션_3단계_첫완주시각 <= 사용자상품_최초view시각 + INTERVAL 30 DAY)
            AS 동일세션_3단계완주_사용자상품조합수
    FROM same_session_stage3
    CROSS JOIN observation_period
)
SELECT
    관측창 AS 구매확인기간,
    구매판정가능_사용자상품조합수
        AS 구매판정가능_사용자상품수,
    동일세션_3단계완주_사용자상품조합수
        AS 동일세션_view_cart_purchase완주_사용자상품수
FROM window_counts
ORDER BY 관측창_정렬;

-- name: pj_purchase_paths | 구매 차수·경로·사용자 유형별 배타적 구매 분류
-- 분석 단위는 purchase가 1건 이상 있는 세션·상품이다.
-- 가장 가까운 선행 cart/view를 찾되 이전 purchase보다 오래된 행동은 현재 에피소드에서 제외한다.
WITH user_sessions AS (
    SELECT
        user_id,
        COUNT(*) AS 관측세션수
    FROM mart_session
    GROUP BY user_id
), purchase_rows AS (
    SELECT
        p.*,
        CASE
            WHEN mp.category_id = 1487580006300255120 THEN '04 우선진단 카테고리'
            ELSE '그 외 카테고리'
        END AS 카테고리구분,
        CASE WHEN u.관측세션수 = 1 THEN '1세션 사용자' ELSE '2+세션 사용자' END AS 사용자유형
    FROM mart_user_product_session p
    JOIN user_sessions u ON p.user_id = u.user_id
    LEFT JOIN mart_product mp ON p.product_id = mp.product_id
    WHERE p.purchases > 0
), episode_context AS (
    SELECT
        p.user_session,
        p.product_id,
        p.user_id,
        p.first_purchase_at,
        p.last_purchase_at,
        p.purchases,
        p.revenue,
        p.first_view_at,
        p.last_view_before_first_purchase_at AS 현재세션_구매전view,
        p.last_cart_before_first_purchase_at AS 현재세션_구매전cart,
        p.has_view_cart_before_first_purchase,
        p.카테고리구분,
        p.사용자유형,
        MAX(CASE
            WHEN a.last_purchase_at < p.first_purchase_at THEN a.last_purchase_at
        END) AS 이전purchase_최근시각,
        MAX(CASE
            WHEN a.user_session = p.user_session THEN p.last_view_before_first_purchase_at
            WHEN a.last_view_at < p.first_purchase_at THEN a.last_view_at
        END) AS 구매전view_최근시각,
        MAX(CASE
            WHEN a.user_session = p.user_session THEN p.last_cart_before_first_purchase_at
            WHEN a.last_cart_at < p.first_purchase_at THEN a.last_cart_at
        END) AS 구매전cart_최근시각
    FROM purchase_rows p
    LEFT JOIN mart_user_product_session a
      ON p.user_id = a.user_id
     AND p.product_id = a.product_id
    GROUP BY
        p.user_session,
        p.product_id,
        p.user_id,
        p.first_purchase_at,
        p.last_purchase_at,
        p.purchases,
        p.revenue,
        p.first_view_at,
        p.last_view_before_first_purchase_at,
        p.last_cart_before_first_purchase_at,
        p.has_view_cart_before_first_purchase,
        p.카테고리구분,
        p.사용자유형
), path_flags AS (
    SELECT
        *,
        CASE
            WHEN 이전purchase_최근시각 IS NULL THEN '관측 첫 구매'
            ELSE '관측 반복 구매'
        END AS 구매차수,

        -- 공통 분석 구간
        -- 이전 purchase │ 이번 구매에 연결할 view·cart │ 현재 purchase
        --               └────── 이번 구매 행동 구간 ──────┘

        -- 현재 세션의 view·cart가 이번 구매 행동 구간 안에 있는지 확인한다.
        -- 이전 purchase │ [현재 세션] view → cart │ [현재 세션] purchase
        --               └──────── 이번 구매 행동 구간 ────────┘
        -- 실제 view → cart → purchase 순서의 존재 여부는 classified에서 별도로 결합한다.
        CASE
            WHEN 이전purchase_최근시각 IS NULL
              OR (first_view_at > 이전purchase_최근시각
                  AND 현재세션_구매전cart > 이전purchase_최근시각)
                THEN 1
            ELSE 0
        END AS 현재세션_view_cart_이번구매구간,

        -- 가장 최근 cart가 이번 구매 행동 구간 안에 있는지 확인한다. 이 단계에서는 세션을 구분하지 않는다.
        -- 이전 purchase │ [세션 미정] 최근 cart │ [현재 세션] purchase
        --               └────── 이번 구매 행동 구간 ──────┘
        CASE
            WHEN 구매전cart_최근시각 IS NOT NULL
             AND (이전purchase_최근시각 IS NULL
                  OR 구매전cart_최근시각 > 이전purchase_최근시각)
                THEN 1
            ELSE 0
        END AS 최근cart_이번구매구간,

        -- 가장 최근 cart가 현재 purchase 세션과 다른 세션에서 발생했는지 확인한다.
        -- 이전 purchase │ [다른 세션] 최근 cart │ [현재 세션] purchase
        --               └────── 이번 구매 행동 구간 ──────┘
        CASE
            WHEN 현재세션_구매전cart IS NULL
              OR 구매전cart_최근시각 <> 현재세션_구매전cart
                THEN 1
            ELSE 0
        END AS 최근cart_다른세션,

        -- 현재 세션의 cart가 이번 구매 행동 구간 안에 있는지 확인한다.
        -- 이전 purchase │ [현재 세션] cart → purchase
        --               └── 이번 구매 행동 구간 ──┘
        CASE
            WHEN 현재세션_구매전cart IS NOT NULL
             AND (이전purchase_최근시각 IS NULL
                  OR 현재세션_구매전cart > 이전purchase_최근시각)
                THEN 1
            ELSE 0
        END AS 현재세션_cart_이번구매구간,

        -- 가장 최근 view가 이번 구매 행동 구간 안에 있는지 확인한다. 이 단계에서는 세션을 구분하지 않는다.
        -- 이전 purchase │ [세션 미정] 최근 view │ [현재 세션] purchase
        --               └────── 이번 구매 행동 구간 ──────┘
        CASE
            WHEN 구매전view_최근시각 IS NOT NULL
             AND (이전purchase_최근시각 IS NULL
                  OR 구매전view_최근시각 > 이전purchase_최근시각)
                THEN 1
            ELSE 0
        END AS 최근view_이번구매구간,

        -- 가장 최근 view가 현재 purchase 세션과 다른 세션에서 발생했는지 확인한다.
        -- 이전 purchase │ [다른 세션] 최근 view │ [현재 세션] purchase
        --               └────── 이번 구매 행동 구간 ──────┘
        CASE
            WHEN 현재세션_구매전view IS NULL
              OR 구매전view_최근시각 <> 현재세션_구매전view
                THEN 1
            ELSE 0
        END AS 최근view_다른세션,

        -- 현재 세션의 view가 이번 구매 행동 구간 안에 있는지 확인한다.
        -- 이전 purchase │ [현재 세션] view → purchase
        --               └── 이번 구매 행동 구간 ──┘
        CASE
            WHEN 현재세션_구매전view IS NOT NULL
             AND (이전purchase_최근시각 IS NULL
                  OR 현재세션_구매전view > 이전purchase_최근시각)
                THEN 1
            ELSE 0
        END AS 현재세션_view_이번구매구간
    FROM episode_context
), classified AS (
    SELECT
        *,
        CASE
            WHEN has_view_cart_before_first_purchase = 1
             AND 현재세션_view_cart_이번구매구간 = 1
                THEN '현재 구매 세션 view→cart→purchase'
            WHEN 최근cart_이번구매구간 = 1
             AND 최근cart_다른세션 = 1
                THEN '다른 세션 cart→현재 purchase'
            WHEN 현재세션_cart_이번구매구간 = 1
                THEN '현재 구매 세션 cart→purchase'
            WHEN 최근view_이번구매구간 = 1
             AND 최근view_다른세션 = 1
                THEN '다른 세션 view→현재 purchase'
            WHEN 현재세션_view_이번구매구간 = 1
                THEN '현재 구매 세션 view→purchase'
            ELSE '구매 전 view·cart 미확인'
        END AS 구매경로
    FROM path_flags
)
SELECT
    구매차수,
    구매경로,
    카테고리구분,
    사용자유형,
    COUNT(*) AS 구매_세션상품수,
    SUM(purchases) AS purchase_이벤트수,
    SUM(revenue) AS revenue,
    SUM(purchases > 1) AS 다중purchase_세션상품수
FROM classified
GROUP BY 구매차수, 구매경로, 카테고리구분, 사용자유형
ORDER BY
    FIELD(구매차수, '관측 첫 구매', '관측 반복 구매'),
    FIELD(
        구매경로,
        '현재 구매 세션 view→cart→purchase',
        '다른 세션 cart→현재 purchase',
        '현재 구매 세션 cart→purchase',
        '다른 세션 view→현재 purchase',
        '현재 구매 세션 view→purchase',
        '구매 전 view·cart 미확인'
    ),
    카테고리구분,
    사용자유형;

-- name: pj_cross_session_cart_delay | 다른 세션 cart와 현재 purchase의 실제 이벤트 간격
-- 분석 단위는 구매 에피소드다. 이전 purchase 이후의 가장 가까운 cart가 다른 세션에 있는 경우만 센다.
WITH purchase_rows AS (
    SELECT *
    FROM mart_user_product_session
    WHERE purchases > 0
), episode_context AS (
    SELECT
        p.user_session,
        p.product_id,
        p.user_id,
        p.first_purchase_at,
        p.first_view_at,
        p.has_view_cart_before_first_purchase,
        p.last_cart_before_first_purchase_at AS 현재세션_구매전cart,
        MAX(CASE
            WHEN a.last_purchase_at < p.first_purchase_at THEN a.last_purchase_at
        END) AS 이전purchase_최근시각,
        MAX(CASE
            WHEN a.user_session = p.user_session THEN p.last_cart_before_first_purchase_at
            WHEN a.last_cart_at < p.first_purchase_at THEN a.last_cart_at
        END) AS 구매전cart_최근시각
    FROM purchase_rows p
    LEFT JOIN mart_user_product_session a
      ON p.user_id = a.user_id
     AND p.product_id = a.product_id
    GROUP BY
        p.user_session,
        p.product_id,
        p.user_id,
        p.first_purchase_at,
        p.first_view_at,
        p.has_view_cart_before_first_purchase,
        p.last_cart_before_first_purchase_at
), cross_session AS (
    SELECT
        CASE
            WHEN 이전purchase_최근시각 IS NULL THEN '관측 첫 구매'
            ELSE '관측 반복 구매'
        END AS 구매차수,
        TIMESTAMPDIFF(SECOND, 구매전cart_최근시각, first_purchase_at) / 3600.0 AS 경과시간
    FROM episode_context
    WHERE 구매전cart_최근시각 IS NOT NULL
      AND (이전purchase_최근시각 IS NULL OR 구매전cart_최근시각 > 이전purchase_최근시각)
      AND (현재세션_구매전cart IS NULL OR 구매전cart_최근시각 <> 현재세션_구매전cart)
      AND NOT (
          has_view_cart_before_first_purchase = 1
          AND (이전purchase_최근시각 IS NULL
               OR (first_view_at > 이전purchase_최근시각
                   AND 현재세션_구매전cart > 이전purchase_최근시각))
      )
)
SELECT
    구매차수,
    CASE
        WHEN 경과시간 < 1 THEN '1시간 미만'
        WHEN 경과시간 < 6 THEN '1-6시간'
        WHEN 경과시간 < 12 THEN '6-12시간'
        WHEN 경과시간 < 24 THEN '12-24시간'
        WHEN 경과시간 < 24 * 3 THEN '1-3일'
        WHEN 경과시간 < 24 * 7 THEN '4-7일'
        WHEN 경과시간 < 24 * 14 THEN '8-14일'
        WHEN 경과시간 < 24 * 30 THEN '15-30일'
        ELSE '31일 이상'
    END AS 기간구간,
    COUNT(*) AS 구매에피소드수,
    MIN(경과시간) AS 최소_시간,
    MAX(경과시간) AS 최대_시간,
    AVG(경과시간) AS 평균_시간
FROM cross_session
GROUP BY 구매차수, 기간구간
ORDER BY
    FIELD(구매차수, '관측 첫 구매', '관측 반복 구매'),
    FIELD(
        기간구간,
        '1시간 미만', '1-6시간', '6-12시간', '12-24시간',
        '1-3일', '4-7일', '8-14일', '15-30일', '31일 이상'
    );

-- name: pj_remove_prior_cart | cart·purchase 없는 remove의 직전 동일 상품 상태·월별 미확인 확인
-- 분석 단위는 remove가 있으나 같은 세션·상품에 cart·purchase가 없는 세션·상품이다.
-- 과거 cart 존재 여부는 넓은 참고값이고, 직전 상태 이벤트가 cart인 경우를 더 강한 이월 후보로 본다.
-- 동일 초에 서로 다른 상태 이벤트가 있으면 순서를 알 수 없으므로 별도 경계 사례로 분류한다.
WITH remove_target AS (
    SELECT *
    FROM mart_user_product_session
    WHERE removes > 0
      AND carts = 0
      AND purchases = 0
), prior_check AS (
    SELECT
        r.user_session,
        r.product_id,
        r.user_id,
        r.first_remove_at,
        MAX(CASE WHEN a.last_cart_at < r.first_remove_at THEN a.last_cart_at END) AS 이전cart_최근시각,
        MAX(CASE WHEN a.last_purchase_at < r.first_remove_at THEN a.last_purchase_at END) AS 이전purchase_최근시각,
        MAX(CASE WHEN a.last_remove_at < r.first_remove_at THEN a.last_remove_at END) AS 이전remove_최근시각
    FROM remove_target r
    LEFT JOIN mart_user_product_session a
      ON r.user_id = a.user_id
     AND r.product_id = a.product_id
    GROUP BY r.user_session, r.product_id, r.user_id, r.first_remove_at
), latest_prior_state AS (
    SELECT
        prior_check.*,
        DATE_FORMAT(first_remove_at, '%Y-%m') AS remove월,
        CASE
            WHEN 이전cart_최근시각 IS NULL
             AND 이전purchase_최근시각 IS NULL
             AND 이전remove_최근시각 IS NULL
                THEN '이전 상태 이벤트 미확인'
            WHEN 이전cart_최근시각 IS NOT NULL
             AND (이전purchase_최근시각 IS NULL
                  OR 이전cart_최근시각 > 이전purchase_최근시각)
             AND (이전remove_최근시각 IS NULL
                  OR 이전cart_최근시각 > 이전remove_최근시각)
                THEN '직전 상태 이벤트 cart'
            WHEN 이전purchase_최근시각 IS NOT NULL
             AND (이전cart_최근시각 IS NULL
                  OR 이전purchase_최근시각 > 이전cart_최근시각)
             AND (이전remove_최근시각 IS NULL
                  OR 이전purchase_최근시각 > 이전remove_최근시각)
                THEN '직전 상태 이벤트 purchase'
            WHEN 이전remove_최근시각 IS NOT NULL
             AND (이전cart_최근시각 IS NULL
                  OR 이전remove_최근시각 > 이전cart_최근시각)
             AND (이전purchase_최근시각 IS NULL
                  OR 이전remove_최근시각 > 이전purchase_최근시각)
                THEN '직전 상태 이벤트 remove'
            ELSE '동일 시각 순서 주의'
        END AS 직전상태_유형
    FROM prior_check
)
SELECT
    IF(GROUPING(remove월) = 1, '전체', remove월) AS remove월,
    COUNT(*) AS remove_only_세션상품수,
    -- 넓은 참고값: remove 이전 어느 시점에든 해당 상태 이벤트가 한 번 이상 있었는가
    SUM(이전cart_최근시각 IS NOT NULL) AS 이전cart_확인수,
    SUM(이전purchase_최근시각 IS NOT NULL) AS 이전purchase_확인수,
    SUM(이전remove_최근시각 IS NOT NULL) AS 이전remove_확인수,
    SUM(이전cart_최근시각 IS NULL) AS 이전cart_미확인수,
    -- 더 강한 상태 후보: remove 직전의 가장 최근 cart·purchase·remove 중 무엇이었는가
    SUM(직전상태_유형 = '직전 상태 이벤트 cart') AS 직전상태_cart수,
    SUM(직전상태_유형 = '직전 상태 이벤트 purchase') AS 직전상태_purchase수,
    SUM(직전상태_유형 = '직전 상태 이벤트 remove') AS 직전상태_remove수,
    SUM(직전상태_유형 = '이전 상태 이벤트 미확인') AS 직전상태_미확인수,
    SUM(직전상태_유형 = '동일 시각 순서 주의') AS 직전상태_동일시각주의수
FROM latest_prior_state
GROUP BY remove월 WITH ROLLUP;

-- name: pj_experiment_baseline | cart+24시간 CRM 실험 적격 사용자와 7일 구매 기준선
-- 분석 단위는 사용자별 최초 관측 cart 한 건이다. 실험의 user_id 무작위 배정 단위와 맞춘다.
-- first_cart_at은 세션·상품 안의 최초 cart 시각이므로 운영 시스템의 개별 cart 트리거를 근사한다.
-- 사용자별 최초 cart 이후 24시간 안에 동일 상품 purchase가 있으면 이번 실험 모집단에서 제외한다.
-- 이후 cart에 재진입시키지 않는 1회성 설계이므로 전체 적격 규모의 보수적 하한에 가깝다.
-- remove·후속 cart·수신 동의·상품 판매 상태는 현재 마트로 확정하지 않고 실제 발송 직전에 확인한다.
-- 주지표 기준점은 cart+24시간이며, 기준점 이후 7일을 끝까지 관측할 수 있는 사용자만 포함한다.
WITH observation_period AS (
    SELECT MAX(session_end) AS 전체관측_종료시각
    FROM mart_user_product_session
), first_cart_time_per_user AS (
    SELECT
        user_id,
        MIN(first_cart_at) AS cart_기준시각
    FROM mart_user_product_session
    WHERE first_cart_at IS NOT NULL
    GROUP BY user_id
), first_cart_per_user AS (
    SELECT
        first_cart.user_id,
        -- 같은 사용자의 여러 상품이 최초 시각에 동시에 찍힌 경우 product_id가 작은 한 건만 대표한다.
        MIN(cart_row.product_id) AS product_id,
        first_cart.cart_기준시각,
        first_cart.cart_기준시각 + INTERVAL 1 DAY AS 실험적격_기준시각
    FROM first_cart_time_per_user first_cart
    JOIN mart_user_product_session cart_row
      ON first_cart.user_id = cart_row.user_id
     AND first_cart.cart_기준시각 = cart_row.first_cart_at
    GROUP BY first_cart.user_id, first_cart.cart_기준시각
), selected_cart_context AS (
    SELECT
        selected.user_id,
        selected.product_id,
        selected.cart_기준시각,
        selected.실험적격_기준시각,
        period.전체관측_종료시각,
        MIN(CASE
            WHEN history.first_purchase_at > selected.cart_기준시각
                THEN history.first_purchase_at
            WHEN history.last_purchase_at > selected.cart_기준시각
                THEN history.last_purchase_at
        END) AS cart이후_다음purchase시각,
        MAX(history.first_purchase_at < selected.cart_기준시각)
            AS cart이전_동일상품구매여부,
        MAX(
            history.purchases > 1
            AND history.first_purchase_at <= selected.실험적격_기준시각
            AND history.last_purchase_at > selected.실험적격_기준시각
        ) AS 다중purchase_기준시각경계주의여부
    FROM first_cart_per_user selected
    CROSS JOIN observation_period period
    LEFT JOIN mart_user_product_session history
      ON selected.user_id = history.user_id
     AND selected.product_id = history.product_id
     AND history.purchases > 0
    GROUP BY
        selected.user_id,
        selected.product_id,
        selected.cart_기준시각,
        selected.실험적격_기준시각,
        period.전체관측_종료시각
), eligible_users AS (
    SELECT
        selected_cart_context.*
    FROM selected_cart_context
    WHERE 실험적격_기준시각 + INTERVAL 7 DAY <= 전체관측_종료시각
      AND (
          cart이후_다음purchase시각 IS NULL
          OR cart이후_다음purchase시각 > 실험적격_기준시각
      )
)
SELECT
    DATE(실험적격_기준시각) AS 실험적격일,
    CASE
        WHEN cart이전_동일상품구매여부 = 1 THEN '관측 반복 구매 후보'
        ELSE '관측 첫 구매 후보'
    END AS 구매차수_사전세그먼트,
    COUNT(*) AS 실험적격_사용자수,
    SUM(
        cart이후_다음purchase시각 > 실험적격_기준시각
        AND cart이후_다음purchase시각
            <= 실험적격_기준시각 + INTERVAL 7 DAY
    ) AS 기준점후_7일_동일상품구매_사용자수,
    SUM(
        실험적격_기준시각 + INTERVAL 30 DAY <= 전체관측_종료시각
    ) AS 기준점후_30일_판정가능_사용자수,
    SUM(
        실험적격_기준시각 + INTERVAL 30 DAY <= 전체관측_종료시각
        AND cart이후_다음purchase시각 > 실험적격_기준시각
        AND cart이후_다음purchase시각
            <= 실험적격_기준시각 + INTERVAL 30 DAY
    ) AS 기준점후_30일_동일상품구매_사용자수,
    SUM(다중purchase_기준시각경계주의여부)
        AS 다중purchase_기준시각경계주의_사용자수
FROM eligible_users
GROUP BY 실험적격일, 구매차수_사전세그먼트
ORDER BY 실험적격일, 구매차수_사전세그먼트;
