"""Provenance-aware cache for named SQL query results."""

from __future__ import annotations

import hashlib
import json
import math
import os
import re
import tempfile
import time
from collections.abc import Mapping, Sequence
from datetime import date, datetime, time as datetime_time, timezone
from decimal import Decimal
from pathlib import Path
from typing import Any, Callable

import pandas as pd
from sqlalchemy import text


class CacheUnavailableError(RuntimeError):
    """Raised when a validated cache entry is required but unavailable."""


def load_queries(path: str | Path) -> dict[str, str]:
    """Load ``-- name: query_name`` sections from a SQL file."""
    body = Path(path).read_text(encoding="utf-8")
    parts = re.split(r"(?m)^--\s*name:\s*(\w+).*?$", body)
    return {
        parts[index]: parts[index + 1].strip()
        for index in range(1, len(parts), 2)
    }


def find_project_root(start: str | Path | None = None) -> Path:
    """Find the project root from either the root or ``notebooks/`` cwd."""
    origin = Path(start or Path.cwd()).resolve()
    for candidate in (origin, *origin.parents):
        if (candidate / "cache_context.json").is_file() and (candidate / "sql").is_dir():
            return candidate
    raise FileNotFoundError(
        f"cache_context.json과 sql/을 포함한 프로젝트 루트를 찾지 못했습니다 (start={origin})"
    )


