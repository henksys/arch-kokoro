#!/usr/bin/env python3
"""OpenAI-compatible text-to-speech server for the Kokoro-82M model.

The server is deliberately small and CPU-only:

* Kokoro runs through ONNX Runtime, never PyTorch or CUDA.
* The model is loaded once and kept in memory.
* Requests are serialised with a single lock, which is the right trade-off for
  a local single-user service.
* The HTTP surface follows OpenAI's ``POST /v1/audio/speech`` contract, so the
  official OpenAI SDKs and other OpenAI-compatible clients can use it.

The module is intentionally a single file so the installer can copy and run it
without building a Python package.
"""

from __future__ import annotations

import asyncio
import base64
import hmac
import io
import json
import logging
import os
import shutil
import subprocess
import time
import wave
from contextlib import asynccontextmanager
from dataclasses import dataclass
from pathlib import Path
from typing import Any, AsyncIterator, Literal

import numpy as np
import onnxruntime as ort
from fastapi import APIRouter, Depends, FastAPI, Header
from fastapi.exceptions import RequestValidationError
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse, Response, StreamingResponse
from kokoro_onnx import Kokoro
from pydantic import BaseModel, ConfigDict, Field
from starlette.exceptions import HTTPException as StarletteHTTPException

# Kokoro always produces 24 kHz mono audio.
SAMPLE_RATE = 24000

# Read an environment variable and strip surrounding whitespace.
def _env(name: str, default: str) -> str:
    return os.environ.get(name, default).strip()

# Read an integer environment variable, falling back to a safe default.
def _env_int(name: str, default: int) -> int:
    try:
        return int(_env(name, str(default)))
    except ValueError:
        return default

# Directory where the model, voices, and virtual environment live.
RUNTIME_DIR = Path(
    _env("KOKORO_RUNTIME_DIR", str(Path.home() / ".local" / "share" / "kokoro-tts"))
)

# ONNX model file. The installer defaults to the int8 model for the smallest
# footprint; switching to fp32 only requires changing this environment value.
MODEL_PATH = Path(
    _env(
        "KOKORO_MODEL_PATH",
        str(RUNTIME_DIR / "models" / "kokoro-v1.0.int8.onnx"),
    )
)

# Voice-pack file that contains all 54 voices.
VOICES_PATH = Path(
    _env(
        "KOKORO_VOICES_PATH",
        str(RUNTIME_DIR / "models" / "voices-v1.0.bin"),
    )
)

# Network listener. The default is loopback-only on purpose.
HOST = _env("KOKORO_HOST", "127.0.0.1")
PORT = _env_int("KOKORO_PORT", 8880)

# Voice used by the CLI and by requests that omit a voice (normally the OpenAI
# API requires one, but a default is convenient locally).
DEFAULT_VOICE = _env("KOKORO_DEFAULT_VOICE", "af_sky")

# Optional bearer token. An empty value disables authentication.
API_KEY = _env("KOKORO_API_KEY", "")

# ONNX Runtime CPU threads. Four is a good balance on both laptops and desktops.
THREADS = max(1, _env_int("KOKORO_THREADS", min(4, os.cpu_count() or 4)))

# Comma-separated CORS origins. Empty means CORS is disabled; the Node agent
# normally talks to the server directly and does not need CORS.
CORS_ORIGINS = _env("KOKORO_CORS_ORIGINS", "")

# Logging verbosity for the server itself.
LOG_LEVEL = _env("KOKORO_LOG_LEVEL", "info").upper()

# ffmpeg is used for MP3/Opus/AAC/FLAC encoding and for extreme speed changes.
FFMPEG = shutil.which(_env("KOKORO_FFMPEG", "ffmpeg"))

# Models accepted by the endpoint. Everything maps to the same local Kokoro
# model, but accepting OpenAI's names keeps existing clients working.
MODEL_ALIASES = frozenset(
    {
        "kokoro",
        "tts-1",
        "tts-1-hd",
        "gpt-4o-mini-tts",
        "gpt-4o-mini-tts-2025-12-15",
    }
)

