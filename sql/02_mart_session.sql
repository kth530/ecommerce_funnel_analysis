-- name: create_mart_session | mart_session 생성 (docs/metrics.md 방침 집행)
-- 처리 방침의 단일 원천은 docs/metrics.md. 이 스크립트가 그 방침을 집행한다.
-- 세션 단위 1행. 분석 노트북(03 이후)은 events가 아니라 이 마트만 소비한다.
SET SESSION group_concat_max_len = 1000000;

DROP TABLE IF EXISTS mart_session;

CREATE TABLE mart_session AS
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
    SUM(IF(event_type = 'purchase' AND price > 0, price, 0)) AS revenue
FROM events
WHERE user_session IS NOT NULL                               -- metrics.md 방침: user_session NOT NULL (WHERE)
GROUP BY user_session
HAVING COUNT(DISTINCT user_id) = 1                           -- metrics.md 방침: 세션당 단일 user_id (HAVING)
   AND TIMESTAMPDIFF(SECOND, MIN(event_time), MAX(event_time)) <= 86400;  -- metrics.md 방침: 지속시간 ≤ 1일 (HAVING)

CREATE INDEX idx_mart_user ON mart_session (user_id);

CREATE INDEX idx_mart_start ON mart_session (session_start);

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
