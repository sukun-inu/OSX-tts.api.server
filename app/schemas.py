"""API のリクエスト / レスポンススキーマ (Pydantic モデル)。"""
from __future__ import annotations

from datetime import datetime
from enum import Enum

from pydantic import BaseModel, Field


class AudioFormat(str, Enum):
    """出力音声フォーマット。"""

    aiff = "aiff"
    wav = "wav"
    m4a = "m4a"
    mp3 = "mp3"


class ResponseMode(str, Enum):
    """synthesize の応答モード。"""

    json = "json"  # メタデータ (URL を含む) を返す
    file = "file"  # 音声ファイル本体を返す


class SynthesizeRequest(BaseModel):
    """POST /api/v1/synthesize のリクエストボディ。"""

    text: str = Field(..., min_length=1, description="読み上げるテキスト")
    voice: str | None = Field(
        default=None, description="音声名 (例: Kyoko)。未指定時はサーバー既定値"
    )
    rate: int | None = Field(
        default=None, description="読み上げ速度 (語/分)。未指定時はサーバー既定値"
    )
    format: AudioFormat | None = Field(
        default=None, description="出力フォーマット。未指定時はサーバー既定値"
    )


class SynthesizeResponse(BaseModel):
    """POST /api/v1/synthesize の JSON レスポンス。"""

    id: str = Field(description="音声の一意ID (キャッシュキー)")
    url: str = Field(description="生成された音声ファイルの取得URL")
    format: AudioFormat
    voice: str | None = Field(description="実際に使用した音声名")
    rate: int | None = Field(description="実際に使用した読み上げ速度")
    size_bytes: int = Field(description="音声ファイルのバイトサイズ")
    cached: bool = Field(description="既存のキャッシュを再利用した場合 true")
    created_at: datetime = Field(description="音声ファイルの生成日時 (UTC)")


class Voice(BaseModel):
    """利用可能な音声 1 件。"""

    name: str = Field(description="音声名")
    locale: str = Field(description="ロケール (例: ja_JP)")
    example: str = Field(default="", description="サンプル文")


class HealthResponse(BaseModel):
    """GET /api/v1/health のレスポンス。"""

    status: str = Field(description="ok = 正常 / degraded = say 利用不可")
    say_available: bool = Field(description="say コマンドが利用可能か")
    ffmpeg_available: bool = Field(description="ffmpeg が利用可能か (mp3 出力に必要)")
    audio_count: int = Field(description="現在保存されている音声ファイル数")
    audio_dir: str = Field(description="音声ファイルの保存ディレクトリ")
