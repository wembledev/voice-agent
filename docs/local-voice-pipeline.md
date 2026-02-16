# Local Voice Pipeline (Experimental)

Local STT + TTS pipeline using MLX on Apple Silicon, replacing Grok's realtime
WebSocket API with fully local speech processing.

## Architecture

```
                    ┌─────────────┐
   Caller Audio ───→│  STT Server │──→ transcript (JSON)
   (S16LE 8kHz)     │  (Whisper)  │         │
                    └─────────────┘         ▼
                                     ┌─────────────┐
                                     │  LLM (Grok  │
                                     │  text API)  │
                                     └──────┬──────┘
                                            │ response text
                                            ▼
                    ┌─────────────┐   ┌─────────────┐
   Agent Audio  ◄───│  Resample   │◄──│  TTS Server │
   (S16LE 8kHz)     │  24k → 8k  │   │ (Qwen3-TTS) │
                    └─────────────┘   └─────────────┘
```

### Components

| Component | Model | Format | Runs as |
|-----------|-------|--------|---------|
| STT | whisper-small-mlx | S16LE 8kHz in → JSON out | Python subprocess |
| LLM | grok-3-mini (text API) | JSON → JSON | HTTP API call |
| TTS | Qwen3-TTS-0.6B-CustomVoice-4bit | JSON in → S16LE 8kHz out | Python subprocess |

### Audio Protocol (TTS → Ruby)

The TTS server writes audio to stdout with a framing protocol:

1. Audio is accumulated at 24kHz, resampled to 8kHz in a single pass (no per-chunk resampling artifacts)
2. Output is padded to 320-byte frame boundaries (20ms frames)
3. A 4-byte sentinel (`0xDEADBEEF` little-endian) marks the end of each utterance
4. Ruby reader detects sentinels to flush buffers between utterances and synchronize the `on_response_done` callback

This eliminates three classes of choppy audio bugs:
- Vocoder splice artifacts from per-chunk streaming decode
- soxr resampler filter edge effects at chunk boundaries
- Frame misalignment accumulating across utterances

### Ruby Integration

`VoiceAgent::Local` (lib/voice_agent/local.rb) implements the same callback
interface as `VoiceAgent::Grok`, so `CallSession` works unchanged. Select it
via config:

```yaml
voice_agent:
  provider: local
```

Agent profiles support local-specific options:

```yaml
agents:
  trump:
    name: Donald
    voice: ryan
    trump: true
    tts_instruct: "Speak with a distinctive New York/Queens accent..."
    personality: "You are Donald Trump..."
```

## Trump Voice

Three approaches, in order of quality:

### 1. Voice Cloning (Best — requires reference audio)

Use the Base model with a 5-15 second clean Trump audio clip:

```yaml
agents:
  trump-clone:
    name: Donald
    ref_audio: /path/to/trump_reference.wav  # 24kHz WAV, clean speech
    ref_text: "Exact transcript of the reference audio"
    personality: "You are Donald Trump..."
```

**Reference audio tips:**
- 5-15 seconds of clear speech, no background noise/music
- Convert to 24kHz mono WAV: `ffmpeg -i input.mp3 -ar 24000 -ac 1 trump.wav`
- Provide an exact transcript in `ref_text` for best quality
- Sources: C-SPAN press conferences, inauguration speeches, Kaggle Trump Speeches dataset

### 2. CustomVoice with Instruct (Good — no reference needed)

Use the CustomVoice model with detailed voice description:

```yaml
agents:
  trump:
    voice: ryan        # Deep male preset
    trump: true
    tts_instruct: >
      Speak with a distinctive New York/Queens accent. Voice is deep,
      slightly raspy and nasal, with a bombastic, confident delivery.
      Use dramatic pauses and emphasis on key words.
```

CustomVoice speakers: serena, vivian, uncle_fu, ryan, aiden, ono_anna, sohee, eric, dylan

### 3. VoiceDesign (Experimental — describe the voice)

Use the VoiceDesign model variant to create a voice from description alone.
Not yet wired into the pipeline but supported by mlx-audio.

