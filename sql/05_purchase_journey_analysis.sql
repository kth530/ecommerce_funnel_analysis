-- 05 대표 첫 구매 여정 분석
-- 구매 경로의 분석 단위는 user_id × product_id다.
-- 대표 구매는 최초 view < purchase_at <= 최초 view + 30일인 가장 빠른 동일 상품 purchase다.
-- 마트의 최초·최종 시각 사이에 기준 시점이 있는 다중 purchase는 raw events로 보완한다.
-- 최초 cart 시간 지표도 같은 원칙으로 경계를 분리하고, 관련 세션의 31일 범위만 raw 조회한다.

-- name: pj_30day_purchase_cohort | 경로 분류와 독립된 30일 대표 첫 구매 cohort 집계
-- 최종 cohort는 이 쿼리의 마트 확정 수에 raw에서 적격 purchase가 확인된
-- 대표 구매 시각 경계 수를 더해 계산하며, path_order나 경로 행 수를 사용하지 않는다.
WITH observation_period AS (
    SELECT MAX(session_end) AS observation_end_at
    FROM mart_user_product_session
), user_product_first_view AS (
    SELECT
        user_id,
        product_id,
        MIN(first_view_at) AS anchor_view_at
    FROM mart_user_product_session
    WHERE first_view_at IS NOT NULL
    GROUP BY user_id, product_id
), eligible_anchors AS (
    SELECT
        first_view.user_id,
        first_view.product_id,
        first_view.anchor_view_at
    FROM user_product_first_view first_view
    CROSS JOIN observation_period period
    WHERE first_view.anchor_view_at + INTERVAL 30 DAY
        <= period.observation_end_at
), purchase_context AS (
    SELECT
        anchor.user_id,
        anchor.product_id,
        anchor.anchor_view_at,
        MIN(CASE
            WHEN journey.first_purchase_at > anchor.anchor_view_at
             AND journey.first_purchase_at
                    <= anchor.anchor_view_at + INTERVAL 30 DAY
                THEN journey.first_purchase_at
        END) AS mart_representative_purchase_at,
        COALESCE(MAX(
            journey.purchases > 1
            AND journey.first_purchase_at <= anchor.anchor_view_at
            AND journey.last_purchase_at > anchor.anchor_view_at
        ), 0) AS purchase_boundary_flag
    FROM eligible_anchors anchor
    LEFT JOIN mart_user_product_session journey
      ON anchor.user_id = journey.user_id
     AND anchor.product_id = journey.product_id
     AND journey.last_purchase_at > anchor.anchor_view_at
     AND journey.first_purchase_at
            <= anchor.anchor_view_at + INTERVAL 30 DAY
    GROUP BY
        anchor.user_id,
        anchor.product_id,
        anchor.anchor_view_at
)
SELECT
    COUNT(*) AS 관측가능30일_사용자상품수,
    SUM(
        purchase_boundary_flag = 0
        AND mart_representative_purchase_at IS NOT NULL
    ) AS 마트확정_대표첫구매_사용자상품수,
    SUM(purchase_boundary_flag = 1)
        AS 대표구매시각_raw경계후보_사용자상품수
FROM purchase_context;

