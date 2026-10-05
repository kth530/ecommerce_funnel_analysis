-- 포트폴리오 가설 검증 SQL. notebooks/04_eda.ipynb 대응.
-- 기존 명명 쿼리의 SQL 본문을 재사용한다. 저장된 최종 노트북은 원본 파일 캐시를 읽는다.
-- 이 파일로 재실행하거나 캐시를 새로 만드는 작업은 이번 개정에서 하지 않았다.
-- 각 경로는 strict 시각 비교를 따르며 로그 미확인은 실제 행동 부재가 아니다.

-- ==================================================
-- 1. 가설 1: 구매 세션의 첫 purchase 이전 동일 상품 A-E 경로
-- ==================================================


-- name: purchase_session_paths | 구매 세션×상품 첫 구매 이전 경로 A-E
-- 출처: final_analysis/03_session_paths.sql, 쿼리 본문 재사용.
-- 목적/연결: 노트북 §3 첫 분석.
-- grain: 구매가 있는 user_session × product_id. 분모: 구매 세션×상품 전체.
-- 분석 단위: 구매가 있는 user_session × product_id, 조합마다 해당 세션의 첫 purchase 한 건.
-- strict event_time < first_purchase_at. remove는 주경로 분류에 사용하지 않는다.
SELECT
    CASE
        WHEN has_view_cart_before_first_purchase = 1 THEN 'A_view_cart_purchase'
        WHEN last_view_before_first_purchase_at IS NOT NULL
         AND last_cart_before_first_purchase_at IS NULL THEN 'B_view_purchase'
        WHEN last_view_before_first_purchase_at IS NULL
         AND last_cart_before_first_purchase_at IS NOT NULL THEN 'C_cart_purchase'
        WHEN last_view_before_first_purchase_at IS NOT NULL
         AND last_cart_before_first_purchase_at IS NOT NULL THEN 'D_nonstandard_both'
        ELSE 'E_purchase_only'
    END AS path_code,
    COUNT(*) AS purchase_session_products
FROM mart_user_product_session FORCE INDEX (idx_mups_first_purchase)
WHERE first_purchase_at IS NOT NULL
GROUP BY path_code
ORDER BY path_code

-- ==================================================
-- 2. 가설 1: Purchase only의 이전 세션 30일 lookback
-- ==================================================


-- name: purchase_only_prior_30d | A-E 중 E만 이전 세션 행동 E1-E5로 분해
-- 출처: final_analysis/03_session_paths.sql, 쿼리 본문 재사용.
-- 목적/연결: 노트북 §3 두 번째 분석.
-- grain: 30일 lookback 적격 Purchase only 세션×상품. 분모: 적격 E; 전체 E와 구분.
-- 첫 purchase 시각 기준 과거 30일의 완전 lookback이 가능한 경우만 사용한다.
-- 이전 세션은 session_end < 현재 구매 세션의 session_start인 세션으로 제한한다.
-- 유효 세션은 최장 1일이므로 인덱스 범위는 31일로 넓히고, 실제 행동은 30일 창으로 판정한다.
WITH purchase_only AS (
    SELECT
        user_id,
        product_id,
        user_session,
        session_start,
        first_purchase_at
    FROM mart_user_product_session FORCE INDEX (idx_mups_first_purchase)
    WHERE first_purchase_at >= '2019-10-31 00:00:00'
      AND last_view_before_first_purchase_at IS NULL
      AND last_cart_before_first_purchase_at IS NULL
),
prior_rollup AS (
    SELECT
        current_purchase.user_session,
        current_purchase.product_id,
        MIN(CASE
            WHEN prior.first_view_at >= current_purchase.first_purchase_at - INTERVAL 30 DAY
            THEN prior.first_view_at
            WHEN prior.last_view_at >= current_purchase.first_purchase_at - INTERVAL 30 DAY
            THEN prior.last_view_at
        END) AS first_confirmed_view_in_window,
        MAX(CASE
            WHEN prior.last_cart_at >= current_purchase.first_purchase_at - INTERVAL 30 DAY
            THEN prior.last_cart_at
        END) AS last_confirmed_cart_in_window
    FROM purchase_only AS current_purchase
    LEFT JOIN mart_user_product_session AS prior FORCE INDEX (idx_mups_user_product_start)
      ON prior.user_id = current_purchase.user_id
     AND prior.product_id = current_purchase.product_id
     AND prior.session_start >= current_purchase.first_purchase_at - INTERVAL 31 DAY
     AND prior.session_start < current_purchase.session_start
     AND prior.session_end < current_purchase.session_start
     AND prior.user_session <> current_purchase.user_session
    GROUP BY current_purchase.user_session, current_purchase.product_id
)
SELECT
    CASE
        WHEN first_confirmed_view_in_window < last_confirmed_cart_in_window
        THEN 'E1_prior_view_cart_ordered'
        WHEN first_confirmed_view_in_window IS NOT NULL
         AND last_confirmed_cart_in_window IS NULL
        THEN 'E2_prior_view_only'
        WHEN first_confirmed_view_in_window IS NULL
         AND last_confirmed_cart_in_window IS NOT NULL
        THEN 'E3_prior_cart_only'
        WHEN first_confirmed_view_in_window IS NOT NULL
         AND last_confirmed_cart_in_window IS NOT NULL
        THEN 'E4_prior_both_order_unconfirmed'
        ELSE 'E5_no_prior_view_cart_observed'
    END AS prior_path_code,
    COUNT(*) AS purchase_only_session_products