# Kokoro voice prefixes map to BCP-47-ish language codes used by espeak-ng.
VOICE_LANGUAGES: dict[str, str] = {
    "a": "en-us",
    "b": "en-gb",
    "e": "es",
    "f": "fr-fr",
    "h": "hi",
    "i": "it",
    "j": "ja",
    "p": "pt-br",
    "z": "zh",
}

# OpenAI's standard voice names mapped to close Kokoro equivalents. Native
# Kokoro names such as af_sky always take priority over this table.
OPENAI_VOICE_MAP: dict[str, str] = {
    "alloy": "af_alloy",
    "ash": "am_adam",
    "ballad": "bm_george",
    "coral": "af_heart",
    "echo": "am_echo",
    "fable": "bm_fable",
    "onyx": "am_onyx",
    "nova": "af_nova",
    "sage": "af_sarah",
    "shimmer": "af_sky",
    "verse": "am_michael",
    "marin": "af_heart",
    "cedar": "am_michael",
}

# Media type returned for each OpenAI response format.
MEDIA_TYPES: dict[str, str] = {
    "mp3": "audio/mpeg",
    "opus": "audio/ogg",
    "aac": "audio/aac",
    "flac": "audio/flac",
    "wav": "audio/wav",
    "pcm": "audio/pcm",
}

# Logger for application-level messages.
logger = logging.getLogger("kokoro_tts")

# Phonemizer warns about punctuation-only word-count mismatches on every short
# utterance. Those warnings are harmless for TTS, so keep the journal quiet.
logging.getLogger("phonemizer").setLevel(logging.ERROR)


@dataclass(frozen=True)
class ModelState:
    """Everything the request handlers need after startup."""

    kokoro: Kokoro
    voices: list[str]
    voice_set: frozenset[str]
    sample_rate: int
    load_seconds: float
    model_path: str
    threads: int


# The loaded model is process-global because there is exactly one worker.
state: ModelState | None = None

# One lock means one synthesis at a time. This keeps CPU usage predictable and
# avoids loading multiple copies of the model.
model_lock = asyncio.Lock()


class VoiceRef(BaseModel):
    """OpenAI allows a voice object with an ``id`` field."""

    model_config = ConfigDict(extra="ignore")

    id: str


class SpeechRequest(BaseModel):
    """Request body for ``POST /v1/audio/speech``.

    Unknown fields are ignored so newer OpenAI SDKs can add parameters without
    breaking this local server.
    """

    model_config = ConfigDict(extra="ignore")

    model: str = Field(min_length=1)
    input: str = Field(min_length=1, max_length=4096)
    voice: str | VoiceRef
    instructions: str | None = Field(default=None, max_length=4096)
    response_format: Literal["mp3", "opus", "aac", "flac", "wav", "pcm"] = "mp3"
    speed: float = Field(default=1.0, ge=0.25, le=4.0)
    stream_format: Literal["audio", "sse"] | None = None
    # ``stream`` is not part of OpenAI's speech API, but some compatible clients
    # send it. It is accepted for compatibility and treated as "audio".
    stream: bool | None = None


def _openai_error(
    status_code: int,
    message: str,
    *,
    error_type: str = "invalid_request_error",
    param: str | None = None,
    code: str | None = None,
    headers: dict[str, str] | None = None,
) -> JSONResponse:
    """Build an OpenAI-shaped error response."""

    return JSONResponse(
        status_code=status_code,
        content={
            "error": {
                "message": message,
                "type": error_type,
                "param": param,
                "code": code,
            }
        },
        headers=headers,
    )


