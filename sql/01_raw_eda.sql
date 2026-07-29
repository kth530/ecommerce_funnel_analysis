-- 01 raw EDA·품질 진단 집계
-- name: base_scalars | 전체 행수·기간·컬럼 결측·가격 부호 (단일 스캔으로 통합)
-- overview의 행수·기간, null_profile, price_anomaly를 한 번의 전체 스캔으로 합쳤다.
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

-- name: distinct_users | 고유 사용자 수 (idx_user_time 선두 컬럼 커버링 유도)
SELECT COUNT(DISTINCT user_id) AS 고유_사용자
FROM events

-- name: distinct_sessions | 고유 세션 수 (idx_repeat_events 선두 컬럼 커버링 유도)
SELECT COUNT(DISTINCT user_session) AS 고유_세션
FROM events

-- name: daily_trend | 일별·유형별 이벤트 수·사용자 수·가격0이하 (수집 이상·가격 파생의 원천)
-- event_dist/price_by_event/price_by_month는 이 결과의 Python groupby로 파생한다.
SELECT
    DATE(event_time) AS event_date,
    event_type,
    COUNT(*) AS event_count,
    COUNT(DISTINCT user_id) AS user_count,
    SUM(price <= 0) AS zero_neg
FROM events
GROUP BY DATE(event_time), event_type
ORDER BY event_date, event_type

-- name: negative_price_detail | 음수 가격의 정체 파악 (상품·브랜드·가격·유형별)
-- 대상 행이 소수라 그룹 결과도 소량이다. 특정 상품·가격에 몰렸는지(반품/오류 여부) 확인한다.
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

-- name: repeat_by_event | 반복 이벤트 패턴을 event_type별로 분해 (이벤트 단위)
-- 전체 규모(반복_그룹수·반복_포함_행수·초과_행수 합계)는 노트북에서 이 결과의 합으로 파생한다.
-- purchase의 반복 비중을 중점적으로 본다. idx_repeat_events 커버링 유도.
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

-- name: session_event_dist | 세션당 이벤트 수 구간 분포 (세션 단위)
-- user_session NULL은 세션 지표에서 제외한다. idx_repeat_events 선두 컬럼 커버링으로 처리된다.
WITH per_session AS (
    SELECT
        user_session,
        COUNT(*) AS 이벤트수
    FROM events
    WHERE user_session IS NOT NULL
    GROUP BY user_session
)
SELECT
    CASE
        WHEN 이벤트수 = 1 THEN '1'
        WHEN 이벤트수 BETWEEN 2 AND 3 THEN '2-3'
        WHEN 이벤트수 BETWEEN 4 AND 10 THEN '4-10'
        WHEN 이벤트수 BETWEEN 11 AND 50 THEN '11-50'
        ELSE '51+'
    END AS 이벤트수_구간,
    COUNT(*) AS 세션수
FROM per_session
GROUP BY 이벤트수_구간
ORDER BY MIN(이벤트수)

-- name: top_active_users | 활동량(이벤트 수) 상위 사용자 (사용자 단위)
-- 세션 수 DISTINCT는 인덱스에 없어 느리므로 idx_user_time로 커버되는 이벤트 수 기준으로 본다.
SELECT
    user_id,
    COUNT(*) AS 이벤트수
FROM events
GROUP BY user_id
ORDER BY 이벤트수 DESC
LIMIT 10

-- name: session_user_integrity | 세션당 고유 user_id 수 분포 (세션 단위)
-- 정상 세션은 user_id가 1개여야 한다. 2개 이상인 세션 수로 세션-사용자 무결성을 본다.
WITH s AS (
    SELECT
        user_session,
        COUNT(DISTINCT user_id) AS 고유user수
    FROM events
    WHERE user_session IS NOT NULL
    GROUP BY user_session
)
SELECT
    CASE WHEN 고유user수 = 1 THEN '1' ELSE '2+' END AS 고유user_구간,
    COUNT(*) AS 세션수
FROM s
GROUP BY 고유user_구간
ORDER BY 고유user_구간

-- name: session_duration_dist | 세션 지속시간(시작~끝) 구간 분포 (세션 단위)
-- MIN/MAX event_time만 사용하므로 idx_repeat_events 선두 컬럼 커버링으로 처리된다.
WITH s AS (
    SELECT
        user_session,
        TIMESTAMPDIFF(SECOND, MIN(event_time), MAX(event_time)) AS 지속초
    FROM events
    WHERE user_session IS NOT NULL
    GROUP BY user_session
)
SELECT
    CASE
        WHEN 지속초 <= 3600 THEN '<=1시간'
        WHEN 지속초 <= 86400 THEN '<=1일'
        ELSE '>1일'
    END AS 지속_구간,
    COUNT(*) AS 세션수
FROM s
GROUP BY 지속_구간
ORDER BY MIN(지속초)

-- name: cardinality | 상품·브랜드·카테고리 카디널리티 (이벤트 단위, 단일 스캔)
SELECT
    COUNT(DISTINCT product_id) AS 상품수,
    COUNT(DISTINCT brand) AS 브랜드수,
    COUNT(DISTINCT category_id) AS 카테고리수
FROM events

-- name: price_histogram | price>0 로그스케일 구간 분포 (이벤트 단위)
-- MySQL 8.0에는 PERCENTILE 집계가 없어 분위수 대신 로그스케일 구간 히스토그램으로 분포를 본다.
SELECT
    CASE
        WHEN price < 1 THEN '[0,1)'
        WHEN price < 3 THEN '[1,3)'
        WHEN price < 10 THEN '[3,10)'
        WHEN price < 30 THEN '[10,30)'
        WHEN price < 100 THEN '[30,100)'
        WHEN price < 300 THEN '[100,300)'
        ELSE '300+'
    END AS 가격구간,
    COUNT(*) AS 건수
FROM events
WHERE price > 0
GROUP BY 가격구간
ORDER BY MIN(price)

-- name: sessions_per_user_dist | 사용자당 세션 수 구간 분포 (사용자 단위)
-- user_session NULL은 제외한다.
WITH u AS (
    SELECT
        user_id,
        COUNT(DISTINCT user_session) AS 세션수
    FROM events
    WHERE user_session IS NOT NULL
    GROUP BY user_id
)
SELECT
    CASE
        WHEN 세션수 = 1 THEN '1'
        WHEN 세션수 BETWEEN 2 AND 3 THEN '2-3'
        WHEN 세션수 BETWEEN 4 AND 10 THEN '4-10'
        ELSE '11+'
    END AS 세션수_구간,
    COUNT(*) AS 사용자수
FROM u
GROUP BY 세션수_구간
ORDER BY MIN(세션수)