-- name: pj_representative_purchase_mart | 대표 첫 구매의 마트 확정 경로와 raw 확인 경계
-- 마지막 purchase가 anchor+30일 밖이더라도 first_purchase <= anchor < last_purchase면
-- 중간 purchase의 30일 내 존재 여부를 알 수 없으므로 raw 경계로 남긴다.
WITH observation_period AS (
    SELECT MAX(session_end) AS observation_end_at
    FROM mart_user_product_session
), user_product_first_view AS (
    SELECT
        user_id,
        product_id,
        MIN(first_view_at) AS anchor_view_at
    FROM mart_user_product_session
    WHERE first_view_at IS NOT NULL
    GROUP BY user_id, product_id
), eligible_anchors AS (
    SELECT
        first_view.user_id,
        first_view.product_id,
        first_view.anchor_view_at
    FROM user_product_first_view first_view
    CROSS JOIN observation_period period
    WHERE first_view.anchor_view_at + INTERVAL 30 DAY
        <= period.observation_end_at
), purchase_context AS (
    SELECT
        anchor.user_id,
        anchor.product_id,
        anchor.anchor_view_at,
        MIN(CASE
            WHEN journey.first_purchase_at > anchor.anchor_view_at
             AND journey.first_purchase_at
                    <= anchor.anchor_view_at + INTERVAL 30 DAY
                THEN journey.first_purchase_at
        END) AS mart_representative_purchase_at,
        COALESCE(MAX(
            journey.purchases > 1
            AND journey.first_purchase_at <= anchor.anchor_view_at
            AND journey.last_purchase_at > anchor.anchor_view_at
        ), 0) AS purchase_boundary_flag
    FROM eligible_anchors anchor
    LEFT JOIN mart_user_product_session journey
      ON anchor.user_id = journey.user_id
     AND anchor.product_id = journey.product_id
     AND journey.last_purchase_at > anchor.anchor_view_at
     AND journey.first_purchase_at
            <= anchor.anchor_view_at + INTERVAL 30 DAY
    GROUP BY
        anchor.user_id,
        anchor.product_id,
        anchor.anchor_view_at
), representative_session_key AS (
    SELECT
        context.user_id,
        context.product_id,
        context.anchor_view_at,
        context.mart_representative_purchase_at,
        MIN(journey.user_session) AS representative_session,
        COUNT(DISTINCT journey.user_session) AS representative_session_count
    FROM purchase_context context
    JOIN mart_user_product_session journey
      ON context.user_id = journey.user_id
     AND context.product_id = journey.product_id
     AND context.mart_representative_purchase_at = journey.first_purchase_at
    WHERE context.purchase_boundary_flag = 0
      AND context.mart_representative_purchase_at IS NOT NULL
    GROUP BY
        context.user_id,
        context.product_id,
        context.anchor_view_at,
        context.mart_representative_purchase_at
), mart_representative_session AS (
    SELECT
        representative.user_id,
        representative.product_id,
        representative.anchor_view_at,
        representative.mart_representative_purchase_at,
        representative.representative_session,
        representative.representative_session_count,
        current_session.first_view_at AS current_session_first_view_at,
        current_session.last_cart_before_first_purchase_at
            AS current_session_last_cart_at
    FROM representative_session_key representative
    JOIN mart_user_product_session current_session
      ON representative.representative_session = current_session.user_session
     AND representative.product_id = current_session.product_id
), mart_action_flags AS (
    SELECT
        representative.user_id,
        representative.product_id,
        representative.anchor_view_at,
        representative.mart_representative_purchase_at,
        representative.representative_session,
        representative.representative_session_count,
        representative.current_session_first_view_at,
        representative.current_session_last_cart_at,
        MAX(
            journey.user_session <> representative.representative_session
            AND (
                (
                    journey.first_cart_at > representative.anchor_view_at
                    AND journey.first_cart_at
                        < representative.mart_representative_purchase_at
                )
                OR (
                    journey.last_cart_at > representative.anchor_view_at
                    AND journey.last_cart_at
                        < representative.mart_representative_purchase_at
                )
            )
        ) AS confirmed_previous_session_cart,
        MAX(
            journey.user_session <> representative.representative_session
            AND journey.carts > 2
            AND journey.first_cart_at <= representative.anchor_view_at
            AND journey.last_cart_at
                >= representative.mart_representative_purchase_at
        ) AS middle_cart_boundary_flag
    FROM mart_representative_session representative
    LEFT JOIN mart_user_product_session journey
      ON representative.user_id = journey.user_id
     AND representative.product_id = journey.product_id
     AND journey.carts > 0
    GROUP BY
        representative.user_id,
        representative.product_id,
        representative.anchor_view_at,
        representative.mart_representative_purchase_at,
        representative.representative_session,
        representative.representative_session_count,
        representative.current_session_first_view_at,
        representative.current_session_last_cart_at
)
SELECT
    CASE
        WHEN (
            action.current_session_last_cart_at <= action.anchor_view_at
            OR action.current_session_last_cart_at IS NULL
        )
         AND action.confirmed_previous_session_cart = 0
         AND action.middle_cart_boundary_flag = 1
            THEN 'raw 확인 경계'
        ELSE '마트 확정 경로'
    END AS row_type,
    CASE
        WHEN (
            action.current_session_last_cart_at <= action.anchor_view_at
            OR action.current_session_last_cart_at IS NULL
        )
         AND action.confirmed_previous_session_cart = 0
         AND action.middle_cart_boundary_flag = 1
            THEN NULL
        WHEN action.current_session_last_cart_at > action.anchor_view_at
         AND action.current_session_first_view_at
                < action.current_session_last_cart_at
            THEN 1
        WHEN action.current_session_last_cart_at > action.anchor_view_at
            THEN 2
        WHEN action.confirmed_previous_session_cart = 1
            THEN 3
        ELSE 4
    END AS path_order,
    action.user_id,
    action.product_id,
    action.anchor_view_at,
    CASE
        WHEN (
            action.current_session_last_cart_at <= action.anchor_view_at
            OR action.current_session_last_cart_at IS NULL
        )
         AND action.confirmed_previous_session_cart = 0
         AND action.middle_cart_boundary_flag = 1
            THEN '이전 방문 중간 cart 경계'
        ELSE NULL
    END AS boundary_type,
    action.representative_session_count
