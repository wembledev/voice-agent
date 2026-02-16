# SMS Integration for garbo-voice-agent

## Overview
Send and receive SMS messages using the voip.ms API from within garbo-voice-agent.

## Quick Start

### Send SMS via CLI:
```bash
cd ~/Projects/garbo-voice-agent
bin/sms 5550100 "Hello from Garbo!"
```

### Send SMS from Ruby code:
```ruby
require_relative 'lib/sms'

sms = SMS.from_env

# Send a message
sms.send(to: '5550100', message: 'Hello!')

# Get recent messages
recent = sms.get_recent(limit: 5)
recent.each do |msg|
  puts "From: #{msg['contact']}"
  puts "Message: #{msg['message']}"
  puts "Date: #{msg['date']}"
end
```

## Use Cases

### During a voice call:
```ruby
# In CallSession or agent code
sms = SMS.from_env
sms.send(
  to: '5550100',
  message: 'Call transcript will be emailed in 5 minutes'
)
```

### Voice agent delegation:
When caller asks to "send a text to Mike", the voice agent can:
1. Capture the message via speech
2. Use SMS.from_env to send it
3. Confirm to caller: "Message sent!"

### Automated notifications:
```ruby
# Send transcript after call
def send_transcript_notification(transcript_path)
  sms = SMS.from_env
  sms.send(
    to: '5550100',
    message: "Call transcript ready: #{transcript_path}"
  )
end
```

## Configuration

Environment variables (in `.env.local`):
```env
VOIPMS_API_USERNAME=you@example.com
VOIPMS_API_PASSWORD=your_password
VOIPMS_DID=5550100
```

## API Methods

### SMS#send(to:, message:)
Send an SMS message.

**Parameters:**
- `to` (String) - Phone number (with or without formatting)
- `message` (String) - Message content

**Returns:** Hash with `status` and `sms` (message ID)

**Raises:** `SMS::Error` if sending fails

### SMS#get_recent(limit: 10, type: 1)
Get recent SMS messages.

**Parameters:**
- `limit` (Integer) - Number of messages (default: 10)
- `type` (Integer) - 1=received, 2=sent (default: 1)

**Returns:** Array of message hashes

### SMS.from_env
Create client from environment variables.

**Returns:** SMS instance

## Integration with Voice Calls

Future enhancements:
- Add SMS capability to CallSession
- Allow voice agent to send texts during calls
- Auto-send transcripts via SMS
- SMS-based delegation responses

## Security

SMS sending uses the same voip.ms credentials as voice calls.
Use contact permissions system to control who can trigger SMS sends.

## Examples

### Send a quick update:
```bash
bin/sms 5550100 "Message sent successfully! 🎉"
```

### Check for new messages:
```ruby
sms = SMS.from_env
messages = sms.get_recent(limit: 5)
messages.each do |msg|
  puts "#{msg['date']} - #{msg['contact']}: #{msg['message']}"
end
```

### Respond to a message:
```ruby
sms = SMS.from_env
recent = sms.get_recent(limit: 1).first
sms.send(
  to: recent['contact'],
  message: "Thanks for your message!"
)
```
