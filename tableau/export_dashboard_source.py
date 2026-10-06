"""Export the verified portfolio dashboard data without editing Tableau workbooks.

Existing aggregates come from provenance-checked cache hits. Only the two
Cart-unobserved subpath queries use the existing mart/events for the keys in
the combined fourth path; QueryCache then stores their validated results.
"""

from __future__ import annotations

import json
import math
import sys
from pathlib import Path

import pandas as pd

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from tableau import export_tableau as existing
from tableau import export_workbook_compat as compat
from experiment_design import calculate_experiment_design


OUTPUT_DIR = ROOT / "tableau"
REPRESENTATIVE_EXPECTED = 342_457
ELIGIBLE_30DAY_EXPECTED = 5_323_764
# 04_eda.ipynb §1-1의 검증된 마트 683,751 + 제한 raw 경계 43.
CART_AFTER_VIEW_30DAY = 683_751 + 43

PATH_NAMES = {
    1: "같은 세션 View → Cart → Purchase",
    2: "같은 세션 Cart → Purchase · 앞선 View 미확인",
    3: "이전 세션 Cart → 대표 첫 구매",
    4: "Cart 미확인 · 구매 세션 View → Purchase",
    5: "Cart 미확인 · 구매 세션 Purchase only",
}
FIVE_DISPLAY_ORDER = (3, 1, 4, 5, 2)


def build_split_keys(
    mart_paths: pd.DataFrame, raw_paths: pd.DataFrame
) -> tuple[pd.DataFrame, pd.DataFrame, dict[str, str], dict[str, str]]:
    """Use only the existing Cart-unobserved path keys for limited verification."""
    mart_keys = mart_paths.loc[
        mart_paths["row_type"].eq("마트 확정 경로") & mart_paths["path_order"].eq(4),
        ["user_id", "product_id", "anchor_view_at"],
    ].copy()
    raw_keys = raw_paths.loc[
        raw_paths["eligible_purchase_flag"].eq(1) & raw_paths["path_order"].eq(4),
        ["user_id", "product_id", "anchor_view_at", "representative_purchase_at"],
    ].copy()
    for frame in (mart_keys, raw_keys):
        frame[["user_id", "product_id"]] = frame[["user_id", "product_id"]].astype("int64")
        frame["anchor_view_at"] = pd.to_datetime(frame["anchor_view_at"]).dt.strftime(
            "%Y-%m-%d %H:%M:%S"
        )
        if frame.duplicated(["user_id", "product_id"]).any():
            raise ValueError("Cart 미확인 원본 키가 중복됐습니다.")
    raw_keys["representative_purchase_at"] = pd.to_datetime(
        raw_keys["representative_purchase_at"]
    ).dt.strftime("%Y-%m-%d %H:%M:%S")
    mart_params = {"no_cart_mart_json": json.dumps(
        mart_keys.to_dict("records"), ensure_ascii=False, separators=(",", ":")
    )}
    raw_params = {"no_cart_raw_json": json.dumps(
        raw_keys.to_dict("records"), ensure_ascii=False, separators=(",", ":")
    )}
    return mart_keys, raw_keys, mart_params, raw_params


def _validate_split_keys(source: pd.DataFrame, detail: pd.DataFrame) -> None:
    """Prove one and only one detailed classification for every source key."""
    key_columns = ["user_id", "product_id", "anchor_view_at"]
    if detail.duplicated(key_columns).any():
        raise ValueError("Cart 미확인 세부 경로에 중복 분류가 있습니다.")
    if not detail["detail_path_order"].isin([4, 5]).all():
        raise ValueError("Cart 미확인 세부 경로에 미분류 또는 잘못된 분류가 있습니다.")
    left = source[key_columns].copy()
    right = detail[key_columns].copy()
    for frame in (left, right):
        frame["anchor_view_at"] = pd.to_datetime(frame["anchor_view_at"]).dt.strftime(
            "%Y-%m-%d %H:%M:%S"
        )
    matched = left.merge(right, on=key_columns, how="outer", indicator=True)
    if not matched["_merge"].eq("both").all() or len(matched) != len(source):
        raise ValueError("Cart 미확인 원본 키와 세부 분류 키가 일치하지 않습니다.")