FROM prior_rollup
GROUP BY prior_path_code
ORDER BY prior_path_code

-- ==================================================
-- 3. 가설 1: 세션 퍼널 진단과 복수 세션 관찰
-- ==================================================


-- name: fn_session_funnel | 유효 세션 내 조회→담기→구매 순차 퍼널
-- 출처: sql/04_funnel_eda.sql, 쿼리 본문 재사용.
-- 목적/연결: 노트북 §3 보조 진단.
-- grain: user_session. 분모: mart_session 전체 유효 세션; 단계별 조건부 분모는 노트북 표 참조.
-- 분석 단위·분모: user_session, mart_session의 유효 세션 전체.
-- 시간 순서: 같은 세션에서 view_at < cart_at < purchase_at인 strict 플래그를 사용한다.
-- 상품 동일성은 요구하지 않으므로 05의 사용자·상품 30일 대표 첫 구매 cohort와 직접 비교하지 않는다.
SELECT
    SUM(views > 0) AS view_도달,
    SUM(has_cart_after_view) AS view_cart_순차,
    SUM(has_purchase_after_view_cart) AS view_cart_purchase_순차,
    COUNT(*) AS 유효세션
FROM mart_session

-- name: fn_user_product_session_scope | 동일 사용자×상품 복수 세션 관찰
-- 출처: sql/04_funnel_eda.sql, 쿼리 본문 재사용.
-- 목적/연결: 노트북 §3 단위 변경 근거.
-- grain: user_id × product_id. 분모: mart_session_product에서 관찰된 사용자×상품; 17.171%는 구매율 아님.
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

-- ==================================================
-- 4. 가설 1: 30일 완전 관측과 대표 첫 구매 네 경로
-- ==================================================

-- 대표 첫 구매 분모는 30일 적격 사용자×상품 중 실제 대표 첫 구매가 확인된 조합.
-- 30.361%는 그중 한 세션 조회→담기→구매 완결, 69.639%는 한 세션 3단계 미완결.
-- 69.639%를 다른 세션 구매율로 읽지 않는다. raw 경계는 아래 제한 키로만 보완한다.

-- name: pj_30day_purchase_cohort | 30일 완전 관측 및 마트 확정 대표 첫 구매 집계
-- 출처: sql/05_purchase_journey_analysis.sql, 쿼리 본문 재사용.
-- 목적/연결: 노트북 §3 대표 첫 구매.
-- grain: user_id × product_id. 분모: 30일 완전 관측 적격군 또는 그중 대표 첫 구매; 최종 분모는 노트북 경계 보정 참조.
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

