"""Pure decisions: routing eligibility, confidence and replacement thresholds."""
from __future__ import annotations
import math
import statistics
from enum import StrEnum


class State(StrEnum):
    CHECKING = 'Проверяется'
    READY = 'Готов'
    SUSPECT = 'Подозрение на отказ'
    QUARANTINE = 'Временно исключён'
    ARCHIVED = 'История'
    EXCLUDED = 'Исключён вручную'


def recent(observations, now):
    return [item for item in observations if now - 300 <= item['at'] <= now]


def reliability(observations, now):
    """Wilson lower bound, capped evidence so faster sampling gets no extra vote."""
    values = recent(observations, now)
    if not values: return 0.0
    count = min(len(values), 30)
    p = sum(bool(item['ok']) for item in values) / len(values)
    z = 1.28
    return (p + z*z/(2*count) - z*math.sqrt(p*(1-p)/count + z*z/(4*count*count))) / (1+z*z/count)


def percentile(observations, now, fraction=.9):
    values = sorted(item['seconds'] for item in recent(observations, now) if item['ok'])
    if not values: return float('inf')
    return values[max(0, math.ceil(len(values)*fraction)-1)]


def rank(channel, now):
    speed = channel.node.download_mbps if now-channel.speed_at < 7200 else None
    return (-reliability(channel.observations, now), percentile(channel.observations, now),
            channel.latency(now), -(speed or 0))


def eligible(channel, now, freshness, countries=None, require_udp=True, provisional=False):
    if channel.state==State.SUSPECT and not provisional:return False
    if not channel.healthy or channel.excluded or now-channel.last > freshness: return False
    if countries is not None and channel.node.country not in countries: return False
    if not channel.admitted and not (provisional and len(channel.observations) >= 2): return False
    return not require_udp or (channel.udp_at > 0 and now-channel.udp_at <= freshness and channel.udp_ok)


def improvement(current, challenger, now):
    """Three recent successes and material latency gain before planned switching."""
    good = [item for item in recent(challenger.observations, now) if item['ok']]
    if len(good) < 3 or challenger.rate(now) < current.rate(now): return False
    old = percentile(current.observations, now); new = percentile(challenger.observations, now)
    return math.isfinite(old) and old-new >= .05 and new <= old * .7


def retry_delay(failures):
    return min(3600, 60 * 2 ** min(max(0, failures-1), 6))