FROM mart_action_flags action

UNION ALL

SELECT
    'raw 확인 경계' AS row_type,
    NULL AS path_order,
    context.user_id,
    context.product_id,
    context.anchor_view_at,
    '대표 구매 시각 경계' AS boundary_type,
    NULL AS representative_session_count
FROM purchase_context context
WHERE context.purchase_boundary_flag = 1
ORDER BY row_type, path_order, user_id, product_id;

-- name: pj_boundary_raw_paths | 대표 구매·중간 cart 경계의 raw 경로 보완
-- 입력 키는 pj_representative_purchase_mart에서 식별하며 최종 경로를 하드코딩하지 않는다.
-- 적격 purchase가 없는 대표 구매 시각 후보도 1행으로 반환하고 path_order를 NULL로 둔다.
WITH boundary_keys AS (
    SELECT
        boundary.user_id,
        boundary.product_id,
        boundary.anchor_view_at,
        boundary.boundary_type
    FROM JSON_TABLE(
        :boundary_json,
        '$[*]' COLUMNS (
            user_id BIGINT PATH '$.user_id',
            product_id BIGINT PATH '$.product_id',
            anchor_view_at DATETIME PATH '$.anchor_view_at',
            boundary_type VARCHAR(40) PATH '$.boundary_type'
        )
    ) boundary
), boundary_raw_events AS (
    SELECT
        boundary.user_id,
        boundary.product_id,
        boundary.anchor_view_at,
        event.user_session,
        event.event_time,
        event.event_type
    FROM boundary_keys boundary
    JOIN mart_user_product_session journey
      ON boundary.user_id = journey.user_id
     AND boundary.product_id = journey.product_id
     AND journey.session_end >= boundary.anchor_view_at
     AND journey.session_start
            <= boundary.anchor_view_at + INTERVAL 30 DAY
    JOIN events event FORCE INDEX (idx_repeat_events)
      ON journey.user_session = event.user_session
     AND journey.product_id = event.product_id
     AND event.event_time >= boundary.anchor_view_at
     AND event.event_time
            <= boundary.anchor_view_at + INTERVAL 30 DAY
    WHERE event.price >= 0
      AND event.event_type IN ('view', 'cart', 'purchase')
), representative_purchase AS (
    SELECT
        boundary.user_id,
        boundary.product_id,
        boundary.anchor_view_at,
        boundary.boundary_type,
        MIN(CASE
            WHEN event.event_type = 'purchase'
             AND event.event_time > boundary.anchor_view_at
                THEN event.event_time
        END) AS representative_purchase_at
    FROM boundary_keys boundary
    LEFT JOIN boundary_raw_events event
      ON boundary.user_id = event.user_id
     AND boundary.product_id = event.product_id
     AND boundary.anchor_view_at = event.anchor_view_at
    GROUP BY
        boundary.user_id,
        boundary.product_id,
        boundary.anchor_view_at,
        boundary.boundary_type
), representative_session_key AS (
    SELECT
        representative.user_id,
        representative.product_id,
        representative.anchor_view_at,
        representative.boundary_type,
        representative.representative_purchase_at,
        MIN(event.user_session) AS representative_session,
        COUNT(DISTINCT event.user_session) AS representative_session_count
    FROM representative_purchase representative
    LEFT JOIN boundary_raw_events event
      ON representative.user_id = event.user_id
     AND representative.product_id = event.product_id
     AND representative.anchor_view_at = event.anchor_view_at
     AND representative.representative_purchase_at = event.event_time
     AND event.event_type = 'purchase'
    GROUP BY
        representative.user_id,
        representative.product_id,
        representative.anchor_view_at,
        representative.boundary_type,
        representative.representative_purchase_at
), action_flags AS (
    SELECT
        representative.user_id,
        representative.product_id,
        representative.anchor_view_at,
        representative.boundary_type,
        representative.representative_purchase_at,
        representative.representative_session_count,
        MIN(CASE
            WHEN event.user_session = representative.representative_session
             AND event.event_type = 'view'
             AND event.event_time < representative.representative_purchase_at
                THEN event.event_time
        END) AS current_session_first_view_at,
        MAX(CASE
            WHEN event.user_session = representative.representative_session
             AND event.event_type = 'cart'
             AND event.event_time > representative.anchor_view_at
             AND event.event_time < representative.representative_purchase_at
                THEN event.event_time
        END) AS current_session_last_cart_at,
        MAX(
            event.user_session <> representative.representative_session
            AND event.event_type = 'cart'
            AND event.event_time > representative.anchor_view_at
            AND event.event_time < representative.representative_purchase_at
        ) AS previous_session_cart
    FROM representative_session_key representative
    LEFT JOIN boundary_raw_events event
      ON representative.user_id = event.user_id
     AND representative.product_id = event.product_id
     AND representative.anchor_view_at = event.anchor_view_at
    GROUP BY
        representative.user_id,
        representative.product_id,
        representative.anchor_view_at,
        representative.boundary_type,
        representative.representative_purchase_at,
        representative.representative_session,
        representative.representative_session_count
)
SELECT
    user_id,
    product_id,
    anchor_view_at,
    boundary_type,
    representative_purchase_at,
    representative_purchase_at IS NOT NULL AS eligible_purchase_flag,
    CASE
        WHEN representative_purchase_at IS NULL
            THEN NULL
        WHEN current_session_last_cart_at IS NOT NULL
         AND current_session_first_view_at < current_session_last_cart_at
            THEN 1
        WHEN current_session_last_cart_at IS NOT NULL
            THEN 2
        WHEN previous_session_cart = 1
            THEN 3
        ELSE 4
    END AS path_order,
    representative_session_count,
    (SELECT COUNT(*) FROM boundary_raw_events) AS raw_event_count