async def require_api_key(authorization: str | None = Header(default=None)) -> None:
    """Enforce the optional bearer token for all ``/v1`` routes."""

    # No configured key means local, unauthenticated access is allowed.
    if not API_KEY:
        return

    # The header must be present and must use the Bearer scheme.
    if not authorization or not authorization.lower().startswith("bearer "):
        raise StarletteHTTPException(
            status_code=401,
            detail={
                "message": "Missing bearer token.",
                "type": "invalid_request_error",
                "param": None,
                "code": "invalid_api_key",
            },
            headers={"WWW-Authenticate": "Bearer"},
        )

    # Compare in constant time to avoid leaking the key through timing.
    token = authorization[7:].strip()
    if not hmac.compare_digest(token, API_KEY):
        raise StarletteHTTPException(
            status_code=401,
            detail={
                "message": "Incorrect API key provided.",
                "type": "invalid_request_error",
                "param": None,
                "code": "invalid_api_key",
            },
            headers={"WWW-Authenticate": "Bearer"},
        )


def _voice_language(voice: str) -> str:
    """Return the espeak language code implied by a Kokoro voice name."""

    return VOICE_LANGUAGES.get(voice[:1], "en-us")


def _voice_metadata(voice: str) -> dict[str, str]:
    """Return public metadata for one voice."""

    # Kokoro names are two-letter prefixes such as af_ or bm_.
    gender = "unknown"
    if len(voice) >= 2 and voice[1] == "f":
        gender = "female"
    elif len(voice) >= 2 and voice[1] == "m":
        gender = "male"

    return {
        "id": voice,
        "name": voice,
        "language": _voice_language(voice),
        "gender": gender,
    }


def _resolve_voice(voice: str | VoiceRef) -> str:
    """Resolve a voice name or OpenAI-style voice object to a Kokoro name."""

    name = voice.id if isinstance(voice, VoiceRef) else voice
    name = name.strip()

    # Native Kokoro names are the preferred path.
    if state is not None and name in state.voice_set:
        return name

    # Fall back to OpenAI's names for drop-in compatibility.
    mapped = OPENAI_VOICE_MAP.get(name.lower())
    if mapped and state is not None and mapped in state.voice_set:
        return mapped

    # Build a short, useful error message instead of dumping all 54 voices.
    sample = ", ".join((state.voices if state else [])[:12])
    raise StarletteHTTPException(
        status_code=400,
        detail={
            "message": (
                f"Voice '{name}' is not supported. Use a Kokoro voice such as "
                f"af_sky. Examples: {sample}"
            ),
            "type": "invalid_request_error",
            "param": "voice",
            "code": "voice_not_found",
        },
    )


def _load_model() -> ModelState:
    """Load the ONNX model and warm it up once."""

    if not MODEL_PATH.is_file():
        raise FileNotFoundError(f"Kokoro model not found: {MODEL_PATH}")

    if not VOICES_PATH.is_file():
        raise FileNotFoundError(f"Kokoro voices file not found: {VOICES_PATH}")

    started = time.perf_counter()

    # Configure ONNX Runtime for CPU-only inference with a bounded thread pool.
    options = ort.SessionOptions()
    options.intra_op_num_threads = THREADS
    options.inter_op_num_threads = 1
    options.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_ALL
    options.log_severity_level = 3

    # Create the session explicitly so the thread count is under our control.
    session = ort.InferenceSession(
        str(MODEL_PATH),
        sess_options=options,
        providers=["CPUExecutionProvider"],
    )

    # kokoro-onnx 0.6.1 reads this private attribute in Kokoro.from_session().
    # Setting it explicitly keeps the version pinned by the lockfile working.
    session._model_path = str(MODEL_PATH)  # type: ignore[attr-defined]

    try:
        kokoro = Kokoro.from_session(session, str(VOICES_PATH))
    except Exception:
        # This fallback is intentionally defensive. It only runs if a future
        # kokoro-onnx release changes the private attribute above.
        logger.exception("Kokoro.from_session failed; retrying with Kokoro()")
        kokoro = Kokoro(str(MODEL_PATH), str(VOICES_PATH))

    voices = sorted(kokoro.get_voices())
    voice_set = frozenset(voices)

    # Resolve the configured default, falling back to af_sky and then the first
    # available voice if a user removes the configured voice in the future.
    warmup_voice = DEFAULT_VOICE
    if warmup_voice not in voice_set:
        warmup_voice = "af_sky" if "af_sky" in voice_set else voices[0]
        logger.warning(
            "Configured default voice %r is unavailable; using %r",
            DEFAULT_VOICE,
            warmup_voice,
        )

    # A short warmup pays the first-inference cost before the service is marked
    # ready, so the first real agent request is not unexpectedly slow.
    kokoro.create(
        "Hello.",
        voice=warmup_voice,
        speed=1.0,
        lang=_voice_language(warmup_voice),
    )

    elapsed = time.perf_counter() - started
    return ModelState(
        kokoro=kokoro,
        voices=voices,
        voice_set=voice_set,
        sample_rate=SAMPLE_RATE,
        load_seconds=elapsed,
        model_path=str(MODEL_PATH),
        threads=THREADS,
    )


