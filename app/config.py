"""アプリケーション設定。

環境変数 (接頭辞 ``TTS_``) および ``.env`` ファイルから読み込む。
"""
from __future__ import annotations

from functools import lru_cache
from pathlib import Path

from pydantic import field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict

# サポートする音声フォーマット
ALLOWED_FORMATS: tuple[str, ...] = ("aiff", "wav", "m4a", "mp3")


class Settings(BaseSettings):
    """環境変数から構築されるアプリ設定。"""

    model_config = SettingsConfigDict(
        env_prefix="TTS_",
        env_file=".env",
        env_file_encoding="utf-8",
        extra="ignore",
    )

    # --- サーバー ---
    host: str = "127.0.0.1"
    port: int = 8000

    # --- 音声ファイル ---
    # nginx の alias と一致させる共有ディレクトリ
    audio_dir: Path = Path("audio")
    # レスポンス url の絶対プレフィックス。空なら相対パスを返す
    public_base_url: str = ""

    # --- 音声生成の既定値 ---
    default_voice: str = ""  # 空 = say のシステム既定音声
    default_rate: int = 0  # 0 = say の既定速度
    default_format: str = "m4a"

    # --- 入力制限 ---
    max_text_length: int = 2000
    rate_min: int = 100
    rate_max: int = 400

    # --- キャッシュ・クリーンアップ ---
    audio_ttl_seconds: int = 3600
    cleanup_interval_seconds: int = 600

    # --- 同時実行・タイムアウト ---
    max_concurrent_synthesis: int = 4
    synthesis_timeout_seconds: int = 30

    # --- 外部コマンド ---
    ffmpeg_path: str = "ffmpeg"

    @field_validator("audio_dir")
    @classmethod
    def _resolve_audio_dir(cls, v: Path) -> Path:
        """音声ディレクトリを絶対パスへ解決する (nginx alias と一致させるため)。"""
        return v.expanduser().resolve()

    @field_validator("default_format")
    @classmethod
    def _check_default_format(cls, v: str) -> str:
        v = v.lower()
        if v not in ALLOWED_FORMATS:
            raise ValueError(f"default_format は {ALLOWED_FORMATS} のいずれかを指定してください")
        return v


@lru_cache
def get_settings() -> Settings:
    """設定インスタンスを取得する (プロセス内でキャッシュ)。"""
    return Settings()