FROM action_flags
ORDER BY user_id, product_id, boundary_type;

-- name: pj_cart_purchase_boundaries | 최초 cart가 다중 purchase 최초·최종 시각 사이인 사용자
-- 분석 단위는 사용자별 최초 관측 cart 한 건이며, 동률이면 product_id가 작은 상품을 선택한다.
-- 두 후속 지표의 공통 기반인 cart 이후 7일 관측 가능 사용자만 raw 후보로 남긴다.
WITH observation_period AS (
    SELECT MAX(session_end) AS observation_end_at
    FROM mart_user_product_session
), first_cart_time_per_user AS (
    SELECT
        user_id,
        MIN(first_cart_at) AS cart_anchor_at
    FROM mart_user_product_session
    WHERE first_cart_at IS NOT NULL
    GROUP BY user_id
), first_cart_per_user AS (
    SELECT
        first_cart.user_id,
        MIN(cart_row.product_id) AS product_id,
        first_cart.cart_anchor_at
    FROM first_cart_time_per_user first_cart
    JOIN mart_user_product_session cart_row
      ON first_cart.user_id = cart_row.user_id
     AND first_cart.cart_anchor_at = cart_row.first_cart_at
    GROUP BY first_cart.user_id, first_cart.cart_anchor_at
), boundary_flags AS (
    SELECT
        selected.user_id,
        selected.product_id,
        selected.cart_anchor_at,
        MAX(
            history.purchases > 1
            AND history.first_purchase_at <= selected.cart_anchor_at
            AND history.last_purchase_at > selected.cart_anchor_at
        ) AS purchase_boundary_flag
    FROM first_cart_per_user selected
    CROSS JOIN observation_period period
    LEFT JOIN mart_user_product_session history
      ON selected.user_id = history.user_id
     AND selected.product_id = history.product_id
     AND history.purchases > 0
    WHERE selected.cart_anchor_at + INTERVAL 7 DAY
        <= period.observation_end_at
    GROUP BY
        selected.user_id,
        selected.product_id,
        selected.cart_anchor_at
)
SELECT
    user_id,
    product_id,
    cart_anchor_at
