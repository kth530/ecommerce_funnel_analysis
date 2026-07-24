-- events 테이블 인덱스 단일 원천.
-- 00_elt_pipeline과 01_eda가 공유한다. 여기 정의만이 유효한 인덱스 목록이다.
-- 폐기: idx_session_time(user_session, event_time)은 idx_repeat_events의 선두 2컬럼과
--   중복이므로 제거했다. 세션 관련 커버링은 idx_repeat_events 선두 컬럼으로 대체된다.

-- name: idx_user_time | 사용자별 시간순 시퀀스·재방문·세션 간 구매 (사용자 퍼널)
CREATE INDEX idx_user_time
    ON events (user_id, event_time)

-- name: idx_product | 상품 단위 조회·조인
CREATE INDEX idx_product
    ON events (product_id)

-- name: idx_event_type | 이벤트 유형 필터·집계
CREATE INDEX idx_event_type
    ON events (event_type)

-- name: idx_repeat_events | 세션 퍼널(시간순) + 반복 이벤트 4키 그룹핑 커버링
-- 선두 2컬럼(user_session, event_time)이 세션 시간순 조회를, 4컬럼 전체가
-- repeat_by_event의 그룹핑을 커버한다.
-- EXPLAIN 검증(2026-07-23): repeat_by_event의 events 스캔 →
--   key=idx_repeat_events, key_len=240, Extra=Using index, temporary 없음.
CREATE INDEX idx_repeat_events
    ON events (user_session, event_time, product_id, event_type)
