"""macOS ``say`` コマンドによる音声合成と音声一覧の取得。

セキュリティ上の注意:
- すべての外部コマンドは ``create_subprocess_exec`` で実行し、シェルを介さない。
- 読み上げテキストはコマンド引数ではなく一時ファイル経由 (``say -f``) で渡し、
  引数解釈やコマンドインジェクションのリスクを排除する。
"""
from __future__ import annotations

import asyncio
import contextlib
import logging
import os
import shutil
import tempfile
from functools import cache
from pathlib import Path

from .config import get_settings
from .schemas import Voice

logger = logging.getLogger(__name__)

# 同時に実行する say / ffmpeg プロセス数を制限するセマフォ
_semaphore = asyncio.Semaphore(get_settings().max_concurrent_synthesis)

# 音声一覧のキャッシュ (say -v '?' の結果はほぼ不変)
_voices_cache: list[Voice] | None = None
_voices_lock = asyncio.Lock()


class SynthesisError(Exception):
    """音声合成中のエラー。対応する HTTP ステータスコードを保持する。"""

    def __init__(self, message: str, status_code: int = 500) -> None:
        super().__init__(message)
        self.message = message
        self.status_code = status_code


@cache
def say_available() -> bool:
    """say コマンドが利用可能か (= macOS 上で動作しているか)。"""
    return Path("/usr/bin/say").is_file()


def _say_cmd() -> list[str]:
    """say コマンドを適切なコンテキストで実行するコマンドリストを返す。

    TTS_SAY_USER_UID が設定されている場合 (root LaunchDaemon):
      launchctl asuser UID /usr/bin/say
      → root から対象ユーザーの bootstrap namespace に委譲し、
        ユーザーセッションの音声エンジンにアクセスする。
    未設定の場合 (開発時 / LaunchAgent):
      /usr/bin/say を直接呼ぶ (既にユーザーセッション内)。
    """
    uid = os.environ.get("TTS_SAY_USER_UID", "").strip()
    if uid:
        return ["/bin/launchctl", "asuser", uid, "/usr/bin/say"]
    return ["/usr/bin/say"]


@cache
def ffmpeg_available() -> bool:
    """ffmpeg が利用可能か (mp3 出力に必要)。結果はキャッシュする。"""
    return shutil.which(get_settings().ffmpeg_path) is not None


def _write_temp_text(text: str) -> str:
    """読み上げテキストを一時ファイルへ書き出し、そのパスを返す (同期I/O)。"""
    fd, path = tempfile.mkstemp(prefix="tts-input-", suffix=".txt")
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(text)
    return path


def _cleanup_temps(*paths: Path | None) -> None:
    """一時ファイルをまとめて削除する (同期I/O、エラーは無視)。"""
    for path in paths:
        if path is not None:
            with contextlib.suppress(OSError):
                path.unlink(missing_ok=True)


async def _run_say(text: str, voice: str | None, rate: int | None, out_path: Path) -> None:
    """テキストを say に渡し out_path へ音声を書き出す。

    出力フォーマットは out_path の拡張子 (.aiff / .wav / .m4a) で決まる。
    """
    if not say_available():
        raise SynthesisError("say コマンドが見つかりません (macOS 上でのみ動作します)", 503)

    settings = get_settings()
    # テキストは引数ではなく一時ファイル経由で渡す (インジェクション対策)。
    # ファイル書き込みはブロッキングI/O のためスレッドプールへ退避する。
    text_path = await asyncio.to_thread(_write_temp_text, text)
    try:
        args = _say_cmd() + ["-f", text_path, "-o", str(out_path)]
        if voice:
            args += ["-v", voice]
        if rate:
            args += ["-r", str(rate)]

        async with _semaphore:
            proc = await asyncio.create_subprocess_exec(
                *args,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )
            try:
                _, stderr = await asyncio.wait_for(
                    proc.communicate(), timeout=settings.synthesis_timeout_seconds
                )
            except asyncio.TimeoutError:
                proc.kill()
                await proc.wait()
                raise SynthesisError("音声生成がタイムアウトしました", 504)

        if proc.returncode != 0:
            detail = stderr.decode("utf-8", "replace").strip() or "不明なエラー"
            raise SynthesisError(f"say コマンドが失敗しました: {detail}", 500)

        # say が exit 0 でも空ファイルを出力する場合がある (音声セッション未確立など)
        try:
            if out_path.stat().st_size == 0:
                with contextlib.suppress(OSError):
                    out_path.unlink(missing_ok=True)
                raise SynthesisError(
                    "say が空の出力ファイルを生成しました。"
                    "音声セッションへのアクセスに失敗している可能性があります"
                    " (TTS_SAY_USER_UID の設定を確認してください)",
                    500,
                )
        except FileNotFoundError:
            raise SynthesisError("say が出力ファイルを生成しませんでした", 500)
    finally:
        with contextlib.suppress(OSError):
            await asyncio.to_thread(os.unlink, text_path)


