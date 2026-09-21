"""Tableau 대시보드용 집계 CSV 생성 스크립트.

- 입력: 검증을 통과한 06 분석 결과 캐시(`cache/pj_*.parquet`). 20M행 `events`를 재조회하지 않는다.
- 지표 정의는 `docs/metrics.md`·06 노트북과 동일하며 여기서 새로 정의하지 않는다.
- 표시용 퍼센트·누적·"전체" 행은 이 스크립트에서 미리 계산해 CSV에 넣는다
  (Tableau가 퍼센트를 평균 내어 왜곡하는 것을 방지).
- 분석 단위·분모가 파일마다 다르므로 Tableau에서도 데이터 원본을 분리해 사용한다.

실행: `python tableau/export_tableau.py` (repo 루트 또는 tableau/ 어디서든)
출력: tableau/{funnel_summary,purchase_path,purchase_delay,category_comparison,experiment_design}.csv
"""

import argparse
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


def build_engine():
    """Build a lazy engine used only to derive the sanitized cache source identity."""
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


def main(cache_dir=None, output_dir=None):
    out = Path(output_dir or os.getenv("TABLEAU_OUTPUT_DIR", ROOT / "tableau")).resolve()
    out.mkdir(parents=True, exist_ok=True)
    cache = QueryCache(
        engine=build_engine(),
        sql_file=ROOT / "sql" / "06_purchase_journey_analysis.sql",
        upstream_sql_files=(ROOT / "sql" / "02_preprocessing_mart.sql",),
        cache_dir=cache_dir,
    )

    def rd(name):
        return cache.read_cached(name)

    # 1) funnel_summary — 동일 사용자·상품·관측창 공통 분모의 세션 3단계 완주 vs 세션 통합 구매
    win = rd("pj_user_product_window")
    total = win[win["카테고리구분"] == "전체"].iloc[0]
    same_session = rd("pj_user_product_same_session_funnel")
    rows = []
    for _, s in same_session.iterrows():
        period = s["구매확인기간"]
        denom = float(s["구매판정가능_사용자상품수"])
        complete = float(s["동일세션_view_cart_purchase완주_사용자상품수"])
        cross = float(total[f"{period}_세션통합구매_사용자상품수"])
        rows.append(
            dict(
                구매확인기간=period,
                구매판정가능_사용자상품수=int(denom),
                동일세션3단계완주_수=int(complete),
                동일세션3단계완주율_pct=round(complete / denom * 100, 3),
                세션통합동일상품구매_수=int(cross),
                세션통합구매율_pct=round(cross / denom * 100, 3),
                동일세션3단계밖구매_수=int(cross - complete),
                동일세션3단계밖구매비중_pct=round((cross - complete) / cross * 100, 2),
            )
        )
    pd.DataFrame(rows).to_csv(out / "funnel_summary.csv", index=False, encoding="utf-8-sig")

    # 2) purchase_path — 구매차수 × 6개 배타 경로. 경로비중은 구매차수 그룹 내 precompute.
    p = rd("pj_purchase_paths")
    by_order = p.groupby(["구매차수", "구매경로"], as_index=False).agg(
        구매_세션상품수=("구매_세션상품수", "sum"), revenue=("revenue", "sum")
    )
    overall = p.groupby("구매경로", as_index=False).agg(
        구매_세션상품수=("구매_세션상품수", "sum"), revenue=("revenue", "sum")
    )
    overall.insert(0, "구매차수", "전체")
    path = pd.concat([overall, by_order], ignore_index=True)
    path["경로비중_pct"] = path.groupby("구매차수")["구매_세션상품수"].transform(
        lambda s: (s / s.sum() * 100).round(2)
    )
    path["revenue"] = path["revenue"].round(2)
    path = path.sort_values(["구매차수", "구매_세션상품수"], ascending=[True, False])
    path.to_csv(out / "purchase_path.csv", index=False, encoding="utf-8-sig")

    # 3) purchase_delay — 다른 세션 cart→purchase 시간 간격. 구간·누적 비중 precompute.
    #    주의: 이 분포는 '성공한 구매 경로'에만 조건부이며 최적 발송 시점을 뜻하지 않는다.
    d = rd("pj_cross_session_cart_delay")
    overall_d = d.groupby("기간구간", as_index=False).agg(
        구매에피소드수=("구매에피소드수", "sum"), 최소_시간=("최소_시간", "min")
    )
    overall_d.insert(0, "구매차수", "전체")
    delay = pd.concat(
        [overall_d, d[["구매차수", "기간구간", "구매에피소드수", "최소_시간"]]], ignore_index=True
    )

    # 구간 시간 폭(시간). 시간당 평균 비중 = 24h 재기준 구간비중 / 시간 폭.
    BIN_HOURS = {
        "1시간 미만": 1, "1-6시간": 5, "6-12시간": 6, "12-24시간": 12,
        "1-3일": 48, "4-7일": 96, "8-14일": 168, "15-30일": 384,
    }
    delay["구간시간폭_시간"] = delay["기간구간"].map(BIN_HOURS)

    def add_shares(x):
        x = x.sort_values("최소_시간")
        t = x["구매에피소드수"].sum()
        x["구간비중_pct"] = (x["구매에피소드수"] / t * 100).round(2)
        x["누적비중_pct"] = (x["구매에피소드수"].cumsum() / t * 100).round(2)
        # 24시간 미만(최소_시간 < 24)만 100%로 재기준한 구간비중·시간당 평균 비중
        m = x["최소_시간"] < 24
        t24 = x.loc[m, "구매에피소드수"].sum()
        x["구간비중_24h재기준_pct"] = pd.NA
        x["시간당평균비중_pct"] = pd.NA
        share24 = x.loc[m, "구매에피소드수"] / t24 * 100
        x.loc[m, "구간비중_24h재기준_pct"] = share24.round(2)
        x.loc[m, "시간당평균비중_pct"] = (share24 / x.loc[m, "구간시간폭_시간"]).round(2)
        return x

    delay = delay.groupby("구매차수", group_keys=False)[
        ["구매차수", "기간구간", "구매에피소드수", "최소_시간", "구간시간폭_시간"]
    ].apply(add_shares)
    delay = delay[[
        "구매차수", "기간구간", "구매에피소드수", "구간비중_pct", "누적비중_pct",
        "구간비중_24h재기준_pct", "시간당평균비중_pct", "구간시간폭_시간", "최소_시간",
    ]]
    delay.to_csv(out / "purchase_delay.csv", index=False, encoding="utf-8-sig")

    # 4) category_comparison — 04 우선진단 vs 그 외, 30일 세션 통합 구매율(분모 병기)
    cat = win[win["카테고리구분"] != "전체"].copy()
    cc = pd.DataFrame(
        dict(
            카테고리구분=cat["카테고리구분"].values,
            구매판정가능_사용자상품수_30일=cat["30일구매판정가능_사용자상품수"].astype(int).values,
            세션통합구매_30일=cat["30일_세션통합구매_사용자상품수"].astype(int).values,
        )
    )
    cc["30일동일상품구매율_pct"] = (cc["세션통합구매_30일"] / cc["구매판정가능_사용자상품수_30일"] * 100).round(3)
    cc.to_csv(out / "category_comparison.csv", index=False, encoding="utf-8-sig")

    # 5) experiment_design — MDE 2시나리오(+5%/+10%) 토글용 한 줄씩.
    #    근사 기준선·적격 사용자수는 캐시에서, 목표·표본·기간은 06의 두 비율 검정 산정값(검증됨).
    eb = rd("pj_experiment_baseline")
    eligible = int(eb["실험적격_사용자수"].sum())
    buy7 = int(eb["기준점후_7일_동일상품구매_사용자수"].sum())
    baseline_rate = buy7 / eligible

    daily_eligible_users = (
        eb.assign(실험적격일=pd.to_datetime(eb["실험적격일"]))
        .groupby("실험적격일")["실험적격_사용자수"]
        .sum()
    )
    experiment_design = calculate_experiment_design(
        baseline_rate,
        daily_eligible_users,
    )

    hazard = rd("pj_cart_purchase_daily_hazard")
    hazard_rates = hazard.set_index("구간순서")["구간구매위험률_pct"]
    required_intervals = {0, 1}
    if not required_intervals.issubset(hazard_rates.index):
        raise ValueError("구매 위험률 캐시에 0-24시간·24-48시간 구간이 모두 필요합니다.")
    first_24h_rate = round(float(hazard_rates.loc[0]), 3)  # 15.413
    next_24h_rate = round(float(hazard_rates.loc[1]), 3)  # 0.877

    primary_relative_mde = max(
        experiment_design.sample_size["상대_MDE"]
        .str.removeprefix("+")
        .str.removesuffix("%")
        .astype(int)
    )
    experiment_rows = []
    for scenario in experiment_design.sample_size.itertuples(index=False):
        relative_mde_pct = int(scenario.상대_MDE.removeprefix("+").removesuffix("%"))
        primary_note = "(1차 후보)" if relative_mde_pct == primary_relative_mde else ""
        experiment_rows.append({
            "MDE_상대_pct": relative_mde_pct,
            "대조군_7일구매율_pct": round(scenario.기준구매율_pct, 3),
            "목표구매율_pct": round(scenario.처리군_목표구매율_pct, 3),
            "절대MDE_pctp": round(scenario.절대_MDE_pctp, 3),
            "군별_필요표본_명": scenario.군별_필요사용자수,
            "전체_필요표본_명": scenario.전체_필요사용자수,
            "예상기간_최소_일": scenario.예상_모집일수 + experiment_design.tracking_days,
            "실험적격_사용자수": eligible,
            "발송_후보시점": "cart+24h",
            "첫24시간_구매율_pct": first_24h_rate,
            "24_48시간_구매율_pct": next_24h_rate,
            "비고": (
                f"상대 {relative_mde_pct}% 개선{primary_note} · "
                f"모집 {scenario.예상_모집일수}일+확인 {experiment_design.tracking_days}일"
            ),
        })
    pd.DataFrame(experiment_rows).to_csv(
        out / "experiment_design.csv",
        index=False,
        encoding="utf-8-sig",
    )

    print("생성 완료:", sorted(f.name for f in out.glob("*.csv")))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--cache-dir", help="검증할 provenance cache 루트")
    parser.add_argument("--output-dir", help="CSV 출력 디렉터리")
    args = parser.parse_args()
    main(cache_dir=args.cache_dir, output_dir=args.output_dir)
