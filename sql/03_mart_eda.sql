-- 03 세션 마트 EDA 집계
-- name: reach_composition | 유형 도달별 세션 규모 (세션 단위, 도달 = 카운트 > 0)
-- 비율은 노트북에서 유효 세션 전체 대비로만 계산한다(단계 간 전환율 아님).
SELECT
    SUM(views > 0 AND carts = 0 AND removes = 0 AND purchases = 0) AS view만,
    SUM(carts > 0) AS cart_도달,
    SUM(purchases > 0) AS purchase_도달,
    COUNT(*) AS 유효세션
FROM mart_session

-- name: reach_residual | reach 3구분 어디에도 없는 잔여 세션 (세션 단위)
-- carts=0 AND purchases=0 AND removes>0 인 세션. 담기·구매 없이 제거 활동만 있어
-- view만·cart도달·purchase도달 어디에도 속하지 않는다. 04 세션 경계 예외 후보.
SELECT
    SUM(carts = 0 AND purchases = 0 AND removes > 0) AS 담기구매없이_제거만있는세션,
    SUM(carts = 0 AND purchases = 0 AND removes > 0 AND views > 0) AS 그중_조회도있음,
    SUM(carts = 0 AND purchases = 0 AND removes > 0 AND views = 0) AS 그중_제거만,
    COUNT(*) AS 전체유효세션
FROM mart_session

-- name: duration_dist | duration_sec 구간 분포 (세션 단위)
SELECT
    CASE
        WHEN duration_sec = 0 THEN '0초'
        WHEN duration_sec <= 60 THEN '<=1분'
        WHEN duration_sec <= 300 THEN '1-5분'
        WHEN duration_sec <= 1800 THEN '5-30분'
        WHEN duration_sec <= 3600 THEN '30-60분'
        ELSE '1시간-1일'
    END AS 구간,
    COUNT(*) AS 세션수
FROM mart_session
GROUP BY 구간
ORDER BY MIN(duration_sec)

-- name: events_dist | total_events 구간 분포 (세션 단위)
SELECT
    CASE
        WHEN total_events = 0 THEN '0'
        WHEN total_events = 1 THEN '1'
        WHEN total_events BETWEEN 2 AND 3 THEN '2-3'
        WHEN total_events BETWEEN 4 AND 10 THEN '4-10'
        WHEN total_events BETWEEN 11 AND 50 THEN '11-50'
        ELSE '51+'
    END AS 구간,
    COUNT(*) AS 세션수
FROM mart_session
GROUP BY 구간
ORDER BY MIN(total_events)

-- name: revenue_dist | 구매 세션(purchases > 0)의 revenue 구간 분포 (세션 단위, 로그 스케일 bin)
SELECT
    CASE
        WHEN revenue = 0 THEN '0'
        WHEN revenue < 10 THEN '(0,10)'
        WHEN revenue < 30 THEN '[10,30)'
        WHEN revenue < 100 THEN '[30,100)'
        WHEN revenue < 300 THEN '[100,300)'
        ELSE '300+'
    END AS revenue_구간,
    COUNT(*) AS 세션수
FROM mart_session
WHERE purchases > 0
GROUP BY revenue_구간
ORDER BY MIN(revenue)

-- name: monthly_sessions | 월별 세션 수 (session_start 기준, 세션 단위)
SELECT
    CONCAT(YEAR(session_start), '-', LPAD(MONTH(session_start), 2, '0')) AS 월,
    COUNT(*) AS 세션수
FROM mart_session
GROUP BY 월
ORDER BY 월

-- name: dow_sessions | 요일별 세션 수 (session_start 기준, 세션 단위, 1=일 ~ 7=토)
SELECT
    DAYOFWEEK(session_start) AS 요일번호,
    COUNT(*) AS 세션수
FROM mart_session
GROUP BY 요일번호
ORDER BY 요일번호

-- name: user_session_count_dist | 사용자당 세션 수 구간 분포 (사용자 단위)
WITH u AS (
    SELECT user_id, COUNT(*) AS 세션수
    FROM mart_session
    GROUP BY user_id
)
SELECT
    CASE
        WHEN 세션수 = 1 THEN '1'
        WHEN 세션수 BETWEEN 2 AND 3 THEN '2-3'
        WHEN 세션수 BETWEEN 4 AND 10 THEN '4-10'
        ELSE '11+'
    END AS 구간,
    COUNT(*) AS 사용자수
FROM u
GROUP BY 구간
ORDER BY MIN(세션수)

-- name: user_purchase_session_dist | 사용자당 구매 세션 수 구간 분포 (사용자 단위)
WITH u AS (
    SELECT user_id, SUM(purchases > 0) AS 구매세션수
    FROM mart_session
    GROUP BY user_id
)
SELECT
    CASE
        WHEN 구매세션수 = 0 THEN '0'
        WHEN 구매세션수 = 1 THEN '1'
        WHEN 구매세션수 BETWEEN 2 AND 3 THEN '2-3'
        ELSE '4+'
    END AS 구간,
    COUNT(*) AS 사용자수
FROM u
GROUP BY 구간
ORDER BY MIN(구매세션수)

-- name: first_type_dist | 진입 유형(first_event_type) 분포 (세션 단위)
SELECT
    first_event_type,
    COUNT(*) AS 세션수
FROM mart_session
GROUP BY first_event_type
ORDER BY 세션수 DESC

-- name: last_type_dist | 이탈 유형(last_event_type) 분포 (세션 단위)
SELECT
    last_event_type,
    COUNT(*) AS 세션수
FROM mart_session
GROUP BY last_event_type
ORDER BY 세션수 DESC
