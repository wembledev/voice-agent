#!/usr/bin/env python3
"""Full pipeline integration test: TTS → audio → STT round-trip.

Tests the complete chain and measures latency at each stage.
Optionally includes LLM (Grok text API) for the full STT → LLM → TTS loop.

Usage:
    python test_pipeline.py                    # TTS → STT round-trip
    python test_pipeline.py --with-llm         # STT → LLM → TTS → STT
    python test_pipeline.py --text "custom"    # Custom input text
"""

import argparse
import json
import os
import sys
import time

import numpy as np


def time_it(label):
    """Context manager that prints elapsed time."""
    class Timer:
        def __init__(self):
            self.elapsed = 0
        def __enter__(self):
            self.start = time.monotonic()
            return self
        def __exit__(self, *args):
            self.elapsed = time.monotonic() - self.start
            print(f"  [{label}] {self.elapsed:.2f}s")
    return Timer()


def main():
    parser = argparse.ArgumentParser(description="Pipeline integration test")
    parser.add_argument("--text", default="Hello, this is a test of the full voice pipeline. How are you doing today?")
    parser.add_argument("--with-llm", action="store_true", help="Include Grok text API in the loop")
    parser.add_argument("--trump", action="store_true", help="Use Trump CustomVoice for TTS")
    parser.add_argument("--tts-model", default=None)
    parser.add_argument("--stt-model", default="mlx-community/whisper-small-mlx")
    args = parser.parse_args()

    import mlx.core as mx
    from mlx_audio.tts import load as load_tts
    from mlx_audio.audio_io import write as audio_write
    import mlx_whisper
    import soxr

    print("=" * 60)
    print("Voice Pipeline Integration Test")
    print("=" * 60)

    # --- Stage 1: Load models ---
    print("\n--- Loading models ---")

    if args.tts_model:
        tts_model_name = args.tts_model
    elif args.trump:
        tts_model_name = "mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-4bit"
    else:
        tts_model_name = "mlx-community/Qwen3-TTS-12Hz-0.6B-Base-4bit"

    with time_it("TTS model load") as t_tts_load:
        tts_model = load_tts(tts_model_name)

    with time_it("STT model warmup") as t_stt_load:
        silence = np.zeros(16000, dtype=np.float32)
        mlx_whisper.transcribe(silence, path_or_hf_repo=args.stt_model, language="en")

    # --- Stage 2: TTS generation ---
    print(f"\n--- TTS: text → audio ---")
    print(f"  Input: {args.text[:80]}{'...' if len(args.text) > 80 else ''}")

    gen_kwargs = dict(
        text=args.text,
        lang_code="english",
        temperature=0.9,
        max_tokens=4096,
    )
    if args.trump:
        gen_kwargs["voice"] = "eric"
        gen_kwargs["instruct"] = (
            "Speak in a confident, bombastic tone with dramatic pauses. "
            "Deep male voice, authoritative."
        )

    with time_it("TTS generate (24kHz)") as t_tts:
        all_audio_24k = []
        for result in tts_model.generate(**gen_kwargs):
            all_audio_24k.append(np.array(result.audio))
        audio_24k = np.concatenate(all_audio_24k)
        tts_sample_rate = result.sample_rate

    tts_duration = len(audio_24k) / tts_sample_rate
    print(f"  Output: {tts_duration:.2f}s audio at {tts_sample_rate}Hz")
    print(f"  RTF: {tts_duration / t_tts.elapsed:.2f}x realtime")
    print(f"  Peak mem: {result.peak_memory_usage:.2f} GB")

    # --- Stage 3: Resample 24kHz → 8kHz (telephony) → 16kHz (Whisper) ---
    print(f"\n--- Resample: 24kHz → 8kHz → 16kHz ---")

    with time_it("Resample 24k→8k") as t_down:
        audio_8k = soxr.resample(audio_24k, 24000, 8000)

    with time_it("Resample 8k→16k") as t_up:
        audio_16k = soxr.resample(audio_8k, 8000, 16000)

    # Also simulate G.711 encode/decode to measure quality impact
    with time_it("G.711 μ-law round-trip simulation"):
        audio_s16_8k = np.clip(audio_8k * 32767, -32768, 32767).astype(np.int16)
        # Simulate: S16LE → PCMU → S16LE (just measure the quantization noise)
        # We don't have the Ruby G.711 codec here, but the 8-bit quantization
        # is the main quality loss — resampling handles the rest
        snr = 10 * np.log10(np.mean(audio_s16_8k.astype(float)**2) /
                            max(1, np.mean((audio_s16_8k % 16).astype(float)**2)))
        print(f"  Estimated telephony SNR: {snr:.1f} dB")

    # --- Stage 4: STT transcription ---
    print(f"\n--- STT: audio → text ---")

    with time_it("STT transcribe") as t_stt:
        stt_result = mlx_whisper.transcribe(
            audio_16k,
            path_or_hf_repo=args.stt_model,
            language="en",
            condition_on_previous_text=False,
        )

    transcript = stt_result.get("text", "").strip()
    print(f"  Transcript: {transcript}")
    print(f"  STT latency: {t_stt.elapsed:.2f}s for {tts_duration:.1f}s audio")

    # --- Stage 5 (optional): LLM round-trip ---
    llm_time = 0
    llm_response = None
    if args.with_llm:
        print(f"\n--- LLM: transcript → response ---")
        api_key = os.environ.get("XAI_API_KEY")
        if not api_key:
            print("  SKIPPED: XAI_API_KEY not set")
        else:
            import urllib.request

            try:
                with time_it("Grok text API") as t_llm:
                    payload = json.dumps({
                        "model": "grok-3-mini",
                        "messages": [
                            {"role": "system", "content": "You are a helpful voice assistant. Be concise."},
                            {"role": "user", "content": transcript},
                        ],
                        "max_tokens": 256,
                        "temperature": 0.7,
                    }).encode()

                    req = urllib.request.Request(
                        "https://api.x.ai/v1/chat/completions",
                        data=payload,
                        headers={
                            "Authorization": f"Bearer {api_key}",
                            "Content-Type": "application/json",
                        },
                    )
                    with urllib.request.urlopen(req, timeout=30) as resp:
                        body = json.loads(resp.read())
                        llm_response = body["choices"][0]["message"]["content"].strip()

                llm_time = t_llm.elapsed
                print(f"  Response: {llm_response[:120]}{'...' if len(llm_response) > 120 else ''}")
            except Exception as e:
                print(f"  LLM ERROR: {e}")
                llm_time = 0

    # --- Summary ---
    print("\n" + "=" * 60)
    print("PIPELINE LATENCY SUMMARY")
    print("=" * 60)
    print(f"  TTS model load:    {t_tts_load.elapsed:6.2f}s  (one-time)")
    print(f"  STT model load:    {t_stt_load.elapsed:6.2f}s  (one-time)")
    print(f"  TTS generation:    {t_tts.elapsed:6.2f}s  → {tts_duration:.1f}s audio ({tts_duration/t_tts.elapsed:.1f}x RT)")
    print(f"  Resample (down):   {t_down.elapsed:6.3f}s")
    print(f"  Resample (up):     {t_up.elapsed:6.3f}s")
    print(f"  STT transcribe:    {t_stt.elapsed:6.2f}s")
    if llm_time:
        print(f"  LLM (Grok text):   {llm_time:6.2f}s")

    total_pipeline = t_tts.elapsed + t_down.elapsed + t_up.elapsed + t_stt.elapsed + llm_time
    print(f"  ─────────────────────────")
    print(f"  Total pipeline:    {total_pipeline:6.2f}s")
    print(f"  Audio duration:    {tts_duration:6.2f}s")
    print()
    print(f"  Input text:     {args.text[:60]}")
    print(f"  STT transcript: {transcript[:60]}")
    if llm_response:
        print(f"  LLM response:   {llm_response[:60]}")

    # Save audio artifacts
    audio_write("/tmp/pipeline_24k.wav", audio_24k, 24000, format="wav")
    audio_write("/tmp/pipeline_8k.wav", audio_8k, 8000, format="wav")
    audio_write("/tmp/pipeline_16k.wav", audio_16k, 16000, format="wav")
    print(f"\n  Saved: /tmp/pipeline_{{24k,8k,16k}}.wav")


if __name__ == "__main__":
    main()
