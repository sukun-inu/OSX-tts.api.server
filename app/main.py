"""FastAPI アプリケーション本体。エンドポイント定義。"""
from __future__ import annotations

import asyncio
import contextlib
import logging
from datetime import datetime, timezone

from fastapi import BackgroundTasks, FastAPI, HTTPException, Query
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles

from . import __version__, storage, tts
from .config import get_settings
from .schemas import (
    AudioFormat,
    HealthResponse,
    ResponseMode,
    SynthesizeRequest,
    SynthesizeResponse,
    Voice,
)

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
)
logger = logging.getLogger("tts-api")

settings = get_settings()

# 進行中の合成を追跡する dict。同一 audio_id のリクエストが同時に来た場合、
# 後続リクエストは既存の Future を待つだけで say を二重実行しない。
# asyncio はシングルスレッドなので await をまたがない範囲では lock 不要。
_synthesis_in_flight: dict[str, asyncio.Future] = {}

# フォーマットごとの Content-Type
MEDIA_TYPES: dict[str, str] = {
    "aiff": "audio/aiff",
    "wav": "audio/wav",
    "m4a": "audio/mp4",
    "mp3": "audio/mpeg",
}


@contextlib.asynccontextmanager
async def lifespan(app: FastAPI):
    """起動時にクリーンアップタスクを開始し、終了時に停止する。"""
    cleanup_task = asyncio.create_task(storage.cleanup_loop())
    # 外部コマンドの可否を起動時に確定させてキャッシュを温める
    # (shutil.which のブロッキングI/O をリクエスト処理ループから排除する)
    tts.say_available()
    tts.ffmpeg_available()
    # 音声一覧を事前取得してキャッシュを温める (失敗しても起動は継続)
    with contextlib.suppress(Exception):
        await tts.get_voices()
    logger.info("TTS API 起動完了 — 音声保存先: %s", settings.audio_dir)
    try:
        yield
    finally:
        cleanup_task.cancel()
        with contextlib.suppress(asyncio.CancelledError):
            await cleanup_task


app = FastAPI(
    title="OSX TTS API",
    description="macOS の say コマンドを用いた音声合成 API サーバー。",
    version=__version__,
    lifespan=lifespan,
)

# /audio を静的配信としてマウントする (FastAPI が直接ディスクから配信する)。
settings.audio_dir.mkdir(parents=True, exist_ok=True)
app.mount("/audio", StaticFiles(directory=settings.audio_dir), name="audio")


@app.get("/", tags=["meta"])
async def root() -> dict:
    """サーバー情報を返す。"""
    return {
        "name": "OSX TTS API",
        "version": __version__,
        "docs": "/docs",
        "endpoints": [
            "POST /api/v1/synthesize",
            "GET /api/v1/voices",
            "GET /api/v1/health",
        ],
    }


@app.get("/api/v1/health", response_model=HealthResponse, tags=["meta"])
async def health() -> HealthResponse:
    """ヘルスチェック。say / ffmpeg の利用可否を返す。"""
    say_ok = tts.say_available()
    audio_count = await asyncio.to_thread(storage.audio_count)
    return HealthResponse(
        status="ok" if say_ok else "degraded",
        say_available=say_ok,
        ffmpeg_available=tts.ffmpeg_available(),
        audio_count=audio_count,
        audio_dir=str(settings.audio_dir),
    )


@app.get("/api/v1/voices", response_model=list[Voice], tags=["tts"])
async def voices(
    locale: str | None = Query(
        default=None,
        description="ロケールの前方一致フィルタ (例: ja で日本語音声のみ)",
    ),
) -> list[Voice]:
    """利用可能な音声の一覧を返す。"""
    try:
        result = await tts.get_voices()
    except tts.SynthesisError as exc:
        raise HTTPException(status_code=exc.status_code, detail=exc.message)
    if locale:
        needle = locale.lower()
        result = [v for v in result if v.locale.lower().startswith(needle)]
    return result