def build_purchase_paths(
    cohort: pd.DataFrame,
    mart_paths: pd.DataFrame,
    raw_paths: pd.DataFrame,
    mart_detail: pd.DataFrame,
    raw_detail: pd.DataFrame,
) -> tuple[pd.DataFrame, pd.DataFrame, int, int]:
    """Validate mutually exclusive 5 paths and derive the 4-path display view."""
    four_base, eligible, representative = existing._path_summary(
        cohort, mart_paths, raw_paths
    )
    mart_keys, raw_keys, _, _ = build_split_keys(mart_paths, raw_paths)
    _validate_split_keys(mart_keys, mart_detail)
    _validate_split_keys(raw_keys, raw_detail)

    confirmed = mart_paths.loc[mart_paths["row_type"].eq("마트 확정 경로")]
    raw_classified = raw_paths.loc[
        raw_paths["eligible_purchase_flag"].eq(1) & raw_paths["path_order"].notna()
    ]
    ordinary = pd.concat([
        confirmed.loc[confirmed["path_order"].ne(4), ["user_id", "product_id", "path_order"]],
        raw_classified.loc[raw_classified["path_order"].ne(4), ["user_id", "product_id", "path_order"]],
    ], ignore_index=True)
    split = pd.concat([mart_detail, raw_detail], ignore_index=True)
    split = split[["user_id", "product_id", "detail_path_order"]].rename(
        columns={"detail_path_order": "path_order"}
    )
    classified = pd.concat([ordinary, split], ignore_index=True)
    if classified.duplicated(["user_id", "product_id"]).any():
        raise ValueError("대표 첫 구매의 5경로가 중복 분류됐습니다.")
    if len(classified) != representative or classified["path_order"].isna().any():
        raise ValueError("대표 첫 구매의 5경로에 미분류가 있습니다.")
    counts = classified["path_order"].astype("int64").value_counts().to_dict()
    five = pd.DataFrame({
        "표시순서": range(1, 6),
        "경로순서": FIVE_DISPLAY_ORDER,
        "경로": [PATH_NAMES[i] for i in FIVE_DISPLAY_ORDER],
        "사용자상품수": [int(counts.get(i, 0)) for i in FIVE_DISPLAY_ORDER],
    })
    five["분모_대표첫구매"] = representative
    five["대표첫구매내비율_pct"] = five["사용자상품수"] / representative * 100
    if representative != REPRESENTATIVE_EXPECTED or eligible != ELIGIBLE_30DAY_EXPECTED:
        raise ValueError("30일 적격군 또는 대표 첫 구매 분모 회귀 검산 실패")
    if counts != {1: 103_974, 2: 14_291, 3: 113_677, 4: 57_679, 5: 52_836}:
        raise ValueError(f"대표 첫 구매 5경로 회귀 검산 실패: {counts}")
    if int(five["사용자상품수"].sum()) != representative:
        raise ValueError("대표 첫 구매 5경로 합계가 분모와 다릅니다.")
    if not math.isclose(float(five["대표첫구매내비율_pct"].sum()), 100.0, abs_tol=1e-9):
        raise ValueError("대표 첫 구매 5경로 비율 합계가 100%가 아닙니다.")

    four = pd.DataFrame({
        "표시순서": range(1, 5),
        "경로": [
            PATH_NAMES[3], "구매 전 Cart 미확인", PATH_NAMES[1], PATH_NAMES[2]
        ],
        "사용자상품수": [
            counts[3], counts[4] + counts[5], counts[1], counts[2]
        ],
    })
    four["분모_대표첫구매"] = representative
    four["대표첫구매내비율_pct"] = four["사용자상품수"] / representative * 100
    original_four = dict(zip(four_base["경로순서"], four_base["사용자상품수"]))
    if [original_four[3], original_four[4], original_four[1], original_four[2]] != four["사용자상품수"].tolist():
        raise ValueError("5경로 합산 결과와 기존 4경로 집계가 다릅니다.")
    if int(four["사용자상품수"].sum()) != representative:
        raise ValueError("대시보드 4경로 합계가 분모와 다릅니다.")
    return five, four, eligible, representative


def _cumulative_purchase(cart_rates: pd.DataFrame) -> tuple[pd.DataFrame, int, float]:
    rates = cart_rates.sort_values("구간순서").reset_index(drop=True)
    if rates["구간순서"].astype("int64").tolist() != list(range(7)):
        raise ValueError("최초 Cart 후 7개의 24시간 구간이 필요합니다.")
    eligible = int(rates.iloc[0]["구간시작_미구매_사용자상품수"])
    purchases = rates["다음24시간_구매_사용자상품수"].astype("int64")
    cumulative = purchases.cumsum()
    first_share = int(purchases.iloc[0]) / int(cumulative.iloc[-1]) * 100
    frame = pd.DataFrame({
        "경과시간_h": [0] + list(range(24, 169, 24)),
        "구간구매_사용자상품수": [0] + purchases.tolist(),
        "누적구매_사용자상품수": [0] + cumulative.tolist(),
    })
    frame["분모_7일관측_사용자상품수"] = eligible
    frame["누적동일상품구매율_pct"] = frame["누적구매_사용자상품수"] / eligible * 100
    frame["7일내구매중_첫24시간비중_pct"] = first_share
    if eligible != 4_082_470 or round(float(frame.iloc[1]["누적동일상품구매율_pct"]), 3) != 19.040:
        raise ValueError("Cart 이후 24시간 누적 구매율 회귀 검산 실패")
    if round(float(frame.iloc[-1]["누적동일상품구매율_pct"]), 3) != 22.591:
        raise ValueError("Cart 이후 7일 누적 구매율 회귀 검산 실패")
    return frame, eligible, first_share


