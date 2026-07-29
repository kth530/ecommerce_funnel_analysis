# Metrics 정의 및 데이터 처리 방침

방침의 집행은 `sql/02_preprocessing_mart.sql`에서 하고, 분석 노트북은 마트만 소비한다.

수치는 `notebooks/01_raw_eda.ipynb` 실행 출력 기준이며, 관측 기간은 2019-10-01 - 2020-02-29(전체 20,692,840행)이다.

---

## 1. 처리 방침

| 대상 | 방침 | 근거 (분자 / 분모 = 비율) | 출처 | 집행 위치 |
|------|------|---------------------------|------|-----------|
| 반복 이벤트 (4키: user_session·event_time·product_id·event_type) | 전 유형 미제거·수용 | purchase 905 / 1,287,007 = 0.070%; remove_from_cart 991,821 / 3,979,679 = 24.9%; cart 115,342 / 5,768,333 = 2.0%; view 1,031 / 9,657,821 = 0.011% | 01 §6 | 집행 없음(수용) — 왜곡 상한 명시 |
| 유효 세션 | user_session NOT NULL AND 세션당 고유 user_id 1개 AND 지속시간 ≤ 1일만 유효 | NULL 4,598 / 20,692,840 = 0.022%; user_id 2+ 272 / 4,535,941 = 0.006%; >1일 36,195 / 4,535,941 = 0.80% | 01 §4, §8 | `02_preprocessing_mart.sql` WHERE/HAVING절 |
| price < 0 | 이벤트 카운트·revenue 모두 제외 | 131건 (purchase 집중·brand 전량 NULL → 반품/취소 추정) | 01 §5 | revenue 및 카운트 정의부 |
| price = 0 | 이벤트 카운트 포함, revenue 제외 | 104,157 / 20,692,840 = 0.50%; 2020-02 71,291 / 4,156,682 = 1.7% 급증 | 01 §5 | revenue 및 카운트 정의부 |
| 카테고리 키 | category_id 사용, category_code 미사용 | category_id 결측 0; category_code 98.291% 결측 | 01 §4, §11 | 마트 컬럼 선택 |
| 상품 대표 속성 | product_id별 category_id·brand 최빈값 사용. 동률이면 최종 관찰 시각 내림차순, 이후 값 오름차순 | 다중 category_id 상품 1,619 / 54,566 = 2.97%; 다중 brand 상품 24 / 54,566 = 0.044% | 04 §5 | `04_funnel_eda.sql` mart_product 생성부 |

- 반복 이벤트 미제거 사유: 제거 시 그룹 내 price 상이로 검증 불가능한 대표값 가정이 필요해 미제거가 방어 가능하다. purchase 초과 0.070%로 전환·revenue 왜곡 상한이 미미하다. remove_from_cart 카운트 해석 시 반복 가능성을 병기한다(03 인계).
- 유효 세션 >1일 제외 사유: 비활동 타임아웃 관례상 존재 불가능한 지속시간으로, 세션 ID 재사용이 의심된다.
- 상품 대표 brand는 NULL·빈 문자열을 후보에서 제외하며, 유효한 brand가 한 번도 없는 상품은 `unknown`으로 보존한다.

---

## 2. 지표 정의