@asynccontextmanager
async def lifespan(_app: FastAPI) -> AsyncIterator[None]:
    """Load the model before accepting requests and release it on shutdown."""

    global state

    logger.info("Loading Kokoro model from %s", MODEL_PATH)
    state = await asyncio.to_thread(_load_model)
    logger.info(
        "Kokoro ready: %d voices, %d threads, %.2fs startup",
        len(state.voices),
        state.threads,
        state.load_seconds,
    )

    try:
        yield
    finally:
        state = None
        logger.info("Kokoro stopped")


# Create the FastAPI application with the model lifespan hook.
app = FastAPI(
    title="Kokoro TTS API",
    description="Local CPU-only Kokoro text-to-speech with an OpenAI-compatible API.",
    version="1.0.0",
    lifespan=lifespan,
)


@app.exception_handler(StarletteHTTPException)
async def _http_exception_handler(
    _request: Any, exc: StarletteHTTPException
) -> JSONResponse:
    """Convert HTTP exceptions to OpenAI's error envelope."""

    detail = exc.detail
    if isinstance(detail, dict) and "message" in detail:
        return _openai_error(
            exc.status_code,
            str(detail["message"]),
            error_type=str(detail.get("type", "invalid_request_error")),
            param=detail.get("param"),
            code=detail.get("code"),
            headers=exc.headers,
        )

    return _openai_error(
        exc.status_code,
        str(detail),
        headers=exc.headers,
    )


@app.exception_handler(RequestValidationError)
async def _validation_exception_handler(
    _request: Any, exc: RequestValidationError
) -> JSONResponse:
    """Convert Pydantic validation failures to OpenAI-shaped 400 errors."""

    errors = exc.errors()
    first = errors[0] if errors else {}
    location = ".".join(
        str(part) for part in first.get("loc", ()) if part not in {"body"}
    )
    message = str(first.get("msg", "Invalid request"))

    return _openai_error(
        400,
        f"{location}: {message}" if location else message,
        param=location or None,
    )


@app.exception_handler(Exception)
async def _unhandled_exception_handler(_request: Any, exc: Exception) -> JSONResponse:
    """Return a clean JSON error instead of an HTML traceback."""

    logger.exception("Unhandled server error: %s", exc)
    return _openai_error(
        500,
        "Internal server error.",
        error_type="server_error",
    )


# Optional CORS is useful if the agent is a browser UI. It is off by default.
if CORS_ORIGINS:
    app.add_middleware(
        CORSMiddleware,
        allow_origins=[origin.strip() for origin in CORS_ORIGINS.split(",") if origin.strip()],
        allow_methods=["GET", "POST", "OPTIONS"],
        allow_headers=["*"],
    )

# All /v1 routes share the optional API-key dependency.
router = APIRouter(prefix="/v1", dependencies=[Depends(require_api_key)])


@app.get("/")
async def root() -> dict[str, Any]:
    """Small landing response that makes the service easy to identify."""

    return {
        "name": "Kokoro TTS",
        "api": "/v1",
        "docs": "/docs",
        "health": "/health",
    }