FROM boundary_flags
WHERE purchase_boundary_flag = 1
ORDER BY user_id, product_id;

-- name: pj_cart_boundary_raw_next_purchase | 최초 cart 다중 purchase 경계의 실제 다음 purchase
-- 두 후속 지표의 최대 판정 범위인 cart+31일까지 관련 세션·상품만 idx_repeat_events로 조회한다.
WITH boundary_keys AS (
    SELECT
        boundary.user_id,
        boundary.product_id,
        boundary.cart_anchor_at
    FROM JSON_TABLE(
        :cart_boundary_json,
        '$[*]' COLUMNS (
            user_id BIGINT PATH '$.user_id',
            product_id BIGINT PATH '$.product_id',
            cart_anchor_at DATETIME PATH '$.cart_anchor_at'
        )
    ) boundary
), boundary_raw_purchases AS (
    SELECT
        boundary.user_id,
        boundary.product_id,
        boundary.cart_anchor_at,
        event.event_time AS purchase_at
    FROM boundary_keys boundary
    JOIN mart_user_product_session journey
      ON boundary.user_id = journey.user_id
     AND boundary.product_id = journey.product_id
     AND journey.session_end > boundary.cart_anchor_at
     AND journey.session_start
            <= boundary.cart_anchor_at + INTERVAL 31 DAY
    JOIN events event FORCE INDEX (idx_repeat_events)
      ON journey.user_session = event.user_session
     AND journey.product_id = event.product_id
     AND event.event_time > boundary.cart_anchor_at
     AND event.event_time
            <= boundary.cart_anchor_at + INTERVAL 31 DAY
     AND event.event_type = 'purchase'
    WHERE event.price >= 0
)
SELECT
    boundary.user_id,
    boundary.product_id,
    boundary.cart_anchor_at,
    MIN(purchase.purchase_at) AS next_purchase_at,
    COUNT(purchase.purchase_at) AS raw_purchase_event_count
FROM boundary_keys boundary
LEFT JOIN boundary_raw_purchases purchase
  ON boundary.user_id = purchase.user_id
 AND boundary.product_id = purchase.product_id
 AND boundary.cart_anchor_at = purchase.cart_anchor_at
GROUP BY
    boundary.user_id,
    boundary.product_id,
    boundary.cart_anchor_at
ORDER BY user_id, product_id;