-- name: pj_representative_purchase_mart | 대표 첫 구매 마트 확정 네 경로와 raw 경계 키
-- 출처: sql/05_purchase_journey_analysis.sql, 쿼리 본문 재사용.
-- 목적/연결: 노트북 §3 대표 첫 구매.
-- grain: user_id × product_id. 분모: 30일 완전 관측 적격군 또는 그중 대표 첫 구매; 최종 분모는 노트북 경계 보정 참조.
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

-- name: pj_boundary_raw_paths | 대표 구매 시각·중간 cart 경계의 제한적 원본 보완
-- 출처: sql/05_purchase_journey_analysis.sql, 쿼리 본문 재사용.
-- 목적/연결: 노트북 §3 대표 첫 구매.
-- grain: user_id × product_id. 분모: 30일 완전 관측 적격군 또는 그중 대표 첫 구매; 최종 분모는 노트북 경계 보정 참조.
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

-- ==================================================
-- 5. 가설 2: 최초 cart 이후 조건부 구매 시간
-- ==================================================

-- 첫 24시간 분모는 최초 cart 후 7일 완전 관측 사용자×상품이다.
-- 24-48시간 분모는 그중 0-24시간 미구매 사용자×상품이다.
-- 19.040%와 1.623%는 서로 다른 조건부 분모다.

