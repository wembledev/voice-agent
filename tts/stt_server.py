#!/usr/bin/env python3
"""STT server — reads raw audio from stdin, writes JSON transcripts to stdout.

Protocol:
  Input (stdin, binary):
    Raw S16LE mono 8kHz audio frames (from G.711 decoder / audio bridge)

  Output (stdout, JSON lines):
    {"type": "transcript", "text": "Hello world", "duration": 2.1, "latency": 0.8}
    {"type": "speech_started"}
    {"type": "speech_stopped"}

  Status (stderr, JSON lines):
    {"status": "ready", "model": "..."}
    {"status": "error", "message": "..."}

Uses energy-based VAD to detect speech boundaries, then transcribes
complete utterances with mlx-whisper.

Designed to be spawned as a subprocess by Ruby VoiceAgent::Local.
"""

import json
import sys
import time
import struct
import io
import collections

import numpy as np


# VAD parameters
SAMPLE_RATE = 8000
FRAME_MS = 30              # VAD frame size in ms
FRAME_SAMPLES = int(SAMPLE_RATE * FRAME_MS / 1000)  # 240 samples per frame
FRAME_BYTES = FRAME_SAMPLES * 2  # S16LE = 2 bytes per sample

# Speech detection thresholds (tuned for 8kHz telephony audio)
ENERGY_THRESHOLD = 150     # RMS energy threshold for speech
SPEECH_FRAMES = 5          # Consecutive voiced frames to start speech
SILENCE_FRAMES = 30        # Consecutive silent frames to end speech (~900ms)
MIN_SPEECH_MS = 200        # Minimum speech duration to transcribe
MAX_SPEECH_S = 30          # Maximum speech duration before forced transcription


def rms_energy(samples):
    """Compute RMS energy of int16 samples."""
    return np.sqrt(np.mean(samples.astype(np.float32) ** 2))


def main():
    import argparse
    parser = argparse.ArgumentParser(description="STT stdin/stdout server")
    parser.add_argument("--model", default="mlx-community/whisper-small-mlx",
                        help="Whisper model name")
    parser.add_argument("--energy-threshold", type=float, default=ENERGY_THRESHOLD,
                        help="RMS energy threshold for VAD")
    parser.add_argument("--min-speech-ms", type=float, default=MIN_SPEECH_MS,
                        help="Minimum speech duration (ms) to transcribe")
    args = parser.parse_args()

    import mlx_whisper

    status({"status": "loading", "model": args.model})

    # Warmup whisper — first transcription is slow
    status({"status": "warming_up"})
    silence = np.zeros(SAMPLE_RATE, dtype=np.float32)  # 1s of silence
    mlx_whisper.transcribe(silence, path_or_hf_repo=args.model, language="en")

    status({"status": "ready", "model": args.model, "sample_rate": SAMPLE_RATE})

    stdin = sys.stdin.buffer
    energy_threshold = args.energy_threshold

    # State machine
    in_speech = False
    speech_frames = 0
    silence_frames = 0
    audio_buffer = []  # list of int16 arrays
    speech_start_time = None

    frame_count = 0

    while True:
        data = stdin.read(FRAME_BYTES)
        if not data or len(data) < FRAME_BYTES:
            break

        frame_count += 1
        samples = np.frombuffer(data, dtype=np.int16)
        energy = rms_energy(samples)

        is_voiced = energy > energy_threshold

        if not in_speech:
            if is_voiced:
                speech_frames += 1
                # Buffer pre-speech frames for context
                audio_buffer.append(samples)
                if speech_frames >= SPEECH_FRAMES:
                    in_speech = True
                    silence_frames = 0
                    speech_start_time = time.monotonic()
                    output({"type": "speech_started"})
            else:
                speech_frames = 0
                # Keep a small rolling buffer for pre-speech context
                audio_buffer.append(samples)
                if len(audio_buffer) > SPEECH_FRAMES * 2:
                    audio_buffer.pop(0)
        else:
            audio_buffer.append(samples)

            if is_voiced:
                silence_frames = 0
            else:
                silence_frames += 1

            speech_duration = time.monotonic() - speech_start_time

            # End of speech?
            force_end = speech_duration >= MAX_SPEECH_S
            natural_end = silence_frames >= SILENCE_FRAMES

            if force_end or natural_end:
                in_speech = False
                output({"type": "speech_stopped"})

                # Transcribe if long enough
                speech_ms = speech_duration * 1000
                if speech_ms >= args.min_speech_ms:
                    all_audio = np.concatenate(audio_buffer)
                    transcribe_and_output(all_audio, speech_start_time,
                                          args.model, mlx_whisper)

                # Reset
                audio_buffer.clear()
                speech_frames = 0
                silence_frames = 0
                speech_start_time = None

    # Handle any remaining speech
    if in_speech and audio_buffer and speech_start_time:
        output({"type": "speech_stopped"})
        all_audio = np.concatenate(audio_buffer)
        transcribe_and_output(all_audio, speech_start_time,
                              args.model, mlx_whisper)


def transcribe_and_output(audio_s16_8k, speech_start_time, model_name, mlx_whisper):
    """Resample to 16kHz float32, run Whisper, emit transcript."""
    import soxr

    t0 = time.monotonic()

    # Convert S16LE int16 → float32 normalized
    audio_f32 = audio_s16_8k.astype(np.float32) / 32768.0

    # Resample 8kHz → 16kHz (Whisper's expected rate)
    audio_16k = soxr.resample(audio_f32, 8000, 16000)

    # Transcribe
    result = mlx_whisper.transcribe(
        audio_16k,
        path_or_hf_repo=model_name,
        language="en",
        condition_on_previous_text=False,
    )

    text = result.get("text", "").strip()
    latency = time.monotonic() - t0
    duration = len(audio_s16_8k) / 8000.0

    if text:
        output({
            "type": "transcript",
            "text": text,
            "duration": round(duration, 2),
            "latency": round(latency, 2),
        })


def output(msg):
    """Write a JSON line to stdout."""
    sys.stdout.write(json.dumps(msg) + "\n")
    sys.stdout.flush()


def status(msg):
    """Write a JSON status line to stderr."""
    sys.stderr.write(json.dumps(msg) + "\n")
    sys.stderr.flush()


if __name__ == "__main__":
    main()