-- name: pj_cart_purchase_next_24h_rate | 최초 cart 후 구간별 다음 24시간 동일 상품 구매율
-- cart 다중 purchase 경계는 pj_cart_boundary_raw_next_purchase 결과로 교체한다.
WITH raw_corrections AS (
    SELECT
        correction.user_id,
        correction.product_id,
        correction.cart_anchor_at,
        correction.next_purchase_at
    FROM JSON_TABLE(
        :cart_boundary_corrections_json,
        '$[*]' COLUMNS (
            user_id BIGINT PATH '$.user_id',
            product_id BIGINT PATH '$.product_id',
            cart_anchor_at DATETIME PATH '$.cart_anchor_at',
            next_purchase_at DATETIME PATH '$.next_purchase_at'
                NULL ON EMPTY NULL ON ERROR
        )
    ) correction
), observation_period AS (
    SELECT MAX(session_end) AS observation_end_at
    FROM mart_user_product_session
), first_cart_time_per_user AS (
    SELECT
        user_id,
        MIN(first_cart_at) AS cart_anchor_at
    FROM mart_user_product_session
    WHERE first_cart_at IS NOT NULL
    GROUP BY user_id
), first_cart_per_user AS (
    SELECT
        first_cart.user_id,
        MIN(cart_row.product_id) AS product_id,
        first_cart.cart_anchor_at
    FROM first_cart_time_per_user first_cart
    JOIN mart_user_product_session cart_row
      ON first_cart.user_id = cart_row.user_id
     AND first_cart.cart_anchor_at = cart_row.first_cart_at
    GROUP BY first_cart.user_id, first_cart.cart_anchor_at
), mart_context AS (
    SELECT
        selected.user_id,
        selected.product_id,
        selected.cart_anchor_at,
        period.observation_end_at,
        MIN(CASE
            WHEN history.first_purchase_at > selected.cart_anchor_at
                THEN history.first_purchase_at
        END) AS mart_next_purchase_at,
        MAX(
            history.purchases > 1
            AND history.first_purchase_at <= selected.cart_anchor_at
            AND history.last_purchase_at > selected.cart_anchor_at
        ) AS purchase_boundary_flag
    FROM first_cart_per_user selected
    CROSS JOIN observation_period period
    LEFT JOIN mart_user_product_session history
      ON selected.user_id = history.user_id
     AND selected.product_id = history.product_id
     AND history.purchases > 0
    GROUP BY
        selected.user_id,
        selected.product_id,
        selected.cart_anchor_at,
        period.observation_end_at
), corrected_context AS (
    SELECT
        mart.user_id,
        mart.product_id,
        mart.cart_anchor_at,
        mart.observation_end_at,
        CASE
            WHEN mart.purchase_boundary_flag = 1
                THEN correction.next_purchase_at
            ELSE mart.mart_next_purchase_at
        END AS next_purchase_at
    FROM mart_context mart
    LEFT JOIN raw_corrections correction
      ON mart.user_id = correction.user_id
     AND mart.product_id = correction.product_id
     AND mart.cart_anchor_at = correction.cart_anchor_at
), eligible_base AS (
    SELECT
        user_id,
        product_id,
        cart_anchor_at,
        next_purchase_at
    FROM corrected_context
    WHERE cart_anchor_at + INTERVAL 7 DAY <= observation_end_at
), intervals AS (
    SELECT 0 AS interval_order, 0 AS start_day, 1 AS end_day
    UNION ALL SELECT 1, 1, 2
    UNION ALL SELECT 2, 2, 3
    UNION ALL SELECT 3, 3, 4
    UNION ALL SELECT 4, 4, 5
    UNION ALL SELECT 5, 5, 6
    UNION ALL SELECT 6, 6, 7
), interval_populations AS (
    SELECT
        interval_def.interval_order,
        interval_def.start_day,
        interval_def.end_day,
        selected.cart_anchor_at,
        selected.next_purchase_at
    FROM eligible_base selected
    CROSS JOIN intervals interval_def
    WHERE selected.next_purchase_at IS NULL
       OR selected.next_purchase_at
            > selected.cart_anchor_at + INTERVAL interval_def.start_day DAY
)
SELECT
    interval_order AS 구간순서,
    CONCAT(start_day * 24, '-', end_day * 24, '시간') AS 경과구간,
    start_day * 24 AS 구간시작_시간,
    end_day * 24 AS 구간종료_시간,
    COUNT(*) AS 구간시작_미구매_사용자수,
    SUM(
        next_purchase_at > cart_anchor_at + INTERVAL start_day DAY
        AND next_purchase_at <= cart_anchor_at + INTERVAL end_day DAY
    ) AS 다음24시간_구매_사용자수
FROM interval_populations
GROUP BY interval_order, start_day, end_day
ORDER BY interval_order;

