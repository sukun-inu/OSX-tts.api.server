"""音声ファイルの保存・キャッシュ・期限切れ削除。"""
from __future__ import annotations

import asyncio
import hashlib
import logging
import time
from pathlib import Path

from .config import get_settings

logger = logging.getLogger(__name__)

# キャッシュキー生成時のフィールド区切り文字 (テキストに出現しない制御文字)
_FIELD_SEP = "\x1f"


def compute_id(text: str, voice: str | None, rate: int | None, fmt: str) -> str:
    """生成パラメータから決定的なIDを計算する。

    同一パラメータ → 同一ID となり、これがキャッシュキーを兼ねる。
    """
    raw = _FIELD_SEP.join(
        [text, voice or "", str(rate) if rate is not None else "", fmt]
    )
    return hashlib.sha256(raw.encode("utf-8")).hexdigest()[:24]


def path_for(audio_id: str, fmt: str) -> Path:
    """音声IDとフォーマットからファイルパスを求める。"""
    return get_settings().audio_dir / f"{audio_id}.{fmt}"


def is_fresh(path: Path) -> bool:
    """ファイルが存在し、かつ TTL 内であれば True。

    同期I/O。非同期コンテキストからは asyncio.to_thread 経由で呼ぶこと。
    """
    if not path.is_file():
        return False
    age = time.time() - path.stat().st_mtime
    return age < get_settings().audio_ttl_seconds


def public_url(audio_id: str, fmt: str) -> str:
    """クライアントへ返す音声ファイルの取得URL。

    public_base_url が設定されていれば絶対URL、未設定なら相対パスを返す。
    """
    rel = f"/audio/{audio_id}.{fmt}"
    base = get_settings().public_base_url.rstrip("/")
    return f"{base}{rel}" if base else rel


def audio_count() -> int:
    """保存済みの音声ファイル数 (一時ファイルを除く)。

    同期I/O。非同期コンテキストからは asyncio.to_thread 経由で呼ぶこと。
    """
    audio_dir = get_settings().audio_dir
    if not audio_dir.is_dir():
        return 0
    return sum(
        1
        for f in audio_dir.iterdir()
        if f.is_file() and not f.name.startswith(".")
    )


def purge_expired() -> int:
    """TTL を超過したファイルを削除し、削除件数を返す。

    生成途中の一時ファイル (.tmp-*) は mtime が新しいため削除対象にならない。
    過去に異常終了して残った一時ファイルは TTL 経過後に削除される。
    同期I/O。非同期コンテキストからは asyncio.to_thread 経由で呼ぶこと。
    """
    settings = get_settings()
    audio_dir = settings.audio_dir
    if not audio_dir.is_dir():
        return 0
    cutoff = time.time() - settings.audio_ttl_seconds
    removed = 0
    for f in audio_dir.iterdir():
        try:
            if f.is_file() and f.stat().st_mtime < cutoff:
                f.unlink()
                removed += 1
        except FileNotFoundError:
            continue
    return removed


async def cleanup_loop() -> None:
    """期限切れファイルを定期的に削除するバックグラウンドタスク。"""
    interval = get_settings().cleanup_interval_seconds
    while True:
        await asyncio.sleep(interval)
        try:
            # ディレクトリ走査はブロッキングI/O のためスレッドプールへ退避する
            removed = await asyncio.to_thread(purge_expired)
            if removed:
                logger.info("期限切れの音声ファイルを %d 件削除しました", removed)
        except Exception:  # noqa: BLE001 - バックグラウンドタスクは止めない
            logger.exception("クリーンアップ処理でエラーが発生しました")
