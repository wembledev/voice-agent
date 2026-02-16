# SIP Client

The SIP client handles phone call signaling and audio transport — registering with the VoIP provider, placing/receiving calls, and streaming G.711 audio.

## Interface

```ruby
client = SipClient::Baresip.new
client.status                      # Check registration
client.call("5550100")          # Dial a number
client.calls                       # List active calls
client.hangup                      # End call
```

## Current: baresip

- **Implementation:** `lib/sip_client/baresip.rb`
- **Control:** TCP socket (netstring-encoded JSON) on port 4444
- **Audio codec:** G.711 μ-law (PCMU) 8kHz
- **Runtime config:** Auto-generated in `tmp/baresip/` from Config
- **Config:** `sip.ctrl_port` and `sip.module_path` in `config/default.yml`, SIP credentials in `.env.local`

### baresip ctrl_tcp Protocol

Commands sent as netstring-encoded JSON:

```
<length>:{"command":"<cmd>","params":"<args>"},
```

| Command | Params | Description |
|---------|--------|-------------|
| `reginfo` | | Registration status |
| `listcalls` | | Active calls |
| `dial` | SIP URI | Place a call |
| `hangup` | | End active call |

**Note:** Commands use bare names — no `/` prefix (baresip v4.5.0).

### Docs

- **Source:** https://github.com/baresip/baresip
- **Modules:** https://github.com/baresip/baresip/tree/main/modules

## Adding a New SIP Client

Create a subclass of `SipClient`:

```ruby
class SipClient::Pjsua < SipClient
  def call(number, **opts) = # ...
  def status = # ...
  def hangup = # ...
  def calls = # ...
end
```
