# Voice Agent

The voice agent handles AI conversation — listening to audio, generating responses, and streaming audio back.

## Interface

```ruby
agent = VoiceAgent::Grok.new(voice: 'Rex', agent_name: 'Garbo', instructions: '...')
agent.connect(
  on_ready:      -> { },
  on_audio:      ->(data) { },     # G.711μ audio chunks
  on_text:       ->(delta) { },    # Transcript deltas
  on_transcript: ->(text) { },     # Complete transcript
  on_error:      ->(e) { }
)
agent.send_audio(pcmu_bytes)       # Stream caller audio in
agent.send_text("Hello")           # Or send text
agent.disconnect
```

## Current: Grok (xAI)

- **Implementation:** `lib/voice_agent/grok.rb`
- **Protocol:** WebSocket (`wss://api.x.ai/v1/realtime`)
- **Audio:** G.711 μ-law (PCMU) 8kHz — native telephony format, no transcoding needed
- **Features:** Server-side VAD, text+audio modalities, 5 voice options (Ara, Rex, Sal, Eve, Leo)
- **Config:** `XAI_API_KEY` in `.env.local`, voice and personality from `config/default.yml` agent profiles

### Grok Event Flow

```
Client                          Server
  │── session.update ──────────▶│
  │◀──────────── session.updated│
  │── input_audio_buffer.append▶│  (streaming caller audio)
  │◀── input_audio_buffer.speech_started
  │◀── input_audio_buffer.speech_stopped
  │◀── response.output_audio.delta  (AI audio chunks)
  │◀── response.output_audio_transcript.delta
  │◀── response.output_audio_transcript.done
  │◀── response.done
```

### Docs

- **API Reference:** https://docs.x.ai/developers/model-capabilities/audio/voice-agent

## Adding a New Voice Agent

Create a subclass of `VoiceAgent`:

```ruby
class VoiceAgent::OpenAI < VoiceAgent
  def connect(**callbacks) = # WebSocket to OpenAI Realtime API
  def send_audio(data) = # ...
  def send_text(text) = # ...
  def disconnect = # ...
  def connected? = # ...
end
```
