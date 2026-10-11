"""Kursdaten: CoinGecko-Client, Tick-Speicher und Kerzen-Bau.

CoinGecko liefert ueber ``/market_chart?days=1`` nur Punkte im ~5-Minuten-Raster.
Fuer echte 1-Minuten-Kerzen fragt der Bot zusaetzlich bei jedem Durchlauf
``/simple/price`` ab (ein Request fuer alle Coins) und baut die Kerzen selbst aus
diesen Ticks. Die History dient nur als Startwert, damit das Chart sofort
etwas zeigt.
"""

from __future__ import annotations

import dataclasses
import json
import math
import random
import time
import urllib.error
import urllib.parse
import urllib.request
from typing import Dict, Iterable, List, Optional, Sequence, Tuple

Tick = Tuple[float, float]  # (unix-Sekunden, Preis)

DEMO_BASE_URL = "https://api.coingecko.com/api/v3"
PRO_BASE_URL = "https://pro-api.coingecko.com/api/v3"


@dataclasses.dataclass(frozen=True)
class Candle:
    ts: float  # Startzeit der Kerze (unix-Sekunden)
    open: float
    high: float
    low: float
    close: float

    @property
    def is_green(self) -> bool:
        return self.close >= self.open

    def to_dict(self) -> dict:
        return {"t": self.ts, "o": self.open, "h": self.high, "l": self.low, "c": self.close}


def build_candles(ticks: Iterable[Tick], candle_seconds: int) -> List[Candle]:
    """Fasst Ticks zu OHLC-Kerzen zusammen.

    Luecken ohne Ticks werden mit einer flachen Kerze auf dem letzten Schlusskurs
    gefuellt, damit die Zeitachse im Chart gleichmaessig bleibt und Fenster wie
    "letzte 6 Minuten" wirklich 6 Kerzen umfassen.
    """
    if candle_seconds <= 0:
        raise ValueError("candle_seconds muss > 0 sein")
    ordered = sorted(ticks, key=lambda t: t[0])
    candles: List[Candle] = []
    bucket_start: Optional[float] = None
    o = h = l = c = 0.0
    for ts, price in ordered:
        if price is None or not math.isfinite(price) or price <= 0:
            continue
        start = math.floor(ts / candle_seconds) * candle_seconds
        if bucket_start is None:
            bucket_start, o, h, l, c = start, price, price, price, price
            continue
        if start == bucket_start:
            h = max(h, price)
            l = min(l, price)
            c = price
            continue
        candles.append(Candle(bucket_start, o, h, l, c))
        gap = bucket_start + candle_seconds
        while gap < start:
            candles.append(Candle(gap, c, c, c, c))
            gap += candle_seconds
        # Neue Kerze eroeffnet am vorherigen Schluss -> durchgehender Verlauf.
        bucket_start, o, h, l = start, c, max(c, price), min(c, price)
        c = price
    if bucket_start is not None:
        candles.append(Candle(bucket_start, o, h, l, c))
    return candles


class TickStore:
    """Haelt pro Coin die Ticks der letzten ``keep_seconds`` Sekunden."""

    def __init__(self, keep_seconds: int):
        self.keep_seconds = keep_seconds
        self._ticks: Dict[str, List[Tick]] = {}

    def add(self, coin: str, ts: float, price: float) -> None:
        series = self._ticks.setdefault(coin, [])
        if series and ts < series[-1][0]:
            series.append((ts, price))
            series.sort(key=lambda t: t[0])
        else:
            series.append((ts, price))
        cutoff = ts - self.keep_seconds
        while series and series[0][0] < cutoff:
            series.pop(0)

    def extend(self, coin: str, ticks: Iterable[Tick]) -> None:
        for ts, price in ticks:
            self.add(coin, ts, price)

    def ticks(self, coin: str) -> List[Tick]:
        return list(self._ticks.get(coin, []))

    def last_price(self, coin: str) -> Optional[float]:
        series = self._ticks.get(coin)
        return series[-1][1] if series else None

    def coins(self) -> List[str]:
        return list(self._ticks)


class CoinGeckoError(RuntimeError):
    pass


