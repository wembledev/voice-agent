# Setup

## Prerequisites

- macOS on Apple Silicon (M1/M2/M3/M4)
- [Homebrew](https://brew.sh/)
- A [voip.ms](https://voip.ms/en/invite/NTIyMzcx) account (or another SIP provider)
- An [xAI](https://console.x.ai/) API key

## 1. Ruby 4.0+

The agent requires Ruby 4.0 or later. macOS ships with an older system Ruby — use [rbenv](https://github.com/rbenv/rbenv) to install a current version:

```sh
brew install rbenv ruby-build
rbenv install 4.0.1
rbenv global 4.0.1
```

Restart your shell, then verify:

```sh
ruby -v   # should show 4.0.1 or later
```

Make sure `rbenv init` is in your shell profile (`~/.zshrc` or `~/.bashrc`). See [rbenv README](https://github.com/rbenv/rbenv#readme) for details.

## 2. Clone and install

```sh
git clone https://github.com/wembledev/voice-agent.git
cd voice-agent
bundle install
cp .env.local.example .env.local
```

Fill in your credentials in `.env.local` (see steps below). Then review `config/default.yml` for provider selection, baresip options, and agent profiles.

## 3. baresip (SIP client)

baresip handles phone call audio and signaling.

```sh
brew install baresip
```

Verify the module path matches your install — check `config/default.yml` under `sip.module_path`. On Apple Silicon the default is:

```
/opt/homebrew/Cellar/baresip/4.5.0/lib/baresip/modules
```

Adjust the version number if yours differs:

```sh
ls /opt/homebrew/Cellar/baresip/
```

## 4. ausock (audio bridge module)

ausock is a custom baresip module that bridges call audio to the voice agent over a Unix socket. Build and install it:

```sh
make -C ext/ausock
make -C ext/ausock install
```

If your baresip modules directory differs from the default, pass it explicitly:

```sh
make -C ext/ausock install MODULE_DIR=/opt/homebrew/Cellar/baresip/4.6.0/lib/baresip/modules
```

Verify it installed:

```sh
ls /opt/homebrew/Cellar/baresip/4.5.0/lib/baresip/modules/ausock.so
```

## 5. voip.ms (VoIP provider)

[voip.ms](https://voip.ms/en/invite/NTIyMzcx) connects the agent to the phone network. Sign up and then:

1. **Enable API access:** Main Menu > SOAP and REST/JSON API > enable it, set an API password
2. **Buy a DID:** Main Menu > Order DID > pick a number in your area
3. **Create a sub-account:** Main Menu > Sub Accounts > Create Sub Account
   - Set the protocol to SIP/UDP
   - Assign a password
   - Route your DID to this sub-account
4. **Note the SIP server:** pick a regional server near you (e.g. `vancouver1.voip.ms`)

Add to `.env.local`:

```sh
VOIPMS_API_USERNAME=you@example.com
VOIPMS_API_PASSWORD=your-api-password
SIP_USERNAME=000000_name
SIP_PASSWORD=your-sip-password
SIP_SERVER=vancouver1.voip.ms
```

Provider selection and baresip options (ctrl port, module path) are in `config/default.yml`.

Verify:

```sh
bin/voip balance
bin/voip dids
```

## 6. xAI / Grok (Voice Agent)

Grok powers the voice conversation — either via the Realtime WebSocket API or the text completion API (used by the local pipeline).

1. Create an account at [x.ai](https://x.ai/)
2. Go to the [xAI Console](https://console.x.ai/) and generate an API key
3. Add credits to your account (the Realtime API bills per minute of audio; the text API bills per token)

Add to `.env.local`:

```sh
XAI_API_KEY=xai-...
```

## 7. Local voice pipeline (optional)

Run STT and TTS locally on Apple Silicon instead of using the Grok Realtime WebSocket API. This uses [mlx-whisper](https://github.com/ml-explore/mlx-examples/tree/main/whisper) for speech-to-text and [Qwen3-TTS](https://github.com/ml-explore/mlx-audio) for text-to-speech. Requires Python 3.12+.

```sh
# Install Python 3.12 if you don't have it
brew install python@3.12

# Create the virtual environment and install dependencies
python3.12 -m venv tts/.venv
tts/.venv/bin/pip install -r tts/requirements.txt
```

Switch to the local pipeline in `config/default.yml`:

```yaml
voice_agent:
  provider: local   # instead of "grok"
```

Models are downloaded automatically on first run (~3-5 GB). The 4-bit quantized TTS model fits on 8GB Macs but leaves little headroom — see [docs/local-voice-pipeline.md](local-voice-pipeline.md) for performance details.

### Voice cloning (optional)

To clone a voice, add a 5-15 second clean WAV reference clip to `tts/ref_audio/` and configure an agent profile in `config/default.yml`:

```yaml
agents:
  myvoice:
    name: MyAgent
    ref_audio: tts/ref_audio/my_clip.wav
    ref_text: "Exact transcript of the reference audio"
    personality: "You are..."
```

Reference audio tips:
- 5-15 seconds of clear speech, no background noise or music
- Convert to 24kHz mono WAV: `ffmpeg -i input.mp3 -ar 24000 -ac 1 output.wav`
- Provide an exact transcript in `ref_text` for best quality

## 8. OpenClaw (AI Assistant — optional)

[OpenClaw](https://openclaw.ai/) runs locally as an AI assistant gateway, providing an OpenAI-compatible chat API. The voice agent uses it for tool-augmented conversations (e.g. looking things up mid-call).

### Install

```sh
npm install -g openclaw@latest
```

### Onboard and start the daemon

```sh
openclaw onboard --install-daemon
```

This walks you through initial setup, configures your preferred AI provider, and installs the gateway as a background service (LaunchAgent on macOS).

### Enable the HTTP API

The chat completions endpoint is disabled by default. Enable it:

```sh
openclaw config set gateway.http.endpoints.chatCompletions.enabled true
openclaw gateway restart
```

### Verify

```sh
# Check the gateway is running
curl -s http://127.0.0.1:18789/ | head -1

# Check your gateway token
openclaw config get gateway.auth.token
```

The voice agent auto-discovers the gateway token from `openclaw config` at runtime — no `.env.local` entry needed.

## 9. Run tests

```sh
rake test
```

## 10. Make a call

```sh
bin/call status              # Check SIP registration
bin/call 5550100             # Call with default agent
bin/call 5550100 --agent norm --verbose   # Call as Norm with debug logging
```
