# Config

The `Config` class loads application configuration from YAML and secrets from `.env.local`.

## Two Layers

| Layer | File | Contains |
|-------|------|----------|
| Config | `config/default.yml` | Providers, agent profiles, baresip options |
| Secrets | `.env.local` | API keys, SIP password (loaded by dotenv) |

ERB interpolation in the YAML injects secrets from `ENV` without duplicating values:

```yaml
sip:
  server: <%= ENV['SIP_SERVER'] %>
```

## `config/default.yml` Reference

```yaml
sip:
  client: baresip                    # SIP client implementation
  server: <%= ENV['SIP_SERVER'] %>   # From .env.local
  username: <%= ENV['SIP_USERNAME'] %>
  password: <%= ENV['SIP_PASSWORD'] %>
  module_path: /opt/homebrew/Cellar/baresip/4.5.0/lib/baresip/modules
  ctrl_port: 4444

voip:
  provider: voipms                   # VoIP provider implementation

voice_agent:
  provider: grok                     # Voice agent implementation

ai_assistant:
  provider: openclaw                 # AI assistant implementation

agents:                              # Agent profiles
  garbo:
    name: Garbo
    voice: Rex                       # Grok voice (Ara, Rex, Sal, Eve, Leo)
    personality: >
      You are Garbo, a helpful AI voice assistant.
      Be concise and conversational.
  ara:
    name: Ara
    voice: Ara
    personality: >
      You are Ara, a cheeky but helpful AI voice assistant.

default_agent: ara                   # Used when --agent is not specified
```

## Agent Profiles

Each profile has three fields:

| Field | Description |
|-------|-------------|
| `name` | Display name (shown in logs, used as agent identity) |
| `voice` | Grok voice option: Ara, Rex, Sal, Eve, or Leo |
| `personality` | System instructions sent to the voice agent |

### Selecting an Agent

```sh
bin/call 5550100                    # Uses default_agent from config
bin/call 5550100 --agent jarvis     # Uses jarvis profile
bin/call 5550100 --agent garbo      # Uses garbo profile
```

### Runtime Personality Override

Use `--instructions` to override the personality while keeping the agent's voice and name:

```sh
bin/call 5550100 --agent ara --instructions "You are Norm Macdonald. Tell the moth joke from Conan."
```

This uses Ara's voice but with custom instructions. Useful for one-off calls without editing the config.

### Adding a New Agent

Add a new entry under `agents:` in `config/default.yml`:

```yaml
agents:
  custom:
    name: Custom
    voice: Eve
    personality: >
      You are Custom, a specialized AI assistant.
      Your specialty is helping with technical questions.
```

## Ruby API

```ruby
# Load config (auto-loads on first fetch)
Config.load!

# Fetch nested values
Config.fetch(:sip, :client)          # => "baresip"
Config.fetch(:sip, :server)          # => "vancouver1.voip.ms"
Config.fetch(:voice_agent, :provider) # => "grok"

# Get agent profile
Config.agent                         # => default agent hash
Config.agent('jarvis')               # => jarvis agent hash
# Returns: { 'name' => 'Jarvis', 'voice' => 'Rex', 'personality' => '...' }

# Reset (for tests)
Config.reset!
```