-- name: pj_experiment_baseline | cart+24시간 실험 적격 사용자와 7일 구매 기준선
-- cart 다중 purchase 경계는 pj_cart_boundary_raw_next_purchase 결과로 교체한다.
WITH raw_corrections AS (
    SELECT
        correction.user_id,
        correction.product_id,
        correction.cart_anchor_at,
        correction.next_purchase_at
    FROM JSON_TABLE(
        :cart_boundary_corrections_json,
        '$[*]' COLUMNS (
            user_id BIGINT PATH '$.user_id',
            product_id BIGINT PATH '$.product_id',
            cart_anchor_at DATETIME PATH '$.cart_anchor_at',
            next_purchase_at DATETIME PATH '$.next_purchase_at'
                NULL ON EMPTY NULL ON ERROR
        )
    ) correction
), observation_period AS (
    SELECT MAX(session_end) AS observation_end_at
    FROM mart_user_product_session
), first_cart_time_per_user AS (
    SELECT
        user_id,
        MIN(first_cart_at) AS cart_anchor_at
    FROM mart_user_product_session
    WHERE first_cart_at IS NOT NULL
    GROUP BY user_id
), first_cart_per_user AS (
    SELECT
        first_cart.user_id,
        MIN(cart_row.product_id) AS product_id,
        first_cart.cart_anchor_at,
        first_cart.cart_anchor_at + INTERVAL 1 DAY AS eligibility_at
    FROM first_cart_time_per_user first_cart
    JOIN mart_user_product_session cart_row
      ON first_cart.user_id = cart_row.user_id
     AND first_cart.cart_anchor_at = cart_row.first_cart_at
    GROUP BY first_cart.user_id, first_cart.cart_anchor_at
), mart_context AS (
    SELECT
        selected.user_id,
        selected.product_id,
        selected.cart_anchor_at,
        selected.eligibility_at,
        period.observation_end_at,
        MIN(CASE
            WHEN history.first_purchase_at > selected.cart_anchor_at
                THEN history.first_purchase_at
        END) AS mart_next_purchase_at,
        MAX(
            history.purchases > 1
            AND history.first_purchase_at <= selected.cart_anchor_at
            AND history.last_purchase_at > selected.cart_anchor_at
        ) AS purchase_boundary_flag
    FROM first_cart_per_user selected
    CROSS JOIN observation_period period
    LEFT JOIN mart_user_product_session history
      ON selected.user_id = history.user_id
     AND selected.product_id = history.product_id
     AND history.purchases > 0
    GROUP BY
        selected.user_id,
        selected.product_id,
        selected.cart_anchor_at,
        selected.eligibility_at,
        period.observation_end_at
), corrected_context AS (
    SELECT
        mart.user_id,
        mart.product_id,
        mart.eligibility_at,
        mart.observation_end_at,
        CASE
            WHEN mart.purchase_boundary_flag = 1
                THEN correction.next_purchase_at
            ELSE mart.mart_next_purchase_at
        END AS next_purchase_at
    FROM mart_context mart
    LEFT JOIN raw_corrections correction
      ON mart.user_id = correction.user_id
     AND mart.product_id = correction.product_id
     AND mart.cart_anchor_at = correction.cart_anchor_at
), eligible_users AS (
    SELECT
        user_id,
        product_id,
        eligibility_at,
        observation_end_at,
        next_purchase_at
    FROM corrected_context
    WHERE eligibility_at + INTERVAL 7 DAY <= observation_end_at
      AND (
          next_purchase_at IS NULL
          OR next_purchase_at > eligibility_at
      )
)
SELECT
    DATE(eligibility_at) AS 실험적격일,
    COUNT(*) AS 실험적격_사용자수,
    SUM(
        next_purchase_at > eligibility_at
        AND next_purchase_at <= eligibility_at + INTERVAL 7 DAY
    ) AS 기준점후_7일_동일상품구매_사용자수,
    SUM(
        eligibility_at + INTERVAL 30 DAY <= observation_end_at
    ) AS 기준점후_30일_판정가능_사용자수,
    SUM(
        eligibility_at + INTERVAL 30 DAY <= observation_end_at
        AND next_purchase_at > eligibility_at
        AND next_purchase_at <= eligibility_at + INTERVAL 30 DAY
    ) AS 기준점후_30일_동일상품구매_사용자수
FROM eligible_users
GROUP BY DATE(eligibility_at)
ORDER BY 실험적격일;
