-- 01 raw EDA: 02 마트 생성 규칙을 확정하기 위한 품질 진단 집계

-- name: base_scalars | 전체 규모·기간·결측·가격 부호를 이벤트 단위 단일 스캔으로 확인
-- 분석 단위: 이벤트 1행. 분모: events 전체 행. 관측 기간은 MIN/MAX(event_time)으로 계산한다.
SELECT
    COUNT(*) AS 행수,
    MIN(event_time) AS 시작,
    MAX(event_time) AS 종료,
    SUM(category_code IS NULL) AS null_category_code,
    SUM(brand IS NULL) AS null_brand,
    SUM(user_session IS NULL) AS null_user_session,
    SUM(category_id IS NULL) AS null_category_id,
    SUM(price IS NULL) AS null_price,
    SUM(price < 0) AS price_음수,
    SUM(price = 0) AS price_0원,
    SUM(price > 0) AS price_정상
FROM events

-- name: distinct_users | 전체 관측 기간 고유 사용자 수
-- 분석 단위: 사용자. 분모: events 전체 행에서 식별된 user_id. idx_user_time 선두 컬럼을 사용한다.
SELECT COUNT(DISTINCT user_id) AS 고유_사용자
FROM events

-- name: distinct_sessions | 전체 관측 기간 고유 세션 수
-- 분석 단위: 세션. 분모: user_session IS NOT NULL인 events. idx_repeat_events 선두 컬럼을 사용한다.
SELECT COUNT(DISTINCT user_session) AS 고유_세션
FROM events

-- name: daily_trend | 날짜·이벤트 유형별 수집량과 가격 0 이하 건수
-- 분석 단위: 일자 × event_type. 분모: 해당 일자·유형의 events 행.
-- 고유 사용자 수는 수집 이상 판정에 사용되지 않아 반복 DISTINCT 집계에서 제외한다.
SELECT
    DATE(event_time) AS event_date,
    event_type,
    COUNT(*) AS event_count,
    SUM(price <= 0) AS zero_neg_count
FROM events
GROUP BY DATE(event_time), event_type
ORDER BY event_date, event_type

-- name: negative_price_detail | 음수 가격 이벤트의 상품·가격·유형별 소량 상세
-- 분석 단위: product_id × brand × price × event_type. 분모: price < 0인 events 131행.
SELECT
    product_id,
    brand,
    price,
    event_type,
    COUNT(*) AS 건수,
    MIN(event_time) AS 최초,
    MAX(event_time) AS 최종
FROM events
WHERE price < 0
GROUP BY product_id, brand, price, event_type
ORDER BY 건수 DESC

-- name: repeat_by_event | 동일 세션·시각·상품·유형 4키 반복 규모
-- 분석 단위: 반복 4키 그룹을 event_type별 집계. 분모는 노트북에서 유형별 전체 이벤트 수와 결합한다.
-- 대표행을 선택할 근거가 없으므로 제거 대상이 아니라 반복 가능성의 상한 진단으로만 사용한다.
WITH repeated AS (
    SELECT
        user_session,
        event_time,
        product_id,
        event_type,
        COUNT(*) AS cnt
    FROM events
    GROUP BY user_session, event_time, product_id, event_type
    HAVING COUNT(*) > 1
)
SELECT
    event_type,
    COUNT(*) AS 반복_그룹수,
    SUM(cnt) - COUNT(*) AS 초과_행수
FROM repeated
GROUP BY event_type
ORDER BY 초과_행수 DESC

-- name: session_quality | 세션-사용자 무결성과 지속시간을 세션별 CTE 한 번으로 통합
-- 분석 단위: user_session. 분모: user_session IS NOT NULL인 고유 세션.
-- 02 유효 세션은 단일 user_id이고 지속시간이 1일 이하인 세션으로 정의한다.
WITH per_session AS (
    SELECT
        user_session,
        COUNT(DISTINCT user_id) AS user_count,
        TIMESTAMPDIFF(SECOND, MIN(event_time), MAX(event_time)) AS duration_seconds
    FROM events
    WHERE user_session IS NOT NULL
    GROUP BY user_session
)
SELECT
    SUM(user_count = 1 AND duration_seconds <= 86400) AS 유효_세션수,
    SUM(user_count = 1) AS 단일_user_세션수,
    SUM(user_count >= 2) AS 다중_user_세션수,
    SUM(duration_seconds <= 3600) AS 1시간_이하_세션수,
    SUM(duration_seconds > 3600 AND duration_seconds <= 86400) AS 1시간_초과_1일_이하_세션수,
    SUM(duration_seconds > 86400) AS 1일_초과_세션수
FROM per_session