@app.get("/health")
async def health() -> JSONResponse:
    """Health check used by the installer, systemd, and monitoring."""

    if state is None:
        return JSONResponse(status_code=503, content={"status": "starting"})

    return JSONResponse(
        status_code=200,
        content={
            "status": "ok",
            "model": "kokoro",
            "model_file": Path(state.model_path).name,
            "voices": len(state.voices),
            "sample_rate": state.sample_rate,
            "threads": state.threads,
            "startup_seconds": round(state.load_seconds, 3),
        },
    )


@router.get("/models")
async def list_models() -> dict[str, Any]:
    """Return an OpenAI-style model list."""

    return {
        "object": "list",
        "data": [
            {
                "id": "kokoro",
                "object": "model",
                "created": 0,
                "owned_by": "local",
            }
        ],
    }


@router.get("/audio/voices")
async def list_voices() -> dict[str, Any]:
    """List every voice in the downloaded Kokoro voice pack."""

    assert state is not None
    return {"voices": [_voice_metadata(voice) for voice in state.voices]}


def _to_pcm16(audio: np.ndarray) -> bytes:
    """Convert Kokoro's float32 samples to signed 16-bit little-endian PCM."""

    samples = np.asarray(audio, dtype=np.float32)
    samples = np.clip(samples, -1.0, 1.0)
    return (samples * 32767.0).astype("<i2").tobytes()


def _native_speed(speed: float) -> tuple[float, float]:
    """Map OpenAI's 0.25-4.0 speed range onto Kokoro's native 0.5-2.0 range.

    Returns the speed to pass to Kokoro and a playback-rate factor for ffmpeg.
    """

    if speed < 0.5:
        return 0.5, speed / 0.5
    if speed > 2.0:
        return 2.0, speed / 2.0
    return speed, 1.0


def _ffmpeg_run(args: list[str], payload: bytes) -> bytes:
    """Run ffmpeg with bytes on stdin and return bytes from stdout."""

    if FFMPEG is None:
        raise RuntimeError(
            "ffmpeg is required for this response format but was not found in PATH"
        )

    process = subprocess.run(
        [FFMPEG, "-hide_banner", "-loglevel", "error", *args],
        input=payload,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=120,
        check=False,
    )

    if process.returncode != 0:
        error = process.stderr.decode("utf-8", errors="replace").strip()
        raise RuntimeError(error or "ffmpeg failed")

    return process.stdout


def _stretch_pcm(pcm: bytes, factor: float) -> bytes:
    """Change playback speed without changing pitch using ffmpeg's atempo."""

    if abs(factor - 1.0) < 1e-9:
        return pcm

    return _ffmpeg_run(
        [
            "-f",
            "s16le",
            "-ar",
            str(SAMPLE_RATE),
            "-ac",
            "1",
            "-i",
            "pipe:0",
            "-filter:a",
            f"atempo={factor:.6f}",
            "-f",
            "s16le",
            "-ar",
            str(SAMPLE_RATE),
            "-ac",
            "1",
            "pipe:1",
        ],
        pcm,
    )


def _encode_pcm(pcm: bytes, response_format: str) -> tuple[bytes, str]:
    """Encode raw PCM into one of OpenAI's supported response formats."""

    if response_format == "pcm":
        return pcm, MEDIA_TYPES["pcm"]

    if response_format == "wav":
        buffer = io.BytesIO()
        with wave.open(buffer, "wb") as wav_file:
            wav_file.setnchannels(1)
            wav_file.setsampwidth(2)
            wav_file.setframerate(SAMPLE_RATE)
            wav_file.writeframes(pcm)
        return buffer.getvalue(), MEDIA_TYPES["wav"]

    common_input = [
        "-f",
        "s16le",
        "-ar",
        str(SAMPLE_RATE),
        "-ac",
        "1",
        "-i",
        "pipe:0",
    ]

    if response_format == "mp3":
        output = ["-c:a", "libmp3lame", "-b:a", "128k", "-f", "mp3", "pipe:1"]
    elif response_format == "opus":
        output = ["-c:a", "libopus", "-b:a", "64k", "-f", "ogg", "pipe:1"]
    elif response_format == "aac":
        output = ["-c:a", "aac", "-b:a", "128k", "-f", "adts", "pipe:1"]
    elif response_format == "flac":
        output = ["-c:a", "flac", "-f", "flac", "pipe:1"]
    else:
        raise ValueError(f"Unsupported response format: {response_format}")

    return _ffmpeg_run([*common_input, *output], pcm), MEDIA_TYPES[response_format]