## Performance (Mac mini M2, 8GB RAM)

### Latency

| Stage | Time | Notes |
|-------|------|-------|
| TTS model load | 3.8s | One-time, cached after first download |
| STT model load | 0.9s | One-time |
| TTS generation | 7.0s for 8.6s audio | **1.2x realtime** |
| Resample (24k→8k) | 10ms | Negligible |
| STT transcribe | 0.4s for 8.6s audio | **19.5x realtime** |
| LLM (Grok text) | ~0.2s | Network-dependent |
| **Total pipeline** | **~7.5s** | Dominated by TTS |

### Memory

| Component | Peak RAM |
|-----------|----------|
| TTS (CustomVoice 4-bit) | 5.4-6.5 GB |
| TTS (Base 4-bit) | 2.9-3.5 GB |
| STT (whisper-small) | ~0.5 GB |
| **Combined** | **~6-7 GB** |

The 4-bit quantized CustomVoice model fits in 8GB but leaves little headroom.
The Base model is more comfortable. Running STT and TTS simultaneously is
possible since they don't overlap in practice (half-duplex conversation).

### Quality

- **TTS round-trip SNR**: ~43-48 dB through resample chain
- **STT accuracy**: Good for clear TTS output; "Hello, this is a test of the
  full voice pipeline" → "Hello, this is a test of the full voice pipeline!"
- **Trump voice**: CustomVoice instruct produces authoritative male voice;
  not a true Trump impersonation but captures the bombastic tone. Voice cloning
  with reference audio will produce much closer results.

## Files

```
tts/
├── .venv/              # Python 3.12 virtual environment
├── .gitignore          # Excludes .venv, __pycache__, *.wav
├── requirements.txt    # Frozen pip dependencies
├── test_tts.py         # Standalone TTS test (WAV output)
├── test_pipeline.py    # Full pipeline integration test
├── tts_server.py       # TTS subprocess (JSON stdin → S16LE stdout)
└── stt_server.py       # STT subprocess (S16LE stdin → JSON stdout)

lib/voice_agent/
└── local.rb            # Ruby VoiceAgent::Local class
```

## Setup

```bash
# Create venv (already done)
/opt/homebrew/bin/python3.12 -m venv tts/.venv

# Install deps
tts/.venv/bin/pip install mlx-audio mlx-whisper numpy scipy soxr

# Test TTS standalone
tts/.venv/bin/python tts/test_tts.py --trump --output /tmp/trump.wav

# Test full pipeline
tts/.venv/bin/python tts/test_pipeline.py --trump

# Run with baresip (needs voice_agent.provider: local in config)
bin/call 5551234 --agent trump -v
```

## Known Issues

1. **Double resample degrades STT quality**: 24kHz→8kHz→16kHz loses high
   frequencies. Could be improved by keeping a separate 16kHz STT path.

2. **Utterance-level latency**: TTS accumulates the full utterance before
   writing audio (to avoid splice artifacts). For a 5-second response, the
   caller waits ~4s before hearing anything. Streaming with crossfade
   blending could reduce this.

3. **Memory pressure on 8GB**: CustomVoice 4-bit uses 5-6.5 GB peak. Under
   memory pressure, macOS will swap and latency will spike. Base model (3.5 GB)
   is safer.

4. **Barge-in is sentence-level**: Caller can interrupt between sentences (~1s
   gaps) but not mid-sentence. Grok Realtime handles this at the audio frame level.

5. **Grok text API 403**: The text completion endpoint may require different
   auth or plan level than the realtime API.

## Next Steps

- [ ] Get a clean Trump reference audio clip and test voice cloning
- [ ] Test with baresip end-to-end
- [ ] Try F5-TTS-MLX as alternative (doesn't need transcript for cloning)
- [ ] Try 1.7B model (much better cloning) if RAM permits
- [ ] Consider keeping 16kHz path for STT (skip telephony resample)
- [ ] Add streaming with crossfade blending for lower first-byte latency
- [ ] Explore LoRA fine-tuning for highest-quality Trump voice
