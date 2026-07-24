# Metrics 정의 및 데이터 처리 방침

방침의 집행은 `sql/02_mart_*.sql`에서 하고, 분석 노트북은 마트만 소비한다.

수치는 `notebooks/01_eda_basic.ipynb` 실행 출력 기준이며, 관측 기간은 2019-10-01 - 2020-02-29(전체 20,692,840행)이다.

---

## 1. 처리 방침

| 대상 | 방침 | 근거 (분자 / 분모 = 비율) | 출처 | 집행 위치 |
|------|------|---------------------------|------|-----------|
| 반복 이벤트 (4키: user_session·event_time·product_id·event_type) | 전 유형 미제거·수용 | purchase 905 / 1,287,007 = 0.070%; remove_from_cart 991,821 / 3,979,679 = 24.9%; cart 115,342 / 5,768,333 = 2.0%; view 1,031 / 9,657,821 = 0.011% | 01 §6 | 집행 없음(수용) — 왜곡 상한 명시 |
| 유효 세션 | user_session NOT NULL AND 세션당 고유 user_id 1개 AND 지속시간 ≤ 1일만 유효 | NULL 4,598 / 20,692,840 = 0.022%; user_id 2+ 272 / 4,535,941 = 0.006%; >1일 36,195 / 4,535,941 = 0.80% | 01 §4, §8 | `02_mart_session.sql` WHERE/HAVING절 |
| price < 0 | 이벤트 카운트·revenue 모두 제외 | 131건 (purchase 집중·brand 전량 NULL → 반품/취소 추정) | 01 §5 | revenue 및 카운트 정의부 |
| price = 0 | 이벤트 카운트 포함, revenue 제외 | 104,157 / 20,692,840 = 0.50%; 2020-02 71,291 / 4,156,682 = 1.7% 급증 | 01 §5 | revenue 및 카운트 정의부 |
| 카테고리 키 | category_id 사용, category_code 미사용, brand는 04에서 확정 | category_id 결측 0; category_code 98.291% 결측; brand 42.320% 결측 | 01 §4, §11 | 마트 컬럼 선택 |

- 반복 이벤트 미제거 사유: 제거 시 그룹 내 price 상이로 검증 불가능한 대표값 가정이 필요해 미제거가 방어 가능하다. purchase 초과 0.070%로 전환·revenue 왜곡 상한이 미미하다. remove_from_cart 카운트 해석 시 반복 가능성을 병기한다(03 인계).
- 유효 세션 >1일 제외 사유: 비활동 타임아웃 관례상 존재 불가능한 지속시간으로, 세션 ID 재사용이 의심된다.

---

## 2. 지표 정의

- **유효 세션**: `user_session IS NOT NULL` AND 세션당 고유 `user_id` = 1 AND 지속시간(세션 내 `MAX(event_time) - MIN(event_time)`) ≤ 1일.
- **세션 전환율** = purchases > 0 인 유효 세션 수 / 유효 세션 수.
- **revenue** = `event_type = 'purchase'` AND `price > 0` 인 이벤트의 `price` 합.
- **카테고리 키** = `category_id`.
- **이벤트 카운트**(views·carts·removes·purchases): `price < 0` 이벤트는 모든 카운트에서 제외한다. `price = 0`은 카운트에 포함한다.

---

## 3. 예외

현재 없음.