def _experiment(experiment_daily: pd.DataFrame, cluster: pd.DataFrame) -> pd.DataFrame:
    daily = experiment_daily.assign(
        실험적격일=pd.to_datetime(experiment_daily["실험적격일"])
    ).groupby("실험적격일")["실험적격_사용자상품수"].sum()
    eligible = int(experiment_daily["실험적격_사용자상품수"].sum())
    purchased = int(experiment_daily["기준점후_7일_동일상품구매_사용자상품수"].sum())
    if (eligible, purchased) != (3_287_385, 154_517):
        raise ValueError("실험 적격군과 자연 구매 기준선 회귀 검산 실패")
    design = calculate_experiment_design(
        purchased / eligible, daily, relative_mdes=(0.05, 0.10),
        tracking_days=7, cluster_distribution=cluster,
    )
    frame = design.sample_size.copy()
    frame.insert(0, "실험상태", "설계안")
    frame["발송후보시점"] = "Cart 후 24시간"
    frame["분석단위"] = "적격 사용자×상품"
    frame["적격군_자연구매율_분모"] = eligible
    frame["적격군_7일동일상품구매_분자"] = purchased
    expected_independent = {"+5%": 260_662, "+10%": 66_672}
    for row in frame.itertuples(index=False):
        if row.독립가정_전체표본 != expected_independent[row.상대_MDE]:
            raise ValueError("독립 가정 표본 회귀 검산 실패")
        if row.군집보정_전체표본 < row.독립가정_전체표본:
            raise ValueError("군집 보정 표본이 독립 가정 표본보다 작습니다.")
    return frame


def build_sources(cache: existing.QueryCache) -> dict[str, pd.DataFrame]:
    cohort, mart, raw, cart_rates, experiment_daily, cluster = compat._load(cache)
    _, _, mart_params, raw_params = build_split_keys(mart, raw)
    mart_detail = cache.run("pj_no_cart_mart_view_split", params=mart_params)
    raw_detail = cache.run("pj_no_cart_raw_view_split", params=raw_params)
    five, four, eligible, representative = build_purchase_paths(
        cohort, mart, raw, mart_detail, raw_detail
    )
    cumulative, cart_eligible, _ = _cumulative_purchase(cart_rates)
    same_session = int(five.loc[five["경로순서"].eq(1), "사용자상품수"].iloc[0])
    if CART_AFTER_VIEW_30DAY != 683_794 or not same_session <= CART_AFTER_VIEW_30DAY <= eligible:
        raise ValueError("View → Cart → Purchase 퍼널 회귀 검산 실패")
    kpi = pd.DataFrame({
        "표시순서": [1, 2, 3, 4],
        "지표": [
            "분석 대상 사용자×상품 조합",
            "한 세션 View → Cart → Purchase",
            "세션을 이어 30일 내 동일 상품 구매",
            "Cart 후 24시간 내 동일 상품 구매",
        ],
        "값": [
            eligible,
            same_session / eligible * 100,
            representative / eligible * 100,
            float(cumulative.iloc[1]["누적동일상품구매율_pct"]),
        ],
        "단위": ["조합", "%", "%", "%"],
        "분모_사용자상품수": [eligible, eligible, eligible, cart_eligible],
    })
    funnel = pd.DataFrame({
        "단계순서": [1, 2, 3],
        "단계": ["View", "Cart", "Purchase"],
        "사용자상품수": [eligible, CART_AFTER_VIEW_30DAY, same_session],
    })
    funnel["분모_30일적격_사용자상품수"] = eligible
    funnel["View대비비율_pct"] = funnel["사용자상품수"] / eligible * 100
    funnel["중앙정렬_시작값"] = -funnel["사용자상품수"] / 2
    funnel["중앙정렬_막대너비"] = funnel["사용자상품수"]
    experiment = _experiment(experiment_daily, cluster)
    return {
        "dashboard_kpi.csv": kpi,
        "dashboard_funnel.csv": funnel,
        "dashboard_purchase_paths_5.csv": five,
        "dashboard_purchase_paths_4.csv": four,
        "dashboard_cumulative_purchase.csv": cumulative,
        "dashboard_experiment.csv": experiment,
    }


def main() -> None:
    cache = existing.build_final_cache()
    sources = build_sources(cache)
    for name, frame in sources.items():
        destination = OUTPUT_DIR / name
        if name == "dashboard_experiment.csv":
            # ICC와 군집 크기의 계산 정밀도를 CSV에서도 보존한다.
            temporary = destination.with_suffix(destination.suffix + ".tmp")
            frame.to_csv(temporary, index=False, encoding="utf-8-sig")
            temporary.replace(destination)
        else:
            existing._write_csv(frame, destination)
        print(f"{name}: {len(frame):,}행")


if __name__ == "__main__":
    main()
