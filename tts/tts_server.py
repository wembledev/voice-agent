#!/usr/bin/env python3
"""TTS server — reads JSON lines from stdin, writes raw audio frames to stdout.

Protocol:
  Input (stdin, JSON lines):
    {"text": "Hello world", "voice": "eric", "instruct": "confident tone"}
    {"text": "Hello", "ref_audio": "/path/to/clip.wav", "ref_text": "transcript"}

  Output (stdout, binary):
    Raw S16LE mono 8kHz audio frames (ready for G.711 conversion), padded to
    320-byte frame boundaries. Each utterance ends with a 4-byte sentinel
    (0xDEAD_BEEF) so the reader can flush its buffer between utterances.

  Status (stderr, JSON lines):
    {"status": "ready", "model": "...", "sample_rate": 8000}
    {"status": "generating", "text_length": 42}
    {"status": "chunk", "n": 1, "samples": 12000, "bytes": 24000}
    {"status": "done", "audio_duration": 2.8, "gen_time": 2.1, "rtf": 1.33}
    {"status": "error", "message": "..."}

The server keeps the model loaded in memory between requests.
Designed to be spawned as a subprocess by Ruby VoiceAgent::Local.
"""

import json
import sys
import time
import struct

# Sentinel bytes written after each utterance's audio data.
# Ruby reader uses this to flush partial-frame buffers between utterances.
UTTERANCE_BOUNDARY = struct.pack('<I', 0xDEADBEEF)
FRAME_BYTES = 320  # S16LE mono 8kHz, 160 samples = 20ms


def main():
    import argparse
    parser = argparse.ArgumentParser(description="TTS stdin/stdout server")
    parser.add_argument("--model", default=None, help="Model name (default: auto)")
    parser.add_argument("--trump", action="store_true", help="Use CustomVoice model")
    parser.add_argument("--voice", default=None, help="Default speaker voice")
    parser.add_argument("--instruct", default=None, help="Default CustomVoice instruction")
    parser.add_argument("--ref-audio", default=None, help="Default reference audio for voice cloning")
    parser.add_argument("--ref-text", default=None, help="Default reference audio transcript")
    args = parser.parse_args()

    # Determine model
    if args.model:
        model_name = args.model
    elif args.ref_audio:
        # Voice cloning requires Base model
        model_name = "mlx-community/Qwen3-TTS-12Hz-0.6B-Base-4bit"
    elif args.trump:
        model_name = "mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-4bit"
    else:
        model_name = "mlx-community/Qwen3-TTS-12Hz-0.6B-Base-4bit"

    default_voice = args.voice or ("ryan" if args.trump else None)
    default_instruct = args.instruct
    default_ref_audio = args.ref_audio
    default_ref_text = args.ref_text

    # Lazy imports
    import numpy as np
    from mlx_audio.tts import load
    import soxr

    status({"status": "loading", "model": model_name})

    model = load(model_name)

    # Warmup — generate a tiny clip to prime the GPU
    status({"status": "warming_up"})
    warmup_kwargs = dict(text="Hello.", lang_code="english", max_tokens=512)
    if default_ref_audio:
        warmup_kwargs["ref_audio"] = default_ref_audio
        warmup_kwargs["ref_text"] = default_ref_text or ""
    else:
        warmup_kwargs["voice"] = default_voice
        warmup_kwargs["instruct"] = default_instruct
    for _ in model.generate(**warmup_kwargs):
        pass

    status({"status": "ready", "model": model_name, "sample_rate": 8000})

    stdout = sys.stdout.buffer

    # Flush any bytes leaked to stdout during warmup (e.g. from progress bars
    # or model internals). Write a sentinel so the Ruby reader discards them.
    stdout.write(UTTERANCE_BOUNDARY)
    stdout.flush()

    # Process requests
    while True:
        line = sys.stdin.readline()
        if not line:  # EOF
            break

        line = line.strip()
        if not line:
            continue

        try:
            req = json.loads(line)
        except json.JSONDecodeError as e:
            status({"status": "error", "message": f"Invalid JSON: {e}"})
            continue

        text = req.get("text", "").strip()
        if not text:
            status({"status": "error", "message": "Empty text"})
            continue

        voice = req.get("voice", default_voice)
        instruct = req.get("instruct", default_instruct)
        ref_audio = req.get("ref_audio", default_ref_audio)
        ref_text = req.get("ref_text", default_ref_text)

        status({"status": "generating", "text_length": len(text)})
        t0 = time.monotonic()

        try:
            gen_kwargs = dict(
                text=text,
                lang_code="english",
                temperature=0.9,
                max_tokens=4096,
                stream=True,
                streaming_interval=1.5,  # ~1.25s wall clock to first chunk
            )

            if ref_audio:
                # Voice cloning mode (ICL)
                gen_kwargs["ref_audio"] = ref_audio
                gen_kwargs["ref_text"] = ref_text or ""
            else:
                gen_kwargs["voice"] = voice
                gen_kwargs["instruct"] = instruct

            resampler = soxr.ResampleStream(24000, 8000, num_channels=1, dtype='float32')
            total_bytes = 0
            chunk_count = 0

            for result in model.generate(**gen_kwargs):
                chunk_24k = np.array(result.audio, dtype=np.float32)
                chunk_count += 1

                chunk_8k = resampler.resample_chunk(chunk_24k, last=False)
                if chunk_8k.size == 0:
                    continue

                s16 = np.clip(chunk_8k * 32767, -32768, 32767).astype(np.int16)
                stdout.write(s16.tobytes())
                stdout.flush()
                total_bytes += len(s16) * 2

                status({"status": "chunk", "n": chunk_count,
                        "samples": len(s16), "bytes": total_bytes})

            # Flush remaining samples buffered in the resampler
            tail = resampler.resample_chunk(np.array([], dtype=np.float32), last=True)
            if tail.size > 0:
                s16 = np.clip(tail * 32767, -32768, 32767).astype(np.int16)
                stdout.write(s16.tobytes())
                total_bytes += len(s16) * 2

            if chunk_count == 0:
                status({"status": "error", "message": "No audio generated"})
                stdout.write(UTTERANCE_BOUNDARY)
                stdout.flush()
                continue

            # Pad final output to frame boundary
            remainder = total_bytes % FRAME_BYTES
            if remainder:
                pad = b'\x00' * (FRAME_BYTES - remainder)
                stdout.write(pad)
                total_bytes += len(pad)

            # End-of-utterance sentinel
            stdout.write(UTTERANCE_BOUNDARY)
            stdout.flush()

            gen_time = time.monotonic() - t0
            audio_duration = (total_bytes / 2) / 8000.0
            rtf = audio_duration / gen_time if gen_time > 0 else 0

            status({
                "status": "done",
                "audio_duration": round(audio_duration, 2),
                "gen_time": round(gen_time, 2),
                "rtf": round(rtf, 2),
                "chunks": chunk_count,
                "bytes": total_bytes,
            })

        except Exception as e:
            import traceback
            status({"status": "error", "message": str(e),
                    "traceback": traceback.format_exc()})

    status({"status": "shutdown"})


def status(msg):
    """Write a JSON status line to stderr."""
    sys.stderr.write(json.dumps(msg) + "\n")
    sys.stderr.flush()


if __name__ == "__main__":
    main()