class CoinGeckoClient:
    """Minimaler CoinGecko-Client (nur Standardbibliothek).

    Der API-Key wird je nach Plan als ``x-cg-demo-api-key`` oder
    ``x-cg-pro-api-key`` Header mitgeschickt. Ohne Key funktioniert die
    oeffentliche API mit strengerem Rate-Limit.
    """

    def __init__(self, api_key: str = "", plan: str = "demo", timeout: float = 15.0, opener=None):
        self.api_key = api_key
        self.plan = plan
        self.timeout = timeout
        self.base_url = PRO_BASE_URL if plan == "pro" else DEMO_BASE_URL
        self._open = opener or urllib.request.urlopen

    def headers(self) -> Dict[str, str]:
        h = {"Accept": "application/json", "User-Agent": "GeckoMiningBot/1.0"}
        if self.api_key:
            h["x-cg-pro-api-key" if self.plan == "pro" else "x-cg-demo-api-key"] = self.api_key
        return h

    def _get(self, path: str, params: Dict[str, str]) -> object:
        url = f"{self.base_url}{path}?{urllib.parse.urlencode(params)}"
        req = urllib.request.Request(url, headers=self.headers())
        try:
            with self._open(req, timeout=self.timeout) as resp:
                return json.loads(resp.read().decode("utf-8"))
        except urllib.error.HTTPError as exc:
            if exc.code == 429:
                raise CoinGeckoError("Rate-Limit erreicht (429) - poll_seconds erhoehen oder API-Key setzen") from exc
            if exc.code in (401, 403):
                raise CoinGeckoError(f"API-Key abgelehnt ({exc.code}) - GECKO_API_KEY/GECKO_API_PLAN pruefen") from exc
            raise CoinGeckoError(f"HTTP {exc.code} fuer {path}") from exc
        except urllib.error.URLError as exc:
            raise CoinGeckoError(f"Netzwerkfehler: {exc.reason}") from exc

    def simple_prices(self, coins: Sequence[str], vs_currency: str = "usd") -> Dict[str, float]:
        data = self._get("/simple/price", {"ids": ",".join(coins), "vs_currencies": vs_currency})
        if not isinstance(data, dict):
            raise CoinGeckoError("Unerwartete Antwort von /simple/price")
        out: Dict[str, float] = {}
        for coin in coins:
            value = (data.get(coin) or {}).get(vs_currency)
            if isinstance(value, (int, float)) and value > 0:
                out[coin] = float(value)
        return out

    def recent_ticks(self, coin: str, vs_currency: str = "usd") -> List[Tick]:
        """Kursverlauf der letzten 24h (ca. 5-Minuten-Raster) als Ticks."""
        data = self._get(f"/coins/{urllib.parse.quote(coin)}/market_chart", {"vs_currency": vs_currency, "days": "1"})
        if not isinstance(data, dict) or "prices" not in data:
            raise CoinGeckoError(f"Unerwartete Antwort von /market_chart fuer {coin}")
        return [(ms / 1000.0, float(p)) for ms, p in data["prices"] if p]


class SimulatedFeed:
    """Offline-Kursquelle mit Zufallsbewegung und eingestreuten Pumps/Dumps.

    Wird benutzt, solange kein API-Key gesetzt ist (``--demo``), und in Tests.
    """

    def __init__(self, coins: Sequence[str], seed: int = 7, start_price: float = 100.0,
                 step_seconds: float = 20.0, start_ts: Optional[float] = None):
        self.rng = random.Random(seed)
        # Eigene Uhr: jeder step() rueckt die Zeit vor -> Zeitraffer im Demo-Modus.
        self.ts = time.time() if start_ts is None else start_ts
        self.step_seconds = step_seconds
        self.prices = {c: start_price * (1 + 0.3 * self.rng.random()) for c in coins}
        self._event: Dict[str, Tuple[int, float]] = {}  # coin -> (verbleibende Schritte, Drift)

    def clock(self) -> float:
        return self.ts

    def step(self) -> Dict[str, float]:
        self.ts += self.step_seconds
        for coin, price in self.prices.items():
            remaining, drift = self._event.get(coin, (0, 0.0))
            if remaining <= 0 and self.rng.random() < 0.02:
                remaining = self.rng.randint(4, 12)
                drift = self.rng.choice((1, -1)) * self.rng.uniform(0.004, 0.008)
            noise = self.rng.gauss(0, 0.0015)
            price *= 1 + noise + (drift if remaining > 0 else 0.0)
            self._event[coin] = (remaining - 1, drift)
            self.prices[coin] = max(price, 1e-9)
        return dict(self.prices)

    def history(self, minutes: int) -> Dict[str, List[Tick]]:
        """Erzeugt ``minutes`` Minuten Verlauf, der genau bei der aktuellen Feed-Zeit endet."""
        out: Dict[str, List[Tick]] = {c: [] for c in self.prices}
        end = self.ts
        self.ts = end - minutes * 60
        while self.ts < end:
            for coin, price in self.step().items():
                out[coin].append((self.ts, price))
        return out


def now() -> float:
    return time.time()
