# Query cache contract

분석 notebook 03-06의 parquet cache는 query name만으로 재사용하지 않는다. 현재 실행 조건에서 계산한 fingerprint가 일치하고 metadata 및 parquet 무결성 검증을 통과한 결과만 cache hit로 인정한다.

## Notebook별 cache 정책

- Notebook 03-06은 `QueryCache`를 사용해 content-addressed parquet와 provenance metadata를 함께 검증한다.
- `tableau/export_tableau.py`는 현재 조건과 일치하는 검증된 Notebook 06 cache만 읽으며 DB 재조회나 legacy fallback을 수행하지 않는다.
- Notebook 01은 아직 `cache/<query-name>.parquet` 형식의 name-only cache를 직접 사용한다. 이 cache는 SQL·parameter·schema provenance를 검증하지 않으므로, SQL이나 원본 조건이 바뀌면 해당 query를 `refresh=True`로 실행해 갱신해야 한다.

## Fingerprint

Fingerprint는 다음 항목으로 구성한다.

- cache contract version
- query name과 실제 named query SQL 본문 SHA-256
- 해당 분석 SQL 파일 전체 SHA-256
- `sql/02_preprocessing_mart.sql` 등 명시적으로 전달한 upstream SQL SHA-256
- `cache_context.json`의 dataset version
- query parameter의 결정론적 hash
- 결과에 영향을 주는 `pandas.read_sql()` kwargs의 결정론적 hash
- DB dialect
- DB host·port·schema로 만든 sanitized source hash

비밀번호, DB user, 전체 connection string, `.env` 원문과 parameter 원문은 cache 경로·metadata·로그에 기록하지 않는다.

## Dataset version

현재 version은 cosmetics shop events의 2019-10-01-2020-02-29 데이터 20,692,840행을 나타낸다. 원본 `events`의 기간, 행 수 또는 내용이 바뀌면 `cache_context.json`의 `dataset_version`을 갱신해야 한다. SQL 파일이나 upstream mart 정의가 바뀌면 파일 hash가 달라져 자동으로 cache miss가 발생한다.

## 저장과 재사용

Cache는 `cache/<sql-file>/<query-name>/<fingerprint>.parquet`와 같은 fingerprint의 `.meta.json`으로 저장한다. parquet와 metadata는 같은 디렉터리의 임시 파일에 먼저 기록한 뒤 atomic replace한다. metadata에는 생성 시각(UTC), 행 수, 컬럼 순서, dtype, parquet SHA-256과 정렬 독립 DataFrame content hash를 기록한다.

`QueryCache`는 `cache/<query-name>.parquet` 형식의 provenance 없는 flat legacy cache를 읽거나 fallback으로 사용하지 않는다. 해당 파일이 남아 있어도 cache miss로 처리하고 DB query를 다시 실행한다. metadata 누락·fingerprint 불일치·parquet 손상도 같은 방식으로 cache miss 처리한다. `refresh=True`는 유효한 content-addressed cache가 있어도 읽지 않고 query를 다시 실행한다. Notebook 01의 13개 name-only cache는 위 예외 정책에 따라 현재도 active이며 Notebook 03-06의 obsolete flat cache와 구분한다.

Cache는 언제든 현재 SQL과 원본 DB에서 재생성할 수 있는 로컬 산출물이며 Git에서 제외한다. `FUNNEL_CACHE_DIR` 환경변수 또는 helper의 `cache_dir` 인자로 기본 `cache/` 경로를 바꿀 수 있다.

## Tableau export

`tableau/export_tableau.py`는 DB를 재조회하지 않는다. 현재 `sql/06_purchase_journey_analysis.sql`, dataset version, upstream mart SQL, DB source에 맞는 provenance 검증을 통과한 06 cache만 읽는다. legacy cache나 provenance 불일치 cache가 있으면 export를 중단한다.