def _sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as file:
        for chunk in iter(lambda: file.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _normalize(value: Any) -> Any:
    """Return a deterministic JSON-compatible representation for hashing only."""
    if value is None or isinstance(value, (bool, int, str)):
        return value
    if isinstance(value, float):
        if math.isnan(value):
            return {"__float__": "nan"}
        if math.isinf(value):
            return {"__float__": "inf" if value > 0 else "-inf"}
        return {"__float__": value.hex()}
    if isinstance(value, Decimal):
        return {"__decimal__": str(value)}
    if isinstance(value, (datetime, date, datetime_time)):
        return {f"__{type(value).__name__}__": value.isoformat()}
    if isinstance(value, Path):
        return {"__path__": str(value)}
    if isinstance(value, bytes):
        return {"__bytes_sha256__": _sha256_bytes(value)}
    if isinstance(value, Mapping):
        items = [(_normalize(key), _normalize(item)) for key, item in value.items()]
        items.sort(key=lambda pair: _canonical_json(pair[0]))
        return {"__mapping__": items}
    if isinstance(value, (set, frozenset)):
        items = [_normalize(item) for item in value]
        items.sort(key=_canonical_json)
        return {"__set__": items}
    if isinstance(value, Sequence) and not isinstance(value, (str, bytes, bytearray)):
        return {"__sequence__": [_normalize(item) for item in value]}
    if isinstance(value, type):
        return {"__type__": f"{value.__module__}.{value.__qualname__}"}
    item = getattr(value, "item", None)
    if callable(item):
        try:
            return _normalize(item())
        except (TypeError, ValueError):
            pass
    return {
        "__object_type__": f"{type(value).__module__}.{type(value).__qualname__}",
        "__repr__": repr(value),
    }


def _canonical_json(value: Any) -> str:
    return json.dumps(
        _normalize(value),
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    )


def canonical_hash(value: Any) -> str:
    """Hash a deterministic representation without persisting its raw value."""
    return _sha256_bytes(_canonical_json(value).encode("utf-8"))


def dataframe_content_hash(frame: pd.DataFrame) -> str:
    """Return a row-order-independent hash that preserves duplicate row counts."""
    row_hashes = pd.util.hash_pandas_object(
        frame, index=False, categorize=True
    ).to_numpy(dtype="uint64")
    row_hashes.sort()
    return _sha256_bytes(row_hashes.tobytes())


def _frame_schema(frame: pd.DataFrame) -> dict[str, Any]:
    return {
        "row_count": int(len(frame)),
        "columns": [str(column) for column in frame.columns],
        "dtypes": [str(dtype) for dtype in frame.dtypes],
        "content_hash_sort_independent": dataframe_content_hash(frame),
    }


class QueryCache:
    """Run named SQL queries with content-addressed provenance validation."""

    def __init__(
        self,
        *,
        engine: Any,
        sql_file: str | Path,
        upstream_sql_files: Sequence[str | Path],
        cache_dir: str | Path | None = None,
        context_file: str | Path | None = None,
        logger: Callable[[str], None] | None = print,
        read_sql: Callable[..., pd.DataFrame] | None = None,
    ) -> None:
        self.engine = engine
        self.sql_file = Path(sql_file).resolve()
        self.project_root = self.sql_file.parent.parent
        self.context_file = Path(
            context_file or self.project_root / "cache_context.json"
        ).resolve()
        self.context = json.loads(self.context_file.read_text(encoding="utf-8"))
        required_context = {
            "cache_contract_version",
            "dataset",
            "dataset_version",
            "period_start",
            "period_end",
            "raw_event_rows",
        }
        missing_context = sorted(required_context - set(self.context))
        if missing_context:
            raise ValueError(f"cache context 필수 키 없음: {missing_context}")

        override = cache_dir or os.getenv("FUNNEL_CACHE_DIR")
        self.cache_dir = Path(override or self.project_root / "cache").resolve()
        self.queries = load_queries(self.sql_file)
        self.sql_file_sha256 = _sha256_file(self.sql_file)
        self.upstream_sql_sha256 = {
            self._safe_relative(Path(path).resolve()): _sha256_file(Path(path).resolve())
            for path in upstream_sql_files
        }
        self.logger = logger
        self.read_sql = read_sql or pd.read_sql

        url = engine.url
        self.db_dialect = engine.dialect.name
        source_identity = {
            "dialect": self.db_dialect,
            "host": url.host or "",
            "port": url.port,
            "schema": url.database or "",
        }
        self.source_hash = canonical_hash(source_identity)

    def _safe_relative(self, path: Path) -> str:
        try:
            return str(path.relative_to(self.project_root))
        except ValueError:
            return path.name

    def _fingerprint_details(
        self, name: str, read_sql_kwargs: Mapping[str, Any]
    ) -> tuple[str, dict[str, Any]]:
        if name not in self.queries:
            raise KeyError(f"named query 없음: {name}")
        kwargs = dict(read_sql_kwargs)
        params = kwargs.pop("params", None)
        details = {
            "cache_contract_version": self.context["cache_contract_version"],
            "query_name": name,
            "query_sql_sha256": _sha256_bytes(self.queries[name].encode("utf-8")),
            "sql_file_sha256": self.sql_file_sha256,
            "upstream_sql_sha256": self.upstream_sql_sha256,
            "dataset_version": self.context["dataset_version"],
            "parameter_sha256": canonical_hash(params),
            "read_sql_kwargs_sha256": canonical_hash(kwargs),
            "db_dialect": self.db_dialect,
            "source_hash": self.source_hash,
        }
        return canonical_hash(details), details

    def fingerprint(self, name: str, **read_sql_kwargs: Any) -> str:
        """Return the full cache fingerprint for a named query invocation."""
        return self._fingerprint_details(name, read_sql_kwargs)[0]

    def _paths(self, name: str, fingerprint: str) -> tuple[Path, Path]:
        directory = self.cache_dir / self.sql_file.stem / name
        return (
            directory / f"{fingerprint}.parquet",
            directory / f"{fingerprint}.meta.json",
        )

    def _log(self, message: str) -> None:
        if self.logger is not None:
            self.logger(message)

    def _read_validated(
        self,
        name: str,
        fingerprint: str,
        details: Mapping[str, Any],
    ) -> tuple[pd.DataFrame | None, str]:
        parquet_path, metadata_path = self._paths(name, fingerprint)
        if not parquet_path.exists() or not metadata_path.exists():
            legacy_path = self.cache_dir / f"{name}.parquet"
            if legacy_path.exists():
                return None, "provenance 없는 legacy flat cache 무시"
            return None, "cache entry 없음"
        try:
            metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            return None, f"metadata 읽기 실패: {type(error).__name__}"
        if metadata.get("fingerprint") != fingerprint:
            return None, "metadata fingerprint 불일치"
        if metadata.get("fingerprint_components") != dict(details):
            return None, "metadata provenance 불일치"
        try:
            if metadata.get("parquet_sha256") != _sha256_file(parquet_path):
                return None, "parquet content hash 불일치"
            frame = pd.read_parquet(parquet_path)
        except Exception as error:
            return None, f"parquet 읽기 실패: {type(error).__name__}"
        expected_schema = {
            key: metadata.get(key)
            for key in ("row_count", "columns", "dtypes", "content_hash_sort_independent")
        }
        if _frame_schema(frame) != expected_schema:
            return None, "metadata와 DataFrame 무결성 불일치"
        return frame, "validated"

    def read_cached(self, name: str, **read_sql_kwargs: Any) -> pd.DataFrame:
        """Read only a cache entry that matches the current full provenance."""
        fingerprint, details = self._fingerprint_details(name, read_sql_kwargs)
        frame, reason = self._read_validated(name, fingerprint, details)
        if frame is None:
            raise CacheUnavailableError(
                f"[{name}] 검증된 cache 사용 불가 ({fingerprint[:12]}): {reason}"
            )
        self._log(f"[{name}] cache HIT {fingerprint[:12]} · {len(frame):,}행")
        return frame

    def _atomic_write(
        self,
        name: str,
        fingerprint: str,
        details: Mapping[str, Any],
        frame: pd.DataFrame,
    ) -> None:
        parquet_path, metadata_path = self._paths(name, fingerprint)
        parquet_path.parent.mkdir(parents=True, exist_ok=True)
        parquet_fd, parquet_temp_name = tempfile.mkstemp(
            prefix=f".{fingerprint}.", suffix=".tmp.parquet", dir=parquet_path.parent
        )
        metadata_fd, metadata_temp_name = tempfile.mkstemp(
            prefix=f".{fingerprint}.", suffix=".tmp.json", dir=parquet_path.parent
        )
        os.close(parquet_fd)
        os.close(metadata_fd)
        parquet_temp = Path(parquet_temp_name)
        metadata_temp = Path(metadata_temp_name)
        try:
            frame.to_parquet(parquet_temp, index=False)
            metadata = {
                "fingerprint": fingerprint,
                "fingerprint_components": dict(details),
                "sql_file": self._safe_relative(self.sql_file),
                "dataset": self.context["dataset"],
                "period_start": self.context["period_start"],
                "period_end": self.context["period_end"],
                "raw_event_rows": self.context["raw_event_rows"],
                "created_at_utc": datetime.now(timezone.utc).isoformat(),
                "parquet_sha256": _sha256_file(parquet_temp),
                **_frame_schema(frame),
            }
            metadata_temp.write_text(
                json.dumps(metadata, ensure_ascii=False, indent=2, sort_keys=True),
                encoding="utf-8",
            )
            os.replace(parquet_temp, parquet_path)
            os.replace(metadata_temp, metadata_path)
        finally:
            parquet_temp.unlink(missing_ok=True)
            metadata_temp.unlink(missing_ok=True)

    def run(
        self, name: str, refresh: bool = False, **read_sql_kwargs: Any
    ) -> pd.DataFrame:
        """Return a validated hit or execute, cache, and return the current query."""
        fingerprint, details = self._fingerprint_details(name, read_sql_kwargs)
        short = fingerprint[:12]
        if refresh:
            self._log(f"[{name}] cache MISS {short} · refresh=True")
        else:
            frame, reason = self._read_validated(name, fingerprint, details)
            if frame is not None:
                self._log(f"[{name}] cache HIT {short} · {len(frame):,}행")
                return frame
            self._log(f"[{name}] cache MISS {short} · {reason}")

        started = time.monotonic()
        frame = self.read_sql(text(self.queries[name]), self.engine, **read_sql_kwargs)
        elapsed = time.monotonic() - started
        try:
            self._atomic_write(name, fingerprint, details, frame)
            note = "cache SAVED"
        except Exception as error:
            note = f"cache 저장 실패: {type(error).__name__}"
        self._log(
            f"[{name}] query DONE {short} · {elapsed:.1f}s · {len(frame):,}행 · {note}"
        )
        return frame