@app.post("/api/v1/synthesize", response_model=SynthesizeResponse, tags=["tts"])
async def synthesize(
    req: SynthesizeRequest,
    background_tasks: BackgroundTasks,
    mode: ResponseMode = Query(
        default=ResponseMode.json,
        description="json=メタデータ(URL含む)を返す / file=音声ファイル本体を返す",
    ),
):
    """テキストを音声に変換する。

    同一パラメータの再リクエストはキャッシュ済みファイルを返す (cached=true)。
    """
    text = req.text.strip()
    if not text:
        raise HTTPException(status_code=400, detail="text が空です")
    if len(text) > settings.max_text_length:
        raise HTTPException(
            status_code=400,
            detail=f"text が長すぎます (最大 {settings.max_text_length} 文字)",
        )

    # 既定値の解決
    fmt = req.format.value if req.format else settings.default_format
    voice = req.voice or settings.default_voice or None
    rate = req.rate if req.rate is not None else (settings.default_rate or None)

    # 読み上げ速度の範囲チェック
    if rate is not None and not (settings.rate_min <= rate <= settings.rate_max):
        raise HTTPException(
            status_code=400,
            detail=f"rate は {settings.rate_min}〜{settings.rate_max} の範囲で指定してください",
        )

    # 音声名のホワイトリスト検証
    if voice:
        names = await tts.voice_names()
        if names and voice not in names:
            raise HTTPException(
                status_code=400,
                detail=f"voice '{voice}' は利用できません。GET /api/v1/voices を参照してください",
            )

    # mp3 は ffmpeg が必要
    if fmt == "mp3" and not tts.ffmpeg_available():
        raise HTTPException(
            status_code=503,
            detail="mp3 形式の出力には ffmpeg が必要ですが、サーバーに見つかりません",
        )

    audio_id = storage.compute_id(text, voice, rate, fmt)
    path = storage.path_for(audio_id, fmt)
    cached = await asyncio.to_thread(storage.is_fresh, path)

    if not cached:
        if audio_id in _synthesis_in_flight:
            # 同一パラメータの合成がすでに進行中 — 完了を待つだけで say を再実行しない
            try:
                await _synthesis_in_flight[audio_id]
            except tts.SynthesisError as exc:
                raise HTTPException(status_code=exc.status_code, detail=exc.message)
        else:
            fut: asyncio.Future = asyncio.get_running_loop().create_future()
            _synthesis_in_flight[audio_id] = fut
            try:
                await tts.synthesize(text, voice, rate, fmt, path)
                fut.set_result(None)
            except tts.SynthesisError as exc:
                fut.set_exception(exc)
                raise HTTPException(status_code=exc.status_code, detail=exc.message)
            finally:
                _synthesis_in_flight.pop(audio_id, None)

    stat = await asyncio.to_thread(path.stat)

    if mode is ResponseMode.file:
        # 送信完了後に post_serve_delete_delay 秒の猶予を置いて削除する。
        # BackgroundTask は FastAPI がレスポンス送信を終えた後に実行される。
        background_tasks.add_task(storage.delete_after_serve, path)
        return FileResponse(
            path,
            media_type=MEDIA_TYPES.get(fmt, "application/octet-stream"),
            filename=f"{audio_id}.{fmt}",
            stat_result=stat,
        )

    return SynthesizeResponse(
        id=audio_id,
        url=storage.public_url(audio_id, fmt),
        format=AudioFormat(fmt),
        voice=voice,
        rate=rate,
        size_bytes=stat.st_size,
        cached=cached,
        created_at=datetime.fromtimestamp(stat.st_mtime, tz=timezone.utc),
    )


if __name__ == "__main__":
    import uvicorn

    # workers > 1 の場合は文字列参照が必要 (multiprocessing でプロセスを fork するため)
    app_ref = "app.main:app" if settings.workers > 1 else app
    uvicorn.run(app_ref, host=settings.host, port=settings.port, workers=settings.workers)
