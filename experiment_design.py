"""Canonical sample-size and recruitment-duration calculations for the CRM experiment."""

from __future__ import annotations

import math
from dataclasses import dataclass
from statistics import NormalDist
from typing import Sequence

import pandas as pd


@dataclass(frozen=True)
class ExperimentDesignResult:
    """Calculated experiment scenarios and the traffic statistics behind them."""

    sample_size: pd.DataFrame
    daily_eligible_users: pd.Series
    rolling_28day_daily_users: pd.Series
    average_daily_eligible_users: float
    median_daily_eligible_users: float
    conservative_daily_eligible_users: float
    tracking_days: int


def _validate_probability(value: float, name: str) -> float:
    value = float(value)
    if not math.isfinite(value) or not 0 < value < 1:
        raise ValueError(f"{name}은 0보다 크고 1보다 작은 유한한 값이어야 합니다.")
    return value


def two_proportion_sample_size(
    baseline_rate: float,
    relative_mde: float,
    *,
    alpha: float = 0.05,
    power: float = 0.80,
) -> tuple[float, int]:
    """Return the target rate and per-group sample for a two-sided equal-allocation test."""
    baseline_rate = _validate_probability(baseline_rate, "baseline_rate")
    alpha = _validate_probability(alpha, "alpha")
    power = _validate_probability(power, "power")
    relative_mde = float(relative_mde)
    if not math.isfinite(relative_mde) or relative_mde <= 0:
        raise ValueError("relative_mde는 0보다 큰 유한한 값이어야 합니다.")

    target_rate = baseline_rate * (1 + relative_mde)
    if target_rate >= 1:
        raise ValueError("baseline_rate와 relative_mde로 계산한 목표 구매율은 1보다 작아야 합니다.")

    pooled_rate = (baseline_rate + target_rate) / 2
    z_alpha = NormalDist().inv_cdf(1 - alpha / 2)
    z_power = NormalDist().inv_cdf(power)
    numerator = (
        z_alpha * math.sqrt(2 * pooled_rate * (1 - pooled_rate))
        + z_power
        * math.sqrt(
            baseline_rate * (1 - baseline_rate)
            + target_rate * (1 - target_rate)
        )
    ) ** 2
    users_per_group = math.ceil(
        numerator / (target_rate - baseline_rate) ** 2
    )
    return target_rate, users_per_group


def cluster_design_effect(cluster_distribution: pd.DataFrame) -> tuple[float, float, float]:
    """Return ICC, unequal-cluster adjusted size, and the exact design effect.

    The distribution is grouped by (eligible pairs per user, purchased pairs per
    user); ``사용자수`` is the frequency of each group. The adjusted size is the
    value used in the existing notebook's one-way ANOVA ICC calculation, rather
    than a rounded display average.
    """
    required = {"사용자수", "보유_사용자상품수", "구매_사용자상품수"}
    if not isinstance(cluster_distribution, pd.DataFrame) or not required.issubset(cluster_distribution):
        raise ValueError(f"cluster_distribution에는 {sorted(required)} 열이 필요합니다.")
    users = pd.to_numeric(cluster_distribution["사용자수"], errors="raise")
    sizes = pd.to_numeric(cluster_distribution["보유_사용자상품수"], errors="raise")
    buys = pd.to_numeric(
        cluster_distribution["구매_사용자상품수"].fillna(0), errors="raise"
    )
    if (users.isna().any() or sizes.isna().any() or buys.isna().any()
            or not (users > 0).all() or not (sizes > 0).all()
            or not ((0 <= buys) & (buys <= sizes)).all()
            or not ((users % 1 == 0) & (sizes % 1 == 0) & (buys % 1 == 0)).all()):
        raise ValueError("사용자별 조합 분포에는 유효한 양의 정수 빈도·크기와 구매 수가 필요합니다.")

    user_n = int(users.sum())
    pair_n = int((users * sizes).sum())
    if user_n <= 1 or pair_n <= user_n:
        raise ValueError("ICC 계산에는 사용자 2명 이상과 사용자당 복수 조합이 필요합니다.")
    grand_rate = float((users * buys).sum() / pair_n)
    user_rate = buys / sizes
    ms_between = float((users * sizes * (user_rate - grand_rate) ** 2).sum()) / (user_n - 1)
    ms_within = float((users * sizes * user_rate * (1 - user_rate)).sum()) / (pair_n - user_n)
    adjusted_size = (pair_n - float((users * sizes ** 2).sum()) / pair_n) / (user_n - 1)
    denominator = ms_between + (adjusted_size - 1) * ms_within
    if denominator <= 0:
        raise ValueError("ICC 분모가 0 이하입니다.")
    icc = max(0.0, (ms_between - ms_within) / denominator)
    return icc, adjusted_size, 1 + (adjusted_size - 1) * icc


def _complete_daily_series(
    daily_eligible_users: pd.Series,
    *,
    rolling_window: int,
) -> pd.Series:
    if not isinstance(daily_eligible_users, pd.Series):
        raise TypeError("daily_eligible_users는 날짜 index를 가진 pandas Series여야 합니다.")
    if daily_eligible_users.empty:
        raise ValueError("daily_eligible_users가 비어 있습니다.")
    if not isinstance(rolling_window, int) or rolling_window <= 0:
        raise ValueError("rolling_window는 1 이상의 정수여야 합니다.")

    try:
        dates = pd.DatetimeIndex(pd.to_datetime(daily_eligible_users.index)).normalize()
        values = pd.to_numeric(daily_eligible_users, errors="raise")
    except (TypeError, ValueError) as error:
        raise ValueError("daily_eligible_users에는 유효한 날짜와 숫자가 필요합니다.") from error

    if values.isna().any() or not values.map(math.isfinite).all():
        raise ValueError("daily_eligible_users에는 결측값이나 무한값을 사용할 수 없습니다.")
    if (values < 0).any():
        raise ValueError("daily_eligible_users에는 음수를 사용할 수 없습니다.")

    daily = pd.Series(values.to_numpy(), index=dates, name=daily_eligible_users.name)
    daily = daily.groupby(level=0).sum().sort_index()
    full_dates = pd.date_range(daily.index.min(), daily.index.max(), freq="D")
    daily = daily.reindex(full_dates, fill_value=0)
    if len(daily) < rolling_window:
        raise ValueError(
            f"보수적 트래픽 계산에는 최소 {rolling_window}일의 일별 데이터가 필요합니다 "
            f"(현재 {len(daily)}일)."
        )
    return daily


