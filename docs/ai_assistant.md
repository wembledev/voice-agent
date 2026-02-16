# AI Assistant

The AI assistant is the conversational brain — handling text-based chat for decision-making, tool use, and non-voice interactions.

## Interface

```ruby
assistant = AiAssistant::OpenClaw.new
assistant.name                     # Display name
assistant.instructions             # System prompt
assistant.chat("What time is it?") # Send message, get response
assistant.configured?              # Has a valid API key?
```

## Current: OpenClaw

- **Implementation:** `lib/ai_assistant/openclaw.rb`
- **Protocol:** OpenAI-compatible HTTP API (POST `/v1/chat/completions`)
- **Gateway:** Local OpenClaw daemon at `http://127.0.0.1:18789`
- **Auth:** Bearer token, auto-discovered from `openclaw config get gateway.auth.token`
- **Model:** `openclaw:main` (routes to whatever model you configure in OpenClaw)
- **Config:** Provider selection in `config/default.yml`, gateway token auto-discovered

### Setup

See [setup.md](setup.md) for full OpenClaw installation steps. The key command to enable the HTTP API:

```sh
openclaw config set gateway.http.endpoints.chatCompletions.enabled true
openclaw gateway restart
```

## Adding a New AI Assistant

Create a subclass of `AiAssistant`:

```ruby
class AiAssistant::Direct < AiAssistant
  def name = # ...
  def instructions = # ...
  def chat(message) = # ...
end
```