def _synthesize_pcm(text: str, voice: str, speed: float) -> bytes:
    """Generate a complete PCM buffer for one request."""

    assert state is not None

    native_speed, stretch = _native_speed(speed)
    audio, _sample_rate = state.kokoro.create(
        text,
        voice=voice,
        speed=native_speed,
        lang=_voice_language(voice),
    )
    pcm = _to_pcm16(audio)

    # Speeds outside Kokoro's native range are handled with ffmpeg time-stretch
    # so the OpenAI speed contract (0.25-4.0) still works.
    return _stretch_pcm(pcm, stretch)


async def _synthesize_pcm_async(text: str, voice: str, speed: float) -> bytes:
    """Run complete synthesis in a worker thread while holding the model lock."""

    async with model_lock:
        return await asyncio.to_thread(_synthesize_pcm, text, voice, speed)


async def _chunk_bytes(data: bytes, chunk_size: int = 32768) -> AsyncIterator[bytes]:
    """Yield bytes in fixed-size chunks for StreamingResponse."""

    for offset in range(0, len(data), chunk_size):
        yield data[offset : offset + chunk_size]


async def _stream_pcm(
    text: str,
    voice: str,
    speed: float,
    chunk_size: int = 4800,
) -> AsyncIterator[bytes]:
    """Stream PCM as it is produced when possible.

    For the native 0.5-2.0 speed range, Kokoro's own sentence/batch streaming is
    used. Extreme speeds need a complete buffer because time-stretch must see
    the whole waveform; those cases are chunked after generation instead.
    """

    assert state is not None

    native_speed, stretch = _native_speed(speed)

    if stretch != 1.0:
        pcm = await _synthesize_pcm_async(text, voice, speed)
        async for chunk in _chunk_bytes(pcm, chunk_size):
            yield chunk
        return

    async with model_lock:
        async for audio, _sample_rate in state.kokoro.create_stream(
            text,
            voice=voice,
            speed=native_speed,
            lang=_voice_language(voice),
        ):
            pcm = _to_pcm16(audio)
            async for chunk in _chunk_bytes(pcm, chunk_size):
                yield chunk


def _sse_event(payload: dict[str, Any]) -> str:
    """Format one Server-Sent Event data frame."""

    return f"data: {json.dumps(payload, separators=(',', ':'))}\n\n"


