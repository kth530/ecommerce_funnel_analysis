"""기존 Tableau 워크북의 컬럼 계약에 맞춘 CSV를 생성한다.

- 워크북(`이커머스 퍼널 분석 대시보드.twbx`)은 이전 분석 시절의 컬럼명을 필드로 바인딩하고 있다.
  현재 `export_tableau.py`가 내보내는 새 컬럼명과는 이름이 달라, 그대로 두면
  Tableau가 모든 필드를 누락으로 표시한다. 이 스크립트는 **같은 05 캐시**에서
  워크북이 기대하는 이름·구조로 다시 내보내 디자인을 유지한 채 데이터만 교체한다.
- 지표 정의는 05 노트북과 동일하며 여기서 새로 정의하지 않는다.
- 현재 분석에 존재하지 않는 값(`revenue`, 구매차수 분해)은 임의로 만들지 않고
  아래 주석에 명시한 방식으로만 채운다.

실행: ``python tableau/export_workbook_compat.py [출력디렉터리]``
기본 출력: ``tableau/_workbook_compat/``
"""

from __future__ import annotations

import sys
from pathlib import Path

import pandas as pd

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))
if str(ROOT / "tableau") not in sys.path:
    sys.path.insert(0, str(ROOT / "tableau"))

import export_tableau as ex  # noqa: E402
from experiment_design import calculate_experiment_design  # noqa: E402
from query_cache import QueryCache  # noqa: E402

# 워크북 P_MDE 매개변수가 5%·10% 두 값을 토글하므로 두 시나리오를 모두 내보낸다.
WORKBOOK_RELATIVE_MDES = (0.05, 0.10)
OBSERVATION_LABEL = f"{ex.OBSERVATION_DAYS}일"


def _load(cache: QueryCache):
    """export_tableau.main과 같은 순서로 검증된 캐시만 읽는다."""
    purchase_cohort = cache.read_cached("pj_30day_purchase_cohort")
    mart_paths = cache.read_cached("pj_representative_purchase_mart")
    raw_params, _ = ex._build_boundary_params(mart_paths)
    raw_paths = cache.read_cached("pj_boundary_raw_paths", params=raw_params)

    cart_boundaries = cache.read_cached("pj_cart_purchase_boundaries")
    cart_raw_params, _ = ex._build_cart_boundary_params(cart_boundaries)
    cart_raw_corrections = cache.read_cached(
        "pj_cart_boundary_raw_next_purchase", params=cart_raw_params
    )
    correction_params = ex._build_cart_correction_params(cart_raw_corrections)
    cart_rates = cache.read_cached(
        "pj_cart_purchase_next_24h_rate", params=correction_params
    )
    experiment_daily = cache.read_cached(
        "pj_experiment_baseline", params=correction_params
    )
    cluster_dist = cache.read_cached(
        "pj_experiment_user_cluster", params=correction_params
    )
    return purchase_cohort, mart_paths, raw_paths, cart_rates, experiment_daily, cluster_dist


def build_funnel_summary(path_summary, eligible_n, purchase_n) -> pd.DataFrame:
    """워크북 funnel_summary 계약(8열).

    옛 CSV는 1일·7일·30일 3행이었으나 현재 분석은 30일만 계산하므로 1행만 내보낸다.
    `동일세션3단계완주_수`는 경로 1(같은 세션 조회→담기→첫 구매)이다. 옛 지표와
    이름은 같지만 대표 첫 구매 기준이라는 점이 다르므로 대시보드 캡션에 반영한다.
    """
    same_visit_n = int(
        path_summary.loc[path_summary["경로순서"].eq(1), "사용자상품수"].iloc[0]
    )
    outside_n = purchase_n - same_visit_n
    return pd.DataFrame([{
        "구매확인기간": OBSERVATION_LABEL,
        "구매판정가능_사용자상품수": int(eligible_n),
        "동일세션3단계완주_수": same_visit_n,
        "동일세션3단계완주율_pct": round(same_visit_n / eligible_n * 100, 3),
        "세션통합동일상품구매_수": int(purchase_n),
        "세션통합구매율_pct": round(purchase_n / eligible_n * 100, 3),
        "동일세션3단계밖구매_수": outside_n,
        "동일세션3단계밖구매비중_pct": round(outside_n / purchase_n * 100, 2),
    }])


