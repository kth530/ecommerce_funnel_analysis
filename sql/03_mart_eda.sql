-- 03 분석 마트 inventory
-- 세 마트는 같은 raw 데이터에서 파생되지만 행의 포함 범위와 하류 질문이 다르다.
-- 이 결과의 행 수를 서로 나누거나 전환율 차이로 해석하지 않는다.

-- name: mart_inventory | 세 마트의 실제 행 수 확인
-- 분석 단위: mart_session은 유효 방문, 나머지는 유효 방문 × 상품
-- 분모: 각 마트에 저장된 전체 행
-- 하류 사용: mart_session·mart_session_product는 04, mart_user_product_session은 05
SELECT
    'mart_session' AS 마트,
    COUNT(*) AS 실제_행수
FROM mart_session
UNION ALL
SELECT
    'mart_session_product' AS 마트,
    COUNT(*) AS 실제_행수
FROM mart_session_product
UNION ALL
SELECT
    'mart_user_product_session' AS 마트,
    COUNT(*) AS 실제_행수
FROM mart_user_product_session