async def _sse_stream(
    text: str,
    voice: str,
    speed: float,
    response_format: str,
) -> AsyncIterator[str]:
    """Emit OpenAI speech streaming events for ``stream_format='sse'``."""

    if response_format == "pcm":
        # PCM can be streamed genuinely as it is generated.
        async for chunk in _stream_pcm(text, voice, speed):
            yield _sse_event(
                {
                    "type": "speech.audio.delta",
                    "audio": base64.b64encode(chunk).decode("ascii"),
                }
            )
    else:
        # Compressed formats are encoded as a complete clip, then split into
        # SSE deltas. This is still protocol-compatible and works for every
        # OpenAI response format.
        pcm = await _synthesize_pcm_async(text, voice, speed)
        encoded, _media_type = _encode_pcm(pcm, response_format)
        async for chunk in _chunk_bytes(encoded, 32768):
            yield _sse_event(
                {
                    "type": "speech.audio.delta",
                    "audio": base64.b64encode(chunk).decode("ascii"),
                }
            )

    # OpenAI includes usage statistics in the final event. These values are
    # approximate; local inference does not expose exact token accounting.
    input_tokens = max(1, len(text) // 4)
    yield _sse_event(
        {
            "type": "speech.audio.done",
            "usage": {
                "input_tokens": input_tokens,
                "output_tokens": 0,
                "total_tokens": input_tokens,
            },
        }
    )


@router.post("/audio/speech")
async def create_speech(request: SpeechRequest) -> Response:
    """Generate speech using the OpenAI ``/v1/audio/speech`` contract."""

    # Accept OpenAI model names as aliases for the local Kokoro model.
    if request.model not in MODEL_ALIASES:
        raise StarletteHTTPException(
            status_code=400,
            detail={
                "message": (
                    f"Model '{request.model}' does not exist. "
                    "Use 'kokoro' or an OpenAI TTS model name."
                ),
                "type": "invalid_request_error",
                "param": "model",
                "code": "model_not_found",
            },
        )

    # Reject whitespace-only input early; it would otherwise fail deep inside
    # the phonemizer with an unhelpful server error.
    if not request.input.strip():
        raise StarletteHTTPException(
            status_code=400,
            detail={
                "message": "Input must contain at least one non-whitespace character.",
                "type": "invalid_request_error",
                "param": "input",
                "code": "invalid_input",
            },
        )

    # Resolve both native Kokoro names and OpenAI's voice names.
    voice = _resolve_voice(request.voice)

    # Kokoro has no instruction-following control; accept the field so clients
    # do not fail, but ignore its contents.
    if request.instructions:
        logger.debug("Ignoring 'instructions' because Kokoro does not support it")

    stream_format = request.stream_format or "audio"
    response_format = request.response_format

    try:
        # SSE mode emits speech.audio.delta / speech.audio.done events.
        if stream_format == "sse":
            return StreamingResponse(
                _sse_stream(
                    request.input,
                    voice,
                    request.speed,
                    response_format,
                ),
                media_type="text/event-stream",
                headers={
                    "Cache-Control": "no-cache",
                    "Connection": "keep-alive",
                    "X-Accel-Buffering": "no",
                },
            )

        # Raw PCM is the lowest-latency path because it can be streamed while
        # Kokoro is still generating later sentences.
        if response_format == "pcm":
            return StreamingResponse(
                _stream_pcm(request.input, voice, request.speed),
                media_type=MEDIA_TYPES["pcm"],
                headers={"Cache-Control": "no-cache"},
            )

        # Compressed formats need the full clip before encoding. The encoded
        # bytes are then sent in chunks so clients still receive a streamed
        # HTTP response.
        pcm = await _synthesize_pcm_async(request.input, voice, request.speed)
        encoded, media_type = _encode_pcm(pcm, response_format)
        return StreamingResponse(
            _chunk_bytes(encoded),
            media_type=media_type,
            headers={"Cache-Control": "no-cache"},
        )

    except StarletteHTTPException:
        raise
    except ValueError as exc:
        # Invalid text (for example, text that produces no phonemes) is a
        # client-side error, not a server failure.
        raise StarletteHTTPException(
            status_code=400,
            detail={
                "message": f"Could not synthesize the input: {exc}",
                "type": "invalid_request_error",
                "param": "input",
                "code": "invalid_input",
            },
        ) from exc
    except Exception as exc:
        logger.exception("Speech generation failed: %s", exc)
        raise StarletteHTTPException(
            status_code=500,
            detail={
                "message": f"Speech generation failed: {exc}",
                "type": "server_error",
                "param": None,
                "code": "speech_generation_failed",
            },
        ) from exc


# Register the /v1 router after all routes have been declared.
app.include_router(router)


def main() -> None:
    """Run the server with uvicorn when executed as a script."""

    logging.basicConfig(
        level=getattr(logging, LOG_LEVEL, logging.INFO),
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )

    import uvicorn

    uvicorn.run(
        app,
        host=HOST,
        port=PORT,
        log_level=LOG_LEVEL.lower(),
        access_log=False,
    )


if __name__ == "__main__":
    main()