- **유효 세션**: `user_session IS NOT NULL` AND 세션당 고유 `user_id` = 1 AND 지속시간(세션 내 `MAX(event_time) - MIN(event_time)`) ≤ 1일.
- **이벤트 도달(순서 미반영)**: 세션에 해당 이벤트가 1건 이상 있으면 도달로 본다(`views > 0`, `carts > 0`, `purchases > 0`). 각 도달 집합은 독립적으로 집계하며 포함 관계를 가정하지 않는다. 03의 도달·분포 집계가 이 정의를 사용한다.
- **세션 진입·이탈 유형**: `first_event_type`·`last_event_type`은 `session_start`·`session_end`와 동일하게 유효 세션 내 전체 이벤트를 기준으로 한다(`price` 필터 미적용). 세션 경계의 보조 기술값이며 순차 퍼널과 직접 진입 경로 판정에는 사용하지 않는다.
- **구매 세션 도달률** = `purchases > 0`인 유효 세션 수 / 유효 세션 수. 이벤트 순서를 반영하지 않으므로 순차 전환율과 구분한다.
- **세션 전체 순차 퍼널**: 분석 단위는 세션(`user_session`)이다. 같은 세션 안에서 시간순 `view → cart → purchase`가 확인되면 순차 도달로 본다. 상품 동일 조건은 적용하지 않으므로 서로 다른 `product_id`의 이벤트가 한 경로로 연결될 수 있다.
- **세션 view→cart 순차 전환율** = 같은 세션에서 view 이후 cart가 발생한 세션 수 / view 도달 세션 수.
- **세션 cart→purchase 순차 전환율** = 같은 세션에서 `view → cart` 이후 purchase가 발생한 세션 수 / `view → cart` 순차 도달 세션 수.
- **동일 상품 순차 퍼널**: 분석 단위는 세션·상품(`user_session × product_id`)이다. 같은 세션·같은 상품에서 시간순 `view → cart → purchase`가 확인되면 순차 도달로 본다.
- **동일 상품 view→cart 순차 전환율** = 같은 세션·상품에서 view 이후 cart가 발생한 session-product 수 / view 도달 session-product 수.
- **동일 상품 cart→purchase 순차 전환율** = 같은 세션·상품에서 `view → cart` 이후 purchase가 발생한 session-product 수 / `view → cart` 순차 도달 session-product 수.
- **직접 진입 경로**: 선행 단계 없이 cart 또는 purchase가 관찰된 세션·session-product는 순차 전환 분자에서 제외하고 선형 퍼널 밖 경로로 별도 집계한다. 세션 내 미구매는 관측 기간 전체의 구매 포기나 사용자 이탈을 의미하지 않는다.
- **상품 이벤트 비율** = 상품·카테고리·가격대별 cart 또는 purchase 이벤트 수 / view 이벤트 수. 이벤트 개수 비율이며 순서와 도달 단위를 반영하지 않아 순차 전환율과 직접 비교하지 않는다.
- **revenue** = `event_type = 'purchase'` AND `price > 0` 인 이벤트의 `price` 합.
- **카테고리 키** = `category_id`.
- **상품 대표 속성**: `mart_product`의 category_id·brand는 상품별 최빈값이다. 동률이면 마지막 관찰 시각이 늦은 값을 우선하고, 그래도 동률이면 값 오름차순으로 하나를 선택한다.
- **이벤트 카운트**(views·carts·removes·purchases): `price < 0` 이벤트는 모든 카운트에서 제외한다. `price = 0`은 카운트에 포함한다.

---

## 3. 예외

- **동일 시각 이벤트**: `event_time`이 같은 이벤트에는 보조 순번이 없어 시간순 선후를 식별할 수 없다. 순차 퍼널의 대표값은 선후가 확인되는 strict(`<`) 기준으로 계산하고, 동일 시각을 인정하는 inclusive(`≤`) 결과는 02 검증에서 민감도만 기록한다. 유효 세션·`price >= 0` 범위에서 inclusive 적용 시 세션 view→cart는 710,008→710,651(+643, 전환율 +0.015%p), view→cart→purchase는 97,600→97,628(+28)이고, 동일 상품 view→cart는 885,651→887,130(+1,479, +0.018%p), view→cart→purchase는 132,235→132,425(+190)로 대표값을 바꿀 수준의 차이는 아니다.
- **세션 경계**: 04의 순차 퍼널은 같은 세션 안의 경로만 다룬다. 이전 세션의 view·cart 이후 후속 세션에서 발생한 purchase는 04의 순차 전환에서 제외하고 05 사용자·상품 여정에서 별도 분석한다.
- **상품 범위**: 세션 전체 순차 퍼널은 방문 수준의 행동 진행을 보기 때문에 상품 동일 조건을 두지 않는다. 상품·카테고리·가격대별 전환은 `user_session × product_id` 기준의 동일 상품 순차 퍼널만 사용한다.
