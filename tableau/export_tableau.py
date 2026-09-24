"""검증된 05 캐시에서 Tableau용 집계 CSV를 생성한다.

- DB를 조회하지 않고 ``QueryCache.read_cached``만 사용한다.
- parameterized query의 JSON 파라미터는 05 노트북과 같은 순서·형식으로 만든다.
- 캐시 fingerprint, provenance, parquet, schema, content hash가 하나라도 다르면
  ``CacheUnavailableError``로 중단하며 DB로 대체하지 않는다.

실행: ``python tableau/export_tableau.py``
출력: ``tableau/{funnel_summary,purchase_path,cart_purchase_rate,experiment_design}.csv``
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

import pandas as pd
from dotenv import load_dotenv
from sqlalchemy import URL, create_engine

ROOT = Path(__file__).resolve().parent.parent
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from experiment_design import calculate_experiment_design
from query_cache import QueryCache

load_dotenv(ROOT / ".env")

OBSERVATION_DAYS = 30
CART_INTERVAL_HOURS = 24
TRACKING_DAYS = 7
ALPHA = 0.05
POWER = 0.80
RELATIVE_MDE = 0.05

# 05 노트북의 PATH_LABELS와 문자열이 같아야 한다. 한쪽만 바꾸면 노트북과 대시보드의 경로명이 갈린다.
PATH_LABELS = {
    1: "같은 세션 내 조회→담기→첫 구매",
    2: "같은 세션 내 담기→첫 구매 (앞선 조회 미확인)",
    3: "이전 세션에서 담은 뒤 첫 구매",
    4: "첫 구매 전 담기 미확인",
}

OUTPUT_FILES = (
    "funnel_summary.csv",
    "purchase_path.csv",
    "cart_purchase_rate.csv",
    "experiment_design.csv",
)
OBSOLETE_FILES = (
    "category_comparison.csv",
    "purchase_delay.csv",
)


def build_engine():
    """캐시 source identity 계산용 lazy engine을 만든다(DB 연결은 열지 않는다)."""
    return create_engine(
        URL.create(
            "mysql+pymysql",
            username=os.getenv("DB_USER"),
            password=os.getenv("DB_PASSWORD"),
            host=os.getenv("DB_HOST"),
            port=int(os.getenv("DB_PORT", "3306")),
            database=os.getenv("DB_NAME"),
            query={"charset": "utf8mb4"},
        )
    )


def _timestamp_text(series: pd.Series) -> pd.Series:
    return pd.to_datetime(series).dt.strftime("%Y-%m-%d %H:%M:%S")


def _write_csv(frame: pd.DataFrame, path: Path) -> None:
    """완성된 CSV만 노출되도록 임시 파일을 같은 디렉터리에서 교체한다."""
    temporary = path.with_suffix(path.suffix + ".tmp")
    frame.to_csv(
        temporary,
        index=False,
        encoding="utf-8-sig",
        float_format="%.3f",
    )
    temporary.replace(path)


def _build_boundary_params(mart_paths: pd.DataFrame) -> tuple[dict[str, str], pd.DataFrame]:
    boundary_keys = mart_paths.loc[
        mart_paths["row_type"].eq("raw 확인 경계"),
        ["user_id", "product_id", "anchor_view_at", "boundary_type"],
    ].copy()
    boundary_keys["user_id"] = boundary_keys["user_id"].astype("int64")
    boundary_keys["product_id"] = boundary_keys["product_id"].astype("int64")
    boundary_keys["anchor_view_at"] = _timestamp_text(boundary_keys["anchor_view_at"])
    boundary_json = json.dumps(
        boundary_keys.to_dict("records"),
        ensure_ascii=False,
        separators=(",", ":"),
    )
    return {"boundary_json": boundary_json}, boundary_keys


def _build_cart_boundary_params(
    cart_boundaries: pd.DataFrame,
) -> tuple[dict[str, str], pd.DataFrame]:
    boundary_keys = cart_boundaries.copy()
    boundary_keys["user_id"] = boundary_keys["user_id"].astype("int64")
    boundary_keys["product_id"] = boundary_keys["product_id"].astype("int64")
    boundary_keys["cart_anchor_at"] = _timestamp_text(boundary_keys["cart_anchor_at"])
    boundary_json = json.dumps(
        boundary_keys.to_dict("records"),
        ensure_ascii=False,
        separators=(",", ":"),
    )
    return {"cart_boundary_json": boundary_json}, boundary_keys


def _build_cart_correction_params(raw_corrections: pd.DataFrame) -> dict[str, str]:
    correction_records = []
    for row in raw_corrections.itertuples(index=False):
        correction_records.append({
            "user_id": int(row.user_id),
            "product_id": int(row.product_id),
            "cart_anchor_at": pd.Timestamp(row.cart_anchor_at).strftime(
                "%Y-%m-%d %H:%M:%S"
            ),
            "next_purchase_at": (
                None
                if pd.isna(row.next_purchase_at)
                else pd.Timestamp(row.next_purchase_at).strftime("%Y-%m-%d %H:%M:%S")
            ),
        })
    corrections_json = json.dumps(
        correction_records,
        ensure_ascii=False,
        separators=(",", ":"),
    )
    return {"cart_boundary_corrections_json": corrections_json}


def _path_summary(
    purchase_cohort: pd.DataFrame,
    mart_paths: pd.DataFrame,
    raw_paths: pd.DataFrame,
) -> tuple[pd.DataFrame, int, int]:
    cohort_row = purchase_cohort.iloc[0]
    eligible_30day_n = int(cohort_row["관측가능30일_사용자상품수"])
    mart_purchase_cohort_n = int(cohort_row["마트확정_대표첫구매_사용자상품수"])

    mart_confirmed = mart_paths.loc[
        mart_paths["row_type"].eq("마트 확정 경로")
    ].copy()
    raw_eligible = raw_paths.loc[raw_paths["eligible_purchase_flag"].eq(1)].copy()
    raw_classified = raw_eligible.loc[raw_eligible["path_order"].notna()].copy()

    raw_purchase_boundary_eligible_n = int((
        raw_paths["boundary_type"].eq("대표 구매 시각 경계")
        & raw_paths["eligible_purchase_flag"].eq(1)
    ).sum())
    representative_purchase_n = (
        mart_purchase_cohort_n + raw_purchase_boundary_eligible_n
    )

    mart_counts = mart_confirmed.groupby("path_order").size()
    raw_counts = raw_classified.groupby("path_order").size()
    summary = pd.DataFrame({"경로순서": range(1, 5)})
    summary["대표첫구매경로"] = summary["경로순서"].map(PATH_LABELS)
    summary["사용자상품수"] = (
        summary["경로순서"].map(mart_counts).fillna(0)
        + summary["경로순서"].map(raw_counts).fillna(0)
    ).astype("int64")
    summary["대표첫구매내비율_pct"] = (
        summary["사용자상품수"] / representative_purchase_n * 100
    )
    summary["30일적격대비비율_pct"] = (
        summary["사용자상품수"] / eligible_30day_n * 100
    )

    classified_keys = pd.concat(
        [
            mart_confirmed[["user_id", "product_id"]],
            raw_classified[["user_id", "product_id"]],
        ],
        ignore_index=True,
    )
    duplicate_n = int(len(classified_keys) - len(classified_keys.drop_duplicates()))
    unclassified_n = int(
        representative_purchase_n - len(classified_keys.drop_duplicates())
    )
    raw_unresolved_n = int(raw_eligible["path_order"].isna().sum())
    if int(summary["사용자상품수"].sum()) != representative_purchase_n:
        raise ValueError("대표 첫 구매 네 경로 합계가 독립 cohort와 다릅니다.")
    if duplicate_n or unclassified_n or raw_unresolved_n:
        raise ValueError(
            "대표 첫 구매 경로 검산 실패: "
            f"중복={duplicate_n}, 미분류={unclassified_n}, raw미분류={raw_unresolved_n}"
        )
    if abs(float(summary["대표첫구매내비율_pct"].sum()) - 100.0) > 1e-9:
        raise ValueError("대표 첫 구매 경로 비율 합계가 100%가 아닙니다.")

    return summary, eligible_30day_n, representative_purchase_n


def _funnel_summary(
    path_summary: pd.DataFrame,
    eligible_30day_n: int,
    representative_purchase_n: int,
) -> pd.DataFrame:
    non_purchase_n = eligible_30day_n - representative_purchase_n
    rows = [
        {
            "단계구분": "cohort",
            "단계순서": 1,
            "단계": f"{OBSERVATION_DAYS}일 관측 가능 사용자·상품",
            "상위단계": "",
            "건수": eligible_30day_n,
            "분모": eligible_30day_n,
            "단계내비율_pct": 100.0,
            "30일적격대비비율_pct": 100.0,
        },
        {
            "단계구분": "구매여부",
            "단계순서": 2,
            "단계": f"{OBSERVATION_DAYS}일 내 대표 첫 구매",
            "상위단계": f"{OBSERVATION_DAYS}일 관측 가능 사용자·상품",
            "건수": representative_purchase_n,
            "분모": eligible_30day_n,
            "단계내비율_pct": representative_purchase_n / eligible_30day_n * 100,
            "30일적격대비비율_pct": representative_purchase_n / eligible_30day_n * 100,
        },
        {
            "단계구분": "구매여부",
            "단계순서": 3,
            "단계": f"{OBSERVATION_DAYS}일 내 미구매",
            "상위단계": f"{OBSERVATION_DAYS}일 관측 가능 사용자·상품",
            "건수": non_purchase_n,
            "분모": eligible_30day_n,
            "단계내비율_pct": non_purchase_n / eligible_30day_n * 100,
            "30일적격대비비율_pct": non_purchase_n / eligible_30day_n * 100,
        },
    ]
    for _, row in path_summary.iterrows():
        rows.append({
            "단계구분": "대표첫구매경로",
            "단계순서": int(row["경로순서"]) + 3,
            "단계": row["대표첫구매경로"],
            "상위단계": f"{OBSERVATION_DAYS}일 내 대표 첫 구매",
            "건수": int(row["사용자상품수"]),
            "분모": representative_purchase_n,
            "단계내비율_pct": float(row["대표첫구매내비율_pct"]),
            "30일적격대비비율_pct": float(row["30일적격대비비율_pct"]),
        })
    frame = pd.DataFrame(rows)
    percentage_columns = ["단계내비율_pct", "30일적격대비비율_pct"]
    frame[percentage_columns] = frame[percentage_columns].round(3)
    return frame


def _cart_purchase_rate(cart_rates: pd.DataFrame) -> pd.DataFrame:
    frame = cart_rates[[
        "구간순서",
        "경과구간",
        "구간시작_미구매_사용자상품수",
        "다음24시간_구매_사용자상품수",
    ]].copy()
    frame["구간시작_미구매_사용자상품수"] = (
        frame["구간시작_미구매_사용자상품수"].astype("int64")
    )
    frame["다음24시간_구매_사용자상품수"] = (
        frame["다음24시간_구매_사용자상품수"].astype("int64")
    )
    frame["구간별다음24시간구매율_pct"] = (
        frame["다음24시간_구매_사용자상품수"]
        / frame["구간시작_미구매_사용자상품수"]
        * 100
    ).round(3)
    return frame.sort_values("구간순서").reset_index(drop=True)


def cluster_design_effect(cluster_dist: pd.DataFrame) -> tuple[float, float, float]:
    """실험 적격 조합의 사용자별 묶임 분포에서 (ICC, 보정 군집크기, 설계효과)를 구한다.

    한 사용자의 여러 (사용자, 상품) 조합은 서로 독립이 아니다. 결제가 장바구니
    단위로 일어나 같은 사용자의 결과가 함께 움직이기 때문이다. 유의성은 보지 않고
    추정값을 그대로 표본 산정에 반영한다. 05 노트북 §5와 같은 계산이다.
    """
    users = cluster_dist["사용자수"].astype("int64")
    size = cluster_dist["보유_사용자상품수"].astype("int64")
    # 모든 행의 다음 purchase가 없으면 SQL SUM()이 NULL을 준다. 구매 0건을 뜻한다.
    buys = cluster_dist["구매_사용자상품수"].fillna(0).astype("int64")
    if not (buys <= size).all():
        raise ValueError("구매 조합 수가 보유 조합 수를 넘습니다.")

    user_n = int(users.sum())
    pair_n = int((users * size).sum())
    grand = float((users * buys).sum() / pair_n)
    rate = buys / size
    msb = float((users * size * (rate - grand) ** 2).sum()) / (user_n - 1)
    msw = float((users * size * rate * (1 - rate)).sum()) / (pair_n - user_n)
    adjusted = (pair_n - float((users * size ** 2).sum()) / pair_n) / (user_n - 1)
    icc = max(0.0, (msb - msw) / (msb + (adjusted - 1) * msw))
    return icc, adjusted, 1 + (adjusted - 1) * icc


def inflate(value: float, design_effect: float) -> int:
    """설계효과를 곱해 올림한다. 표본·기간에 같은 배수를 적용한다."""
    return -(-int(value) * int(round(design_effect * 1000)) // 1000)


def _experiment_design(
    experiment_daily: pd.DataFrame,
    cart_rates: pd.DataFrame,
    cluster_dist: pd.DataFrame,
) -> pd.DataFrame:
    daily = experiment_daily.copy()
    daily["실험적격일"] = pd.to_datetime(daily["실험적격일"])
    # 분석 단위는 (사용자, 상품) 쌍이다. 같은 캐시의 실험적격_사용자수는
    # 일별 distinct 사용자 수이므로 표본 산정에 쓰지 않는다.
    eligible_n = int(daily["실험적격_사용자상품수"].sum())
    purchase_7day_n = int(daily["기준점후_7일_동일상품구매_사용자상품수"].sum())
    baseline_rate = purchase_7day_n / eligible_n
    daily_eligible_pairs = daily.set_index("실험적격일")["실험적격_사용자상품수"]
    design = calculate_experiment_design(
        baseline_rate=baseline_rate,
        daily_eligible_users=daily_eligible_pairs,
        relative_mdes=(RELATIVE_MDE,),
        alpha=ALPHA,
        power=POWER,
        tracking_days=TRACKING_DAYS,
    )
    design_row = design.sample_size.iloc[0]
    icc, _adjusted, design_effect = cluster_design_effect(cluster_dist)
    required_pairs = inflate(design_row["전체_필요표본수"], design_effect)
    total_days = inflate(design_row["예상_모집일수"], design_effect) + TRACKING_DAYS
    conservative_days = total_days + (
        int(design_row["보수적_7일추적포함_일수"]) - int(design_row["7일추적포함_최소일수"])
    )
    interval_rates = cart_rates.set_index("구간순서")[
        "구간별다음24시간구매율_pct"
    ]
    if not {0, 1}.issubset(interval_rates.index):
        raise ValueError("cart 구매율 캐시에 0~24시간과 24~48시간 구간이 필요합니다.")

    return pd.DataFrame([{
        "실험적격_사용자상품수": eligible_n,
        "7일_동일상품구매_사용자수": purchase_7day_n,
        "기준구매율_pct": round(baseline_rate * 100, 3),
        "상대MDE_pct": round(RELATIVE_MDE * 100, 3),
        "목표구매율_pct": round(float(design_row["처리군_목표구매율_pct"]), 3),
        "급내상관": round(icc, 4),
        "설계효과_배": round(design_effect, 3),
        "전체필요표본_쌍": required_pairs,
        "평균유입기준기간_일": total_days,
        "보수적기간_일": conservative_days,
        "유의수준": ALPHA,
        "검정력": POWER,
        "검정방식": "양측 검정",
        "추적기간_일": TRACKING_DAYS,
        "발송후보시점": f"최초 cart 후 {CART_INTERVAL_HOURS}시간",
        "0_24시간구매율_pct": round(float(interval_rates.loc[0]), 3),
        "24_48시간구매율_pct": round(float(interval_rates.loc[1]), 3),
    }])


def _validate_regression(
    funnel: pd.DataFrame,
    paths: pd.DataFrame,
    cart_rates: pd.DataFrame,
    experiment: pd.DataFrame,
) -> None:
    purchase_row = funnel.loc[funnel["단계"].eq("30일 내 대표 첫 구매")].iloc[0]
    if int(funnel.iloc[0]["건수"]) != 5_323_764:
        raise ValueError("30일 적격 cohort 회귀 검산 실패")
    if int(purchase_row["건수"]) != 342_457:
        raise ValueError("대표 첫 구매 cohort 회귀 검산 실패")
    if paths["사용자상품수"].tolist() != [103_974, 14_291, 113_677, 110_515]:
        raise ValueError("대표 첫 구매 네 경로 회귀 검산 실패")
    if round(float(paths["대표첫구매내비율_pct"].sum()), 3) != 100.000:
        raise ValueError("표시용 대표 첫 구매 경로 비율 합계 검산 실패")
    if round(float(purchase_row["단계내비율_pct"]), 3) != 6.433:
        raise ValueError("30일 대표 첫 구매율 회귀 검산 실패")

    first_two = cart_rates.set_index("구간순서").loc[[0, 1]]
    if first_two["구간시작_미구매_사용자상품수"].tolist() != [4_082_470, 3_305_169]:
        raise ValueError("cart 구매율 분모 회귀 검산 실패")
    if first_two["다음24시간_구매_사용자상품수"].tolist() != [777_301, 53_646]:
        raise ValueError("cart 구매율 분자 회귀 검산 실패")
    if first_two["구간별다음24시간구매율_pct"].tolist() != [19.040, 1.623]:
        raise ValueError("cart 구매율 회귀 검산 실패")

    row = experiment.iloc[0]
    expected_experiment = {
        "실험적격_사용자상품수": 3_287_385,
        "7일_동일상품구매_사용자수": 154_517,
        "기준구매율_pct": 4.700,
        "목표구매율_pct": 4.935,
        "전체필요표본_쌍": 763_479,
        "평균유입기준기간_일": 43,
        "보수적기간_일": 44,
    }
    for column, expected in expected_experiment.items():
        if row[column] != expected:
            raise ValueError(
                f"실험 설계 회귀 검산 실패: {column}={row[column]!r}, expected={expected!r}"
            )


def main(cache_dir: str | None = None, output_dir: str | None = None) -> None:
    out = Path(output_dir or os.getenv("TABLEAU_OUTPUT_DIR", ROOT / "tableau")).resolve()
    out.mkdir(parents=True, exist_ok=True)
    cache = QueryCache(
        engine=build_engine(),
        sql_file=ROOT / "sql" / "05_purchase_journey_analysis.sql",
        upstream_sql_files=(ROOT / "sql" / "02_preprocessing_mart.sql",),
        cache_dir=cache_dir,
    )

    # read_cached는 검증된 캐시가 없으면 예외를 발생시키며 DB를 조회하지 않는다.
    purchase_cohort = cache.read_cached("pj_30day_purchase_cohort")
    mart_paths = cache.read_cached("pj_representative_purchase_mart")

    raw_params, boundary_keys = _build_boundary_params(mart_paths)
    raw_paths = cache.read_cached("pj_boundary_raw_paths", params=raw_params)
    raw_key_frame = raw_paths[
        ["user_id", "product_id", "anchor_view_at", "boundary_type"]
    ].copy()
    raw_key_frame["anchor_view_at"] = _timestamp_text(raw_key_frame["anchor_view_at"])
    if set(map(tuple, boundary_keys.astype(str).to_numpy())) != set(
        map(tuple, raw_key_frame.astype(str).to_numpy())
    ):
        raise ValueError("대표 구매 raw 경계 캐시의 키가 후보 키와 일치하지 않습니다.")

    cart_boundaries = cache.read_cached("pj_cart_purchase_boundaries")
    cart_raw_params, cart_boundary_keys = _build_cart_boundary_params(cart_boundaries)
    cart_raw_corrections = cache.read_cached(
        "pj_cart_boundary_raw_next_purchase",
        params=cart_raw_params,
    )
    cart_raw_key_frame = cart_raw_corrections[
        ["user_id", "product_id", "cart_anchor_at"]
    ].copy()
    cart_raw_key_frame["cart_anchor_at"] = _timestamp_text(
        cart_raw_key_frame["cart_anchor_at"]
    )
    if set(map(tuple, cart_boundary_keys.astype(str).to_numpy())) != set(
        map(tuple, cart_raw_key_frame.astype(str).to_numpy())
    ):
        raise ValueError("cart raw 보완 캐시의 키가 후보 키와 일치하지 않습니다.")

    correction_params = _build_cart_correction_params(cart_raw_corrections)
    cart_rate_cache = cache.read_cached(
        "pj_cart_purchase_next_24h_rate",
        params=correction_params,
    )
    experiment_daily = cache.read_cached(
        "pj_experiment_baseline",
        params=correction_params,
    )

    path_summary, eligible_30day_n, representative_purchase_n = _path_summary(
        purchase_cohort,
        mart_paths,
        raw_paths,
    )
    funnel = _funnel_summary(
        path_summary,
        eligible_30day_n,
        representative_purchase_n,
    )
    paths = path_summary.copy()
    paths[["대표첫구매내비율_pct", "30일적격대비비율_pct"]] = paths[[
        "대표첫구매내비율_pct",
        "30일적격대비비율_pct",
    ]].round(3)
    cart_rates = _cart_purchase_rate(cart_rate_cache)
    cluster_dist = cache.read_cached(
        "pj_experiment_user_cluster",
        params=correction_params,
    )
    experiment = _experiment_design(experiment_daily, cart_rates, cluster_dist)

    _validate_regression(funnel, paths, cart_rates, experiment)

    outputs = {
        "funnel_summary.csv": funnel,
        "purchase_path.csv": paths,
        "cart_purchase_rate.csv": cart_rates,
        "experiment_design.csv": experiment,
    }
    for filename, frame in outputs.items():
        _write_csv(frame, out / filename)
    for filename in OBSOLETE_FILES:
        obsolete = out / filename
        if obsolete.is_file():
            obsolete.unlink()

    print("검증된 05 캐시 HIT: 7/7 (DB 조회 0건)")
    for filename in OUTPUT_FILES:
        frame = outputs[filename]
        print(f"- {filename}: {len(frame):,}행 × {len(frame.columns):,}열")
    print("구형 CSV 정리:", ", ".join(OBSOLETE_FILES))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--cache-dir", help="검증할 provenance cache 루트")
    parser.add_argument("--output-dir", help="CSV 출력 디렉터리")
    arguments = parser.parse_args()
    main(cache_dir=arguments.cache_dir, output_dir=arguments.output_dir)