def build_purchase_path(path_summary) -> pd.DataFrame:
    """워크북 purchase_path 계약(5열).

    `구매차수`는 현재 분석에 없는 차원이라 옛 CSV의 '전체' 행만 내보낸다.
    `revenue`는 05 쿼리가 집계하지 않으므로 값을 만들지 않고 결측으로 둔다.
    """
    frame = pd.DataFrame({
        "구매차수": "전체",
        "구매경로": path_summary["대표첫구매경로"],
        "구매_세션상품수": path_summary["사용자상품수"].astype("int64"),
        "revenue": pd.NA,
        "경로비중_pct": path_summary["대표첫구매내비율_pct"].round(2),
    })
    return frame.sort_values("구매_세션상품수", ascending=False, ignore_index=True)


def build_experiment_design(experiment_daily, cart_rates, cluster_dist) -> pd.DataFrame:
    """워크북 experiment_design 계약(12열). MDE 5%·10% 두 행."""
    eligible_n = int(experiment_daily["실험적격_사용자상품수"].sum())
    purchase_7day_n = int(experiment_daily["기준점후_7일_동일상품구매_사용자상품수"].sum())
    baseline_rate = purchase_7day_n / eligible_n
    daily = (
        experiment_daily.assign(실험적격일=pd.to_datetime(experiment_daily["실험적격일"]))
        .groupby("실험적격일")["실험적격_사용자상품수"]
        .sum()
    )
    design = calculate_experiment_design(
        baseline_rate,
        daily,
        relative_mdes=WORKBOOK_RELATIVE_MDES,
        alpha=ex.ALPHA,
        power=ex.POWER,
        tracking_days=ex.TRACKING_DAYS,
    )
    # 캐시 원본에는 구매율이 없으므로 export_tableau와 같은 계산을 거쳐 쓴다.
    rates = (
        ex._cart_purchase_rate(cart_rates)
        .set_index("구간순서")["구간별다음24시간구매율_pct"]
    )
    if not {0, 1}.issubset(rates.index):
        raise ValueError("0-24시간·24-48시간 구간이 모두 필요합니다.")
    first_24h, next_24h = round(float(rates.loc[0]), 3), round(float(rates.loc[1]), 3)

    # 대표 설계는 export_tableau의 RELATIVE_MDE와 같은 시나리오다.
    primary = int(round(ex.RELATIVE_MDE * 100))
    # 지표·표본은 (사용자, 상품) 쌍이지만 배정·발송은 사용자 단위다. 워크북 카드가
    # 사람 수를 보여주도록 쌍을 사용자 수로 환산해 `..._명` 열에 넣는다. 같은 사용자가
    # 다른 날 다시 적격이 될 수 있어 일자 기준 비율을 쓴다(사용자 수를 크게 잡는 쪽).
    eligible_user_days = int(experiment_daily["실험적격_사용자수"].sum())
    # 표본·기간은 05 노트북과 같은 설계효과를 반영한다.
    _icc, _adjusted, design_effect = ex.cluster_design_effect(cluster_dist)

    def to_users(pairs: int) -> int:
        return -(-int(pairs) * eligible_user_days // eligible_n)

    rows = []
    for s in design.sample_size.itertuples(index=False):
        mde = int(s.상대_MDE.removeprefix("+").removesuffix("%"))
        group_pairs = ex.inflate(s.군별_필요표본수, design_effect)
        total_pairs = ex.inflate(s.전체_필요표본수, design_effect)
        total_days = ex.recruit_days(
            total_pairs, design.average_daily_eligible_users
        ) + design.tracking_days
        rows.append({
            "MDE_상대_pct": mde,
            "대조군_7일구매율_pct": round(s.기준구매율_pct, 3),
            "목표구매율_pct": round(s.처리군_목표구매율_pct, 3),
            "절대MDE_pctp": round(s.절대_MDE_pctp, 3),
            "군별_필요표본_명": to_users(group_pairs),
            "전체_필요표본_명": to_users(total_pairs),
            "예상기간_최소_일": total_days,
            # 워크북 계약상 이름은 유지하되 값은 적격 (사용자, 상품) 쌍 수다.
            "실험적격_사용자수": eligible_n,
            "발송_후보시점": "cart+24h",
            "첫24시간_구매율_pct": first_24h,
            "24_48시간_구매율_pct": next_24h,
            "비고": (
                f"상대 {mde}% 개선{'(1차 후보)' if mde == primary else ''} · "
                f"{total_pairs:,}쌍 = 약 {to_users(total_pairs):,}명 · "
                f"설계효과 {design_effect:.2f}배 반영 · 총 {total_days}일"
            ),
        })
    return pd.DataFrame(rows)


def build_cart_cumulative(cart_rates) -> pd.DataFrame:
    """대시보드 2의 누적 곡선용. 05 노트북 §4의 누적 구매율과 같은 정의다.

    구간별 구매율은 구간마다 분모가 달라 더할 수 없으므로, 최초 담기 사용자 전체를
    고정 분모로 둔 누적값을 쓴다. 담기 시점(0시간·0%)을 첫 행으로 넣어 첫 24시간의
    상승 폭이 곡선에 드러나게 한다.
    """
    d = cart_rates.sort_values("구간순서").copy()
    base = int(d["구간시작_미구매_사용자상품수"].iloc[0])
    cumulative = d["다음24시간_구매_사용자상품수"].fillna(0).cumsum().astype("int64")
    rows = [{
        "구간순서": -1, "경과시간": "0시간", "경과시간_시간": 0,
        "누적_구매_사용자수": 0, "누적_구매율_pct": 0.0,
    }]
    for order, end_hour, users in zip(d["구간순서"], d["구간종료_시간"], cumulative):
        rows.append({
            "구간순서": int(order),
            "경과시간": f"{int(end_hour)}시간",
            "경과시간_시간": int(end_hour),
            "누적_구매_사용자수": int(users),
            "누적_구매율_pct": round(users / base * 100, 3),
        })
    return pd.DataFrame(rows)


def main(output_dir: str | None = None) -> None:
    out = Path(output_dir or ROOT / "tableau" / "_workbook_compat").resolve()
    out.mkdir(parents=True, exist_ok=True)
    cache = QueryCache(
        engine=ex.build_engine(),
        sql_file=ROOT / "sql" / "05_purchase_journey_analysis.sql",
        upstream_sql_files=(ROOT / "sql" / "02_preprocessing_mart.sql",),
    )
    cohort, mart_paths, raw_paths, cart_rates, experiment_daily, cluster_dist = _load(cache)
    path_summary, eligible_n, purchase_n = ex._path_summary(cohort, mart_paths, raw_paths)

    written = {
        "funnel_summary.csv": build_funnel_summary(path_summary, eligible_n, purchase_n),
        "purchase_path.csv": build_purchase_path(path_summary),
        "experiment_design.csv": build_experiment_design(
            experiment_daily, cart_rates, cluster_dist
        ),
        "cart_cumulative.csv": build_cart_cumulative(cart_rates),
    }
    for name, frame in written.items():
        ex._write_csv(frame, out / name)
        print(f"- {name}: {len(frame)}행 × {frame.shape[1]}열")
    print(f"출력 위치: {out}")
    print("워크북이 쓰던 purchase_delay.csv는 현재 분석에 대응 데이터가 없어 생성하지 않는다.")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else None)
