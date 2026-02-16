# VoIP Provider

The VoIP provider connects the system to the phone network (PSTN) — managing phone numbers (DIDs), SIP accounts, and call routing.

## Interface

```ruby
api = VoipProvider::Voipms.new     # Reads credentials from ENV
api.balance                        # Account balance
api.dids                           # Phone numbers
api.sub_accounts                   # SIP accounts
api.servers                        # Available SIP servers
```

## Current: voip.ms

- **Implementation:** `lib/voip_provider/voipms.rb`
- **Protocol:** REST API (GET requests, JSON responses)
- **SIP server:** vancouver1.voip.ms (POP 16)
- **DID:** Set via `VOIPMS_DID` in `.env.local`
- **Account:** Set via `SIP_USERNAME` in `.env.local`
- **Config:** Provider selection in `config/default.yml`, `VOIPMS_*` secrets in `.env.local`

### Key Concepts

| Concept | Description |
|---------|-------------|
| **DID** | Phone number (Direct Inward Dial) |
| **POP** | Point of Presence — the server handling calls for a DID |
| **Sub-account** | SIP account for registration and calling |
| **SIP server** | Where the sub-account registers (must match DID POP) |

### Server Notes

- DID and SIP account should use the same POP (server)
- ca.voip.ms (POP 105) is DID routing only — not for SIP registration
- Use regional servers (vancouver1, toronto1, etc.) for SIP registration

### Docs

- **API Reference:** https://voip.ms/m/apidocs.php
- **Wiki:** https://wiki.voip.ms

## Adding a New VoIP Provider

Create a subclass of `VoipProvider`:

```ruby
class VoipProvider::Twilio < VoipProvider
  def balance = # ...
  def phone_numbers = # ...
  def registrations = # ...
end
```