async def _run_ffmpeg(src: Path, dst: Path) -> None:
    """ffmpeg で src を mp3 (dst) に変換する。"""
    settings = get_settings()
    if not ffmpeg_available():
        raise SynthesisError("mp3 出力には ffmpeg が必要ですが見つかりません", 503)

    args = [
        settings.ffmpeg_path,
        "-y",
        "-hide_banner",
        "-loglevel", "error",
        "-i", str(src),
        "-codec:a", "libmp3lame",
        "-qscale:a", "4",
        "-ac", "1",
        str(dst),
    ]
    async with _semaphore:
        proc = await asyncio.create_subprocess_exec(
            *args,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        try:
            _, stderr = await asyncio.wait_for(
                proc.communicate(), timeout=settings.synthesis_timeout_seconds
            )
        except asyncio.TimeoutError:
            proc.kill()
            await proc.wait()
            raise SynthesisError("mp3 変換がタイムアウトしました", 504)

    if proc.returncode != 0:
        detail = stderr.decode("utf-8", "replace").strip() or "不明なエラー"
        raise SynthesisError(f"ffmpeg 変換に失敗しました: {detail}", 500)


async def synthesize(
    text: str, voice: str | None, rate: int | None, fmt: str, out_path: Path
) -> None:
    """音声を生成し out_path へ原子的に書き出す。

    一時ファイルへ書き出してから os.replace でリネームすることで、
    生成途中の不完全なファイルが配信されることを防ぐ。
    ブロッキングなファイル操作はスレッドプールへ退避する。
    """
    await asyncio.to_thread(out_path.parent.mkdir, parents=True, exist_ok=True)
    # mp3 は say で直接生成できないため、一旦 aiff を作って ffmpeg で変換する
    say_suffix = "aiff" if fmt == "mp3" else fmt
    tmp_say = out_path.parent / f".tmp-{os.urandom(8).hex()}.{say_suffix}"
    tmp_mp3: Path | None = None
    try:
        await _run_say(text, voice, rate, tmp_say)
        if fmt == "mp3":
            tmp_mp3 = out_path.parent / f".tmp-{os.urandom(8).hex()}.mp3"
            await _run_ffmpeg(tmp_say, tmp_mp3)
            await asyncio.to_thread(os.replace, tmp_mp3, out_path)
            tmp_mp3 = None
        else:
            await asyncio.to_thread(os.replace, tmp_say, out_path)
    finally:
        await asyncio.to_thread(_cleanup_temps, tmp_say, tmp_mp3)


def _parse_voices(output: str) -> list[Voice]:
    """``say -v '?'`` の出力をパースする。

    出力例 (音声名にはスペースを含みうる。ロケールは常に ``#`` 直前の最終トークン):
        Kyoko               ja_JP    # こんにちは、私の名前はKyokoです。
    """
    voices: list[Voice] = []
    for line in output.splitlines():
        line = line.rstrip()
        if not line:
            continue
        head, _, example = line.partition("#")
        parts = head.split()
        if len(parts) < 2:
            continue
        locale = parts[-1]
        name = " ".join(parts[:-1])
        voices.append(Voice(name=name, locale=locale, example=example.strip()))
    return voices


async def get_voices(force: bool = False) -> list[Voice]:
    """利用可能な音声の一覧を返す (結果はプロセス内でキャッシュ)。"""
    global _voices_cache
    if _voices_cache is not None and not force:
        return _voices_cache

    async with _voices_lock:
        if _voices_cache is not None and not force:
            return _voices_cache
        if not say_available():
            raise SynthesisError(
                "say コマンドが見つかりません (macOS 上でのみ動作します)", 503
            )
        proc = await asyncio.create_subprocess_exec(
            *_say_cmd(), "-v", "?",
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        try:
            stdout, stderr = await asyncio.wait_for(proc.communicate(), timeout=10)
        except asyncio.TimeoutError:
            proc.kill()
            await proc.wait()
            raise SynthesisError("音声一覧の取得がタイムアウトしました", 504)

        if proc.returncode != 0:
            detail = stderr.decode("utf-8", "replace").strip() or "不明なエラー"
            raise SynthesisError(f"音声一覧の取得に失敗しました: {detail}", 500)

        _voices_cache = _parse_voices(stdout.decode("utf-8", "replace"))
        logger.info("音声一覧を取得しました (%d 件)", len(_voices_cache))
        return _voices_cache


async def voice_names() -> set[str]:
    """音声名の集合を返す (リクエスト検証用)。取得失敗時は空集合。"""
    try:
        return {v.name for v in await get_voices()}
    except SynthesisError:
        return set()
