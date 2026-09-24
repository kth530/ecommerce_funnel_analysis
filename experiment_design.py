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
) -> ExperimentDesignResult:
    """Calculate the canonical 1:1 experiment designs without display rounding.

    `daily_eligible_users`의 단위는 호출자가 정한다. 05 분석은 (사용자, 상품) 쌍을
    넘기므로 반환되는 필요 표본도 쌍 수다. 배정은 사용자 단위이므로, 표본을 사용자
    수로 환산하는 일은 호출자가 쌍/사용자 비율로 수행한다.
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

    rows = []
    for relative_mde in relative_mdes:
        target_rate, users_per_group = two_proportion_sample_size(
            baseline_rate,
            relative_mde,
            alpha=alpha,
            power=power,
        )
        total_users = users_per_group * 2
        recruitment_days = math.ceil(total_users / average_daily)
        conservative_recruitment_days = math.ceil(total_users / conservative_daily)
        rows.append({
            "상대_MDE": f"+{relative_mde * 100:.0f}%",
            "기준구매율_pct": baseline_rate * 100,
            "처리군_목표구매율_pct": target_rate * 100,
            "절대_MDE_pctp": (target_rate - baseline_rate) * 100,
            "군별_필요표본수": users_per_group,
            "전체_필요표본수": total_users,
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
