#!/usr/bin/env python3
"""Standalone Qwen3-TTS test — generates speech and saves WAV files.

Usage:
    # Basic generation with default voice
    python test_tts.py

    # Trump voice via CustomVoice instruct
    python test_tts.py --trump

    # Voice cloning from reference audio
    python test_tts.py --clone reference.wav "Transcript of reference audio"

    # List available voices
    python test_tts.py --list-voices
"""

import argparse
import sys
import time
import os

def main():
    parser = argparse.ArgumentParser(description="Qwen3-TTS test harness")
    parser.add_argument("--trump", action="store_true", help="Use CustomVoice with Trump instructions")
    parser.add_argument("--clone", nargs=2, metavar=("AUDIO", "TEXT"), help="Clone voice from reference audio")
    parser.add_argument("--list-voices", action="store_true", help="List available speaker voices")
    parser.add_argument("--voice", default=None, help="Speaker voice name (default: auto-select)")
    parser.add_argument("--text", default=None, help="Text to synthesize")
    parser.add_argument("--output", "-o", default="output.wav", help="Output WAV path")
    parser.add_argument("--stream", action="store_true", help="Use streaming generation")
    args = parser.parse_args()

    # Lazy imports — model loading is slow, don't pay the cost for --help
    import mlx.core as mx
    import numpy as np
    from mlx_audio.tts import load
    from mlx_audio.audio_io import write as audio_write

    if args.trump:
        model_name = "mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-4bit"
    else:
        model_name = "mlx-community/Qwen3-TTS-12Hz-0.6B-Base-4bit"

    print(f"Loading model: {model_name}")
    t0 = time.monotonic()
    model = load(model_name)
    load_time = time.monotonic() - t0
    print(f"Model loaded in {load_time:.1f}s")

    if args.list_voices:
        print("\nAvailable speakers:")
        for s in model.get_supported_speakers():
            print(f"  - {s}")
        print("\nAvailable languages:")
        for l in model.get_supported_languages():
            print(f"  - {l}")
        return

    # Pick text
    if args.text:
        text = args.text
    elif args.trump:
        text = (
            "Let me tell you something, and believe me, nobody knows more about "
            "this than I do. We're going to make phone calls great again. "
            "These AI voice agents? Tremendous. The best. People are saying "
            "it's the most beautiful technology they've ever seen."
        )
    else:
        text = "Hello! This is a test of the Qwen 3 text to speech system running locally on Apple Silicon."

    print(f"\nText: {text[:100]}{'...' if len(text) > 100 else ''}")

    # Generate
    t0 = time.monotonic()

    if args.clone:
        ref_audio_path, ref_text = args.clone
        print(f"Cloning voice from: {ref_audio_path}")
        results = model.generate(
            text=text,
            ref_audio=ref_audio_path,
            ref_text=ref_text,
            lang_code="english",
            temperature=0.9,
            max_tokens=4096,
            stream=args.stream,
        )
    elif args.trump:
        voice = args.voice or "eric"
        print(f"Using CustomVoice with Trump instructions (speaker: {voice})")
        results = model.generate(
            text=text,
            voice=voice,
            instruct="Speak in a confident, bombastic tone with dramatic pauses and emphasis. Deep male voice, authoritative and self-assured.",
            lang_code="english",
            temperature=0.9,
            max_tokens=4096,
            stream=args.stream,
        )
    else:
        print(f"Using voice: {args.voice}")
        results = model.generate(
            text=text,
            voice=args.voice,
            lang_code="english",
            temperature=0.9,
            max_tokens=4096,
            stream=args.stream,
        )

    # Collect all audio chunks
    all_audio = []
    sample_rate = None
    for i, result in enumerate(results):
        gen_time = time.monotonic() - t0
        sample_rate = result.sample_rate
        audio_np = np.array(result.audio)
        all_audio.append(audio_np)

        print(f"\n--- Chunk {i} ---")
        print(f"  Duration:    {result.audio_duration}")
        print(f"  Samples:     {len(audio_np)}")
        print(f"  Sample rate: {sample_rate} Hz")
        print(f"  RTF:         {result.real_time_factor:.2f}x realtime")
        print(f"  Peak memory: {result.peak_memory_usage:.2f} GB")
        print(f"  Gen time:    {result.processing_time_seconds:.2f}s")

    if not all_audio:
        print("ERROR: No audio generated")
        sys.exit(1)

    # Concatenate and save
    combined = np.concatenate(all_audio)
    total_duration = len(combined) / sample_rate
    total_time = time.monotonic() - t0

    print(f"\n=== Summary ===")
    print(f"Total audio:  {total_duration:.2f}s ({len(combined)} samples)")
    print(f"Total time:   {total_time:.2f}s")
    print(f"Overall RTF:  {total_duration / total_time:.2f}x realtime")
    print(f"Load time:    {load_time:.1f}s")

    audio_write(args.output, combined, sample_rate, format="wav")
    print(f"\nSaved: {args.output}")

if __name__ == "__main__":
    main()
