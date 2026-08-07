"""Tableau 대시보드용 집계 CSV 생성 스크립트.

- 입력: 검증을 통과한 06 분석 결과 캐시(`cache/pj_*.parquet`). 20M행 `events`를 재조회하지 않는다.
- 지표 정의는 `docs/metrics.md`·06 노트북과 동일하며 여기서 새로 정의하지 않는다.
- 표시용 퍼센트·누적·"전체" 행은 이 스크립트에서 미리 계산해 CSV에 넣는다
  (Tableau가 퍼센트를 평균 내어 왜곡하는 것을 방지).
- 분석 단위·분모가 파일마다 다르므로 Tableau에서도 데이터 원본을 분리해 사용한다.

실행: `python tableau/export_tableau.py` (repo 루트 또는 tableau/ 어디서든)
출력: tableau/{funnel_summary,purchase_path,purchase_delay,category_comparison,experiment_design}.csv
"""

from pathlib import Path

import pandas as pd

ROOT = Path(__file__).resolve().parent.parent
CACHE = ROOT / "cache"
OUT = ROOT / "tableau"


def rd(name):
    return pd.read_parquet(CACHE / f"{name}.parquet")


def main():
    OUT.mkdir(exist_ok=True)

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
    pd.DataFrame(rows).to_csv(OUT / "funnel_summary.csv", index=False, encoding="utf-8-sig")

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
    path.to_csv(OUT / "purchase_path.csv", index=False, encoding="utf-8-sig")

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

    def add_cumulative(x):
        x = x.sort_values("최소_시간")
        t = x["구매에피소드수"].sum()
        x["구간비중_pct"] = (x["구매에피소드수"] / t * 100).round(2)
        x["누적비중_pct"] = (x["구매에피소드수"].cumsum() / t * 100).round(2)
        return x

    delay = delay.groupby("구매차수", group_keys=False)[
        ["구매차수", "기간구간", "구매에피소드수", "최소_시간"]
    ].apply(add_cumulative)
    delay = delay[["구매차수", "기간구간", "구매에피소드수", "구간비중_pct", "누적비중_pct", "최소_시간"]]
    delay.to_csv(OUT / "purchase_delay.csv", index=False, encoding="utf-8-sig")

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
    cc.to_csv(OUT / "category_comparison.csv", index=False, encoding="utf-8-sig")

    # 5) experiment_design — 근사 기준선 + 표본 설계값(06 산정)
    eb = rd("pj_experiment_baseline")
    eligible = int(eb["실험적격_사용자수"].sum())
    buy7 = int(eb["기준점후_7일_동일상품구매_사용자수"].sum())
    baseline = buy7 / eligible * 100
    pd.DataFrame(
        [
            ("실험적격_사용자수(최초cart+24h 미구매)", eligible, "근사 기준선 · 최초 cart 1회성 설계"),
            ("기준점후_7일_동일상품구매_사용자수", buy7, ""),
            ("대조군_7일_동일상품구매율_pct", round(baseline, 3), "알림 없는 자연 구매율(근사)"),
            ("발송_후보시점", "cart+24h", "성공구매 조건부 분포 기반 · 최적시점 아님"),
            ("MDE_상대_pct", 10, "양측 5% · 검정력 80%"),
            ("필요표본_총_명", 126548, "06 두 비율 검정 산정"),
            ("예상기간_최소_일", 64, "모집 57일 + 결과확인 7일"),
        ],
        columns=["항목", "값", "비고"],
    ).to_csv(OUT / "experiment_design.csv", index=False, encoding="utf-8-sig")

    print("생성 완료:", sorted(f.name for f in OUT.glob("*.csv")))


if __name__ == "__main__":
    main()