def calculate_experiment_design(
    baseline_rate: float,
    daily_eligible_users: pd.Series,
    *,
    relative_mdes: Sequence[float] = (0.05, 0.10),
    alpha: float = 0.05,
    power: float = 0.80,
    tracking_days: int = 7,
    rolling_window: int = 28,
    conservative_quantile: float = 0.25,
    cluster_distribution: pd.DataFrame | None = None,
) -> ExperimentDesignResult:
    """Calculate the canonical 1:1 experiment designs without display rounding.

    `daily_eligible_users`가 (사용자, 상품) 쌍이면 필요 표본도 쌍 수다.
    `cluster_distribution`을 넘기면 사용자별 복수 쌍의 ICC와 설계효과를
    반올림 없이 적용한다. 기존 표본 열은 독립 가정 값으로 유지한다.
    """
    baseline_rate = _validate_probability(baseline_rate, "baseline_rate")
    alpha = _validate_probability(alpha, "alpha")
    power = _validate_probability(power, "power")
    if not isinstance(tracking_days, int) or tracking_days < 0:
        raise ValueError("tracking_days는 0 이상의 정수여야 합니다.")
    conservative_quantile = float(conservative_quantile)
    if not math.isfinite(conservative_quantile) or not 0 <= conservative_quantile <= 1:
        raise ValueError("conservative_quantile은 0 이상 1 이하의 유한한 값이어야 합니다.")

    relative_mdes = tuple(relative_mdes)
    if not relative_mdes:
        raise ValueError("relative_mdes에는 하나 이상의 상대 MDE가 필요합니다.")

    daily = _complete_daily_series(
        daily_eligible_users,
        rolling_window=rolling_window,
    )
    average_daily = float(daily.mean())
    median_daily = float(daily.median())
    rolling_daily = daily.rolling(
        window=rolling_window,
        min_periods=rolling_window,
    ).mean().dropna()
    conservative_daily = float(rolling_daily.quantile(conservative_quantile))
    if average_daily <= 0 or conservative_daily <= 0:
        raise ValueError("모집 기간 계산에 사용할 일별 적격 사용자 수는 0보다 커야 합니다.")

    if cluster_distribution is None:
        icc = average_size = adjusted_size = design_effect = float("nan")
    else:
        icc, adjusted_size, design_effect = cluster_design_effect(cluster_distribution)
        cluster_users = int(pd.to_numeric(cluster_distribution["사용자수"]).sum())
        cluster_pairs = int((
            pd.to_numeric(cluster_distribution["사용자수"])
            * pd.to_numeric(cluster_distribution["보유_사용자상품수"])
        ).sum())
        average_size = cluster_pairs / cluster_users
        if cluster_pairs != int(daily.sum()):
            raise ValueError("군집 분포의 적격 조합 수와 일별 적격 조합 수가 다릅니다.")

    rows = []
    for relative_mde in relative_mdes:
        target_rate, users_per_group = two_proportion_sample_size(
            baseline_rate,
            relative_mde,
            alpha=alpha,
            power=power,
        )
        total_users = users_per_group * 2
        corrected_total = (
            math.ceil(total_users * design_effect)
            if cluster_distribution is not None else pd.NA
        )
        period_sample = corrected_total if cluster_distribution is not None else total_users
        recruitment_days = math.ceil(period_sample / average_daily)
        conservative_recruitment_days = math.ceil(period_sample / conservative_daily)
        rows.append({
            "상대_MDE": f"+{relative_mde * 100:.0f}%",
            "기준구매율_pct": baseline_rate * 100,
            "처리군_목표구매율_pct": target_rate * 100,
            "절대_MDE_pctp": (target_rate - baseline_rate) * 100,
            "군별_필요표본수": users_per_group,
            "전체_필요표본수": total_users,
            "독립가정_군별표본": users_per_group,
            "독립가정_전체표본": total_users,
            "ICC": icc,
            "평균_클러스터크기": average_size,
            "설계_보정_클러스터크기": adjusted_size,
            "설계효과": design_effect,
            "군집보정_전체표본": corrected_total,
            "예상_모집일수": recruitment_days,
            "7일추적포함_최소일수": recruitment_days + tracking_days,
            "보수적_예상모집일수": conservative_recruitment_days,
            "보수적_7일추적포함_일수": conservative_recruitment_days + tracking_days,
            "과거관측기간내_모집가능여부": (
                "가능" if recruitment_days + tracking_days <= len(daily) else "어려움"
            ),
        })

    return ExperimentDesignResult(
        sample_size=pd.DataFrame(rows),
        daily_eligible_users=daily,
        rolling_28day_daily_users=rolling_daily,
        average_daily_eligible_users=average_daily,
        median_daily_eligible_users=median_daily,
        conservative_daily_eligible_users=conservative_daily,
        tracking_days=tracking_days,
    )