-- name: pj_cart_purchase_boundaries | 다중 purchase의 최초 cart 경계 키
-- 출처: sql/05_purchase_journey_analysis.sql, 쿼리 본문 재사용.
-- 목적/연결: 노트북 §4 구매 시간.
-- grain: user_id × product_id. 분모: 최초 cart 후 7일 완전 관측; 구간별 미구매 집단으로 감소.
-- 분석 단위는 (사용자, 상품)별 최초 관측 cart 한 건이다. 30일 여정 분석과 같은 단위를 쓴다.
-- 두 후속 지표의 공통 기반인 cart 이후 7일 관측 가능 사용자·상품만 raw 후보로 남긴다.
WITH observation_period AS (
    SELECT MAX(session_end) AS observation_end_at
    FROM mart_user_product_session
), first_cart_per_user_product AS (
    SELECT
        user_id,
        product_id,
        MIN(first_cart_at) AS cart_anchor_at
    FROM mart_user_product_session
    WHERE first_cart_at IS NOT NULL
    GROUP BY user_id, product_id
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
    FROM first_cart_per_user_product selected
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

-- name: pj_cart_boundary_raw_next_purchase | 129건 경계의 실제 다음 purchase 제한 조회
-- 출처: sql/05_purchase_journey_analysis.sql, 쿼리 본문 재사용.
-- 목적/연결: 노트북 §4 구매 시간.
-- grain: user_id × product_id. 분모: 최초 cart 후 7일 완전 관측; 구간별 미구매 집단으로 감소.
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

-- name: pj_cart_purchase_next_24h_rate | 최초 cart 후 24시간 구간별 조건부 구매율 원시 집계
-- 출처: sql/05_purchase_journey_analysis.sql, 쿼리 본문 재사용.
-- 목적/연결: 노트북 §4 구매 시간.
-- grain: user_id × product_id. 분모: 최초 cart 후 7일 완전 관측; 구간별 미구매 집단으로 감소.
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
), first_cart_per_user_product AS (
    SELECT
        user_id,
        product_id,
        MIN(first_cart_at) AS cart_anchor_at
    FROM mart_user_product_session
    WHERE first_cart_at IS NOT NULL
    GROUP BY user_id, product_id
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
    FROM first_cart_per_user_product selected
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
    COUNT(*) AS 구간시작_미구매_사용자상품수,
    SUM(
        next_purchase_at > cart_anchor_at + INTERVAL start_day DAY
        AND next_purchase_at <= cart_anchor_at + INTERVAL end_day DAY
    ) AS 다음24시간_구매_사용자상품수
FROM interval_populations
GROUP BY interval_order, start_day, end_day
ORDER BY interval_order;

-- ==================================================
-- 6. 가설 2: cart+24시간 미구매 실험 적격군과 자연 구매 기준선
-- ==================================================

-- 구매자 경로 모집단과 별도다. 분모는 cart+24시간까지 미구매이고
-- 그 뒤 7일을 완전 관측할 수 있는 사용자×상품; 자연 구매 기준선 4.700%.
-- 아래 쿼리는 실험 실행·무작위 배정·효과 추정이 아닌 관찰 데이터 기준선이다.

-- name: pj_experiment_baseline | 실험 적격 조합과 기준 시점 후 7일 동일 상품 구매
-- 출처: sql/05_purchase_journey_analysis.sql, 쿼리 본문 재사용.
-- 목적/연결: 노트북 §4, 05 실험 설계 문서.
-- grain: user_id × product_id를 일자별 집계. 분모: cart+24시간 미구매 및 이후 7일 완전 관측 조합.
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
), first_cart_per_user_product AS (
    SELECT
        user_id,
        product_id,
        MIN(first_cart_at) AS cart_anchor_at,
        MIN(first_cart_at) + INTERVAL 1 DAY AS eligibility_at
    FROM mart_user_product_session
    WHERE first_cart_at IS NOT NULL
    GROUP BY user_id, product_id
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
    FROM first_cart_per_user_product selected
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
    COUNT(*) AS 실험적격_사용자상품수,
    -- 배정·발송은 사용자 단위이므로, 필요 표본(쌍)을 사용자 수로 환산할 때 쓴다.
    COUNT(DISTINCT user_id) AS 실험적격_사용자수,
    SUM(
        next_purchase_at > eligibility_at
        AND next_purchase_at <= eligibility_at + INTERVAL 7 DAY
    ) AS 기준점후_7일_동일상품구매_사용자상품수,
    SUM(
        eligibility_at + INTERVAL 30 DAY <= observation_end_at
    ) AS 기준점후_30일_판정가능_사용자상품수,
    SUM(
        eligibility_at + INTERVAL 30 DAY <= observation_end_at
        AND next_purchase_at > eligibility_at
        AND next_purchase_at <= eligibility_at + INTERVAL 30 DAY
    ) AS 기준점후_30일_동일상품구매_사용자상품수
FROM eligible_users
GROUP BY DATE(eligibility_at)
ORDER BY 실험적격일;

-- ==================================================
-- 7. 가설 2: 사용자 내 군집 보정의 기존 입력 집계
-- ==================================================

-- name: pj_experiment_user_cluster | 기존 05의 사용자별 적격 조합·구매 분포
-- 출처: sql/05_purchase_journey_analysis.sql, 쿼리 본문 재사용.
-- 목적/연결: 노트북 §4 실험 설계의 ICC·설계효과 입력.
-- grain: 적격 사용자별 보유 조합 수·구매 조합 수 분포. 분모: 기준점 후 7일 완전 관측 적격 조합.
-- 적격 집합 정의는 pj_experiment_baseline과 완전히 같고 마지막 집계만 다르다.
-- 사용자 한 명이 몇 개의 적격 조합을 갖고 그중 몇 개를 구매했는지의 분포를 돌려준다.
-- 이 분포만으로 급내상관(ICC)과 설계효과를 계산할 수 있어 사용자 행을 모두 내리지 않는다.
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
), first_cart_per_user_product AS (
    SELECT
        user_id,
        product_id,
        MIN(first_cart_at) AS cart_anchor_at,
        MIN(first_cart_at) + INTERVAL 1 DAY AS eligibility_at
    FROM mart_user_product_session
    WHERE first_cart_at IS NOT NULL
    GROUP BY user_id, product_id
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
    FROM first_cart_per_user_product selected
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
    보유_사용자상품수,
    구매_사용자상품수,
    COUNT(*) AS 사용자수
FROM (
    SELECT
        user_id,
        COUNT(*) AS 보유_사용자상품수,
        SUM(
            next_purchase_at > eligibility_at
            AND next_purchase_at <= eligibility_at + INTERVAL 7 DAY
        ) AS 구매_사용자상품수
    FROM eligible_users
    GROUP BY user_id
) per_user
GROUP BY 보유_사용자상품수, 구매_사용자상품수
ORDER BY 보유_사용자상품수, 구매_사용자상품수;
