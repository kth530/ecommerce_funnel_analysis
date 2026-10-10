# 최종 분석 SQL 기준본

이 폴더는 [최종 분석](../notebooks/README.md)의 세 노트북에 대응하는 이름별 SQL을 모은다. 포트폴리오에 필요한 범위를 추린 기준본이며, 노트북 안에 같은 SQL 본문을 다시 저장하지 않는다.

| 최종 노트북 | SQL 파일 | 사용 범위 |
|---|---|---|
| [02_data_overview.ipynb](../notebooks/02_data_overview.ipynb) | [data_overview.sql](data_overview.sql) | 원본 규모·기간·유형·식별자·기본 품질·스키마 참고 |
| [03_mart_overview.ipynb](../notebooks/03_mart_overview.ipynb) | [mart_overview.sql](mart_overview.sql) | 전처리와 세 마트 생성 정의·행 수·키 검산 |
| [04_eda.ipynb](../notebooks/04_eda.ipynb) | [eda.sql](eda.sql) | 두 가설, 경계 보완, 실험 적격군·ICC 입력 |

[01_problem_hypothesis.md](../notebooks/01_problem_hypothesis.md)는 분석 질문과 탐색 가설이므로 실행 SQL이 없다.

## 파일 구성

- `data_overview.sql`: 규모·품질·고유 수·일자×유형. 노트북은 검증된 일자×유형 캐시를 유형별로 합산한다. `overview_event_columns`는 MySQL 저장 타입을 확인하는 참고 쿼리다.
- `mart_overview.sql`: 세 마트의 생성 정의, 저장 행 수·기본키 중복 검산. `mart_user_product_session`의 실제 PK와 grain은 **세션×상품**이다.
- `eda.sql`: 구매 세션 A-E, `Purchase only` 이전 E1-E5, 복수 세션, 30일 대표 첫 구매, 최초 cart 시간, 24시간 실험 적격군과 사용자별 군집 분포.
- [`cache_compatibility.json`](cache_compatibility.json): 검증된 캐시를 새 SQL 파일에 연결하기 위한 쿼리 해시·캐시 지문 구성값. SQL이나 결과 데이터는 담지 않는다.

## 캐시·실행 범위

각 노트북은 이 폴더의 SQL만 읽는다. `QueryCache.read_compatible_cached()`는 쿼리 본문의 엄격한 정규화 해시, 세 마트 생성문의 해시, 캐시 호환 메타데이터에 고정된 예전 지문 구성값, 현재 데이터 버전·DB 출처·파라미터, Parquet 내용과 스키마를 검증한다. SQL 파일명과 전체 파일 해시가 달라져도 **쿼리와 마트 정의가 같을 때만** 보관된 캐시를 읽는다. 이전 SQL 파일과 `archive_previous/`는 실행에 필요하지 않다. 각 쿼리 위의 `-- 출처:` 주석은 2026-10-05 구조 개편 전 파일명(`sql/05_purchase_journey_analysis.sql`, `final_analysis/03_overview.sql` 등)을 적어 둔 이력이며, 그 파일들은 현재 저장소에 없다. 불일치하거나 캐시가 없으면 자동 재계산 없이 해당 쿼리에서 멈춘다.

`-- name:` 단위로 읽는 SQL 자료이며 파일 전체를 일괄 실행하는 스크립트가 아니다. 특히 `mart_overview.sql`의 `create_*`에는 원본의 `DROP TABLE`·`CREATE TABLE`이 포함돼 있다. 현재 마트는 그대로 사용하고 생성문은 정의 참고용으로만 본다. `eda.sql`의 30일 대표 구매와 cart 시간은 마트 집계에 기존의 **제한된 경계 보완 결과**를 합쳐야 최종 분모·경로가 된다.

- **17.171%:** 복수 세션에서 관찰된 사용자×상품 비중이며 구매율이 아니다.
- **30.361% / 69.639%:** 대표 첫 구매 중 한 세션에서 조회·담기·구매가 모두 이어진 비중 / 그렇지 않은 비중이다. 69.639%는 다른 세션 구매율이 아니다.
- **19.040% / 1.623% / 4.700%:** 서로 다른 최초 cart·첫날 미구매·실험 적격 집단을 분모로 한다. 마지막 값은 자연 구매 기준선이다.
