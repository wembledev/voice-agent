# Call Control Triggers

Research and implementation notes for voice call triggers.

## Research: garbo-phone Implementation

### 1. Keyword Detection (Farewell)

**Location:** `lib/garbo_phone/grok/streaming_handler.rb`

**Pattern:**
```ruby
FAREWELL_PATTERNS = /\b(goodbye|good bye|bye bye|bye|see you|talk to you later|gotta go|got to go|take care|later|have a good one|catch you later|see ya|peace out)\b/i
```

**Flow:**
1. User transcript received via `input_audio_transcription.completed` event
2. `check_farewell(transcript)` called
3. If pattern matches → `trigger_hangup!(:farewell)`
4. `@pending_hangup_reason` is set (doesn't hang up immediately)
5. On `response.done` event, `on_hangup` callback is invoked with audio duration
6. Bridge waits for audio playback to finish, then hangs up SIP

**Key insight:** Hangup is *deferred* until after the goodbye response plays. This avoids cutting off the AI mid-sentence.

### 2. Silence Detection

**Location:** `lib/garbo_phone/grok/streaming_handler.rb`

**Constants:**
```ruby
SILENCE_TIMEOUT = 20 # seconds
```

**State tracked:**
- `@last_garbo_finished_at` — timestamp when AI finished speaking (set on `response.done`)
- `@is_speaking` — true while AI is generating/playing audio

**Flow:**
1. Async task in Bridge polls every 2 seconds
2. Calls `handler.silence_timed_out?`
3. Method checks: `(Time.now - @last_garbo_finished_at) > SILENCE_TIMEOUT`
4. Only triggers if AI is NOT currently speaking
5. Sends "I can't hear you" message, then triggers hangup

**Key insight:** Timer only starts *after* AI finishes speaking. Otherwise you'd hang up during your own responses.

### 3. Request Capture (Dashbot Integration)

**Location:** `lib/garbo_phone/dashbot/listener.rb`, `lib/garbo_phone/dashbot/injector.rb`

**Pattern:** NOT keyword-based! It uses:
1. System prompt instructs Grok about background assistant
2. All transcripts forwarded to external dashbot server
3. Dashbot (OpenClaw) processes requests asynchronously
4. Injector polls for responses and injects them into Grok conversation

**This is NOT trigger-based** — it's transcript forwarding + response injection.

### 4. Tool Handler

**Location:** `lib/garbo_phone/grok/tool_handler.rb`

Function calling via Grok's native tools:
- Register handlers: `handler.register("get_weather") { |args| ... }`
- Handle `response.function_call_arguments.done` events
- Send result back via `conversation.item.create`

---

## Design: garbo-voice-agent Trigger System

### Goals

1. **Modular** — easy to add new triggers
2. **Separation** — detection logic separate from actions
3. **Configurable** — simple YAML or hash config
4. **Testable** — triggers can be unit tested in isolation

### Architecture

```
                     ┌─────────────────┐
   transcripts ──────▶│ TriggerManager │──────▶ actions
                     └─────────────────┘
                            │
                 ┌──────────┼──────────┐
                 ▼          ▼          ▼
           ┌─────────┐ ┌─────────┐ ┌─────────┐
           │ Keyword │ │ Silence │ │ Request │
           │ Trigger │ │ Trigger │ │ Capture │
           └─────────┘ └─────────┘ └─────────┘
```

### Base Pattern

```ruby
class Trigger
  def initialize(config = {})
  end
  
  def check(context)
    # Return action symbol or nil
  end
end
```

### Trigger Types

| Trigger | Detects | Action |
|---------|---------|--------|
| `KeywordTrigger` | "goodbye", "bye", etc. | `:hangup` |
| `SilenceTrigger` | No speech for N seconds | `:hangup` |
| `RequestCapture` | "hey garbo..." prefix | `:delegate` |

### Context Object

```ruby
{
  transcript: "...",           # User's words
  role: :user/:assistant,      # Who spoke
  last_speech_at: Time,        # When user last spoke
  last_response_at: Time,      # When AI finished responding
  is_speaking: bool            # Is AI currently speaking?
}
```

---

## Implementation Plan

### Phase 1: Core Framework ✅
- [x] Document garbo-phone approach
- [x] Create `Trigger` base class
- [x] Create `TriggerManager` to coordinate triggers

### Phase 2: Implement Triggers ✅
- [x] `KeywordTrigger` — farewell detection
- [x] `SilenceTrigger` — timeout detection
- [x] `RequestCapture` — "hey garbo" delegation

### Phase 3: Integration ✅
- [x] Wire into `VoiceAgent::Grok`
- [x] Add callbacks for hangup/delegate actions

---

## Files Created

```
lib/
  trigger.rb                    # Base class ✅
  trigger_manager.rb            # Coordinator ✅
  triggers.rb                   # Convenience loader ✅
  triggers/
    keyword_trigger.rb          # Farewell detection ✅
    silence_trigger.rb          # Timeout detection ✅
    request_capture.rb          # Hey garbo... ✅

test/
  trigger_test.rb               # ✅
  trigger_manager_test.rb       # ✅
  triggers/
    keyword_trigger_test.rb     # ✅
    silence_trigger_test.rb     # ✅
    request_capture_test.rb     # ✅
```

All tests passing: 103 runs, 491 assertions, 0 failures

---

## Usage Examples

### Basic Setup

```ruby
require_relative 'lib/triggers'

# Create manager
manager = TriggerManager.new

# Add triggers
manager.add(KeywordTrigger.new(action: :hangup))  # Default farewell patterns
manager.add(SilenceTrigger.new(timeout: 10, action: :hangup))
manager.add(RequestCapture.new(action: :delegate))

# Register callbacks
manager.on(:hangup) do |context|
  puts "Hanging up because: #{context[:reason]}"
  sip_client.hangup
end

manager.on(:delegate) do |context, request_text|
  puts "Delegating to AI: #{request_text}"
  ai_assistant.process(request_text)
end
```

### Check Context (call during voice events)

```ruby
# On user transcript received
manager.check(
  transcript: "Goodbye, talk to you later!",
  role: :user
)
# => Fires :hangup callback

# On silence timeout check (periodic poll)
manager.check(
  last_response_at: @last_response_at,
  is_speaking: @is_speaking
)
# => Fires :hangup if silence exceeded

# On "hey garbo" request
manager.check(
  transcript: "Hey Garbo, send a text to mom",
  role: :user
)
# => Fires :delegate callback with "send a text to mom"
```

### Custom Triggers

```ruby
# Custom keyword trigger
manager.add(KeywordTrigger.new(
  patterns: %w[help emergency sos],
  action: :alert,
  role: :user
))

# Custom silence with longer timeout
manager.add(SilenceTrigger.new(
  timeout: 30,
  action: :prompt_user
))

# Custom wake phrase
manager.add(RequestCapture.new(
  prefix: /hey\s+assistant[,.]?\s*/i,
  action: :forward
))
```
