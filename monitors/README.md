# Garbo Voice Agent Monitoring

Shell-based monitors for garbo-voice-agent. Zero-token monitoring: run checks via system cron, only spawn LLM sessions when alerts are needed.

## Why Shell Monitors?

**Problem:** OpenClaw isolated cron jobs load full workspace context (50KB = 12,500 tokens) on every run.

**Old approach (expensive):**
```
Every 5 min → Spawn isolated session → Load AGENTS.md, SOUL.md, USER.md, MEMORY.md, TOOLS.md 
  → Run curl command → "Nothing new" → Exit
= 3.6M tokens/day per monitor
```

**New approach (efficient):**
```
Every 5 min → Shell script checks directly → Nothing new → Exit silently
              OR
              New data → Spawn OpenClaw session with alert → Telegram notification
= ~0 tokens/day (only on alerts)
```

**Savings:** 3.6M tokens/day → ~0 tokens/day

---

## Monitor Script

### `monitor` - Consolidated Voice Agent Monitor
- **Frequency:** Every 5 minutes (recommended)
- **Checks:**
  - **SMS:** voip.ms API for new messages to 604-998-8013
  - **Calls:** voip.ms call logs for missed calls (throttled to 10 min)
  - **Zombies:** Defunct/orphaned bin/call, baresip, Ghostty processes
- **State files:** `~/clawd/state/{sms,calls}-last-check.txt`
- **Actions:**
  - New SMS → Spawns Haiku session → announces to Telegram
  - Missed call → Spawns Haiku session → announces caller & time
  - Zombie found → Kills process silently (logs to file)

**APIs:**
- `https://voip.ms/api/v1/rest.php?method=getSMS&did=5550100`
- `https://voip.ms/api/v1/rest.php?method=getCallAccounts`

---

## Installation

### System Crontab

```bash
# Add to system crontab
crontab -e

# Add this line (adjust path if garbo-voice-agent is elsewhere)
*/5 * * * * ~/Projects/garbo-voice-agent/monitors/monitor >> ~/clawd/logs/monitor-voice.log 2>&1
```

### Manual Test

```bash
# Ensure script is executable
chmod +x ~/Projects/garbo-voice-agent/monitors/monitor

# Run manually to test
~/Projects/garbo-voice-agent/monitors/monitor

# Check logs
tail -f ~/clawd/logs/monitor-voice.log
```

---

## How It Works

### Architecture

```
System Cron (every 5 min)
  ↓
monitors/monitor
  ↓
  ├─ SMS Check → voip.ms API
  │    ↓
  │    ├─ New messages → Spawn OpenClaw Haiku session → Telegram alert
  │    └─ No new → Update timestamp, exit silently
  │
  ├─ Call Check (every 10 min) → voip.ms API
  │    ↓
  │    ├─ Missed calls → Spawn OpenClaw Haiku session → Telegram alert
  │    └─ No missed → Update timestamp, exit silently
  │
  └─ Zombie Check → ps aux
       ↓
       ├─ Zombies found → kill -9, log to file
       └─ None → Exit silently
```

### OpenClaw Integration

```bash
GATEWAY_TOKEN=$(jq -r '.gateway.auth.token' ~/.openclaw/openclaw.json)

curl -s -X POST http://localhost:18789/sessions/spawn \
  -H "Authorization: Bearer $GATEWAY_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "task": "New SMS messages received. Fetch and announce to Mike.",
    "model": "haiku",
    "cleanup": "delete"
  }'
```

**No workspace context loaded** until the spawn happens (only on alerts).

---

## Zombie Process Detection

The monitor kills:

1. **Defunct zombies** - Process state `Z` or `defunct`
2. **Orphaned baresip** - baresip with no parent bin/call
3. **Stuck bin/call** - Elapsed >10 min with <5s CPU time
4. **Orphaned Ghostty** - >1hr old with no child processes

**Why kill zombies?**
- Voice calls can crash/hang leaving orphaned processes
- baresip doesn't always clean up properly on SIGTERM
- Prevents resource leaks and port conflicts

**Safety:**
- Only kills garbo-voice-agent related processes
- Checks parent-child relationships before killing
- Logs all kills to monitor-voice.log

---

## Adding More Checks

### Template

```bash
# ============================================================================
# New Check Name
# ============================================================================
NEW_STATE="$STATE_DIR/new-check-last-check.txt"
LAST_CHECK=$(cat "$NEW_STATE" 2>/dev/null || echo "0")

# Do your check here
RESULT=$(command-to-check)

if [ condition-met ]; then
  echo "[NEW_CHECK] Alert triggered: $RESULT"
  curl -s -X POST "$SPAWN_URL" \
    -H "Authorization: Bearer $GATEWAY_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"task\": \"Alert: $RESULT\", \"model\": \"haiku\", \"cleanup\": \"delete\"}"
fi

date +%s > "$NEW_STATE"
```

### Best Practices

1. **Silent by default** - only output when action needed
2. **Use state files** - track last check in `~/clawd/state/`
3. **Spawn on alert only** - let OpenClaw handle formatting
4. **Log clearly** - prefix output with `[SECTION_NAME]`
5. **Cleanup:** Always `"cleanup": "delete"` for one-shot alerts

---

## Logs

Monitor writes to `~/clawd/logs/monitor-voice.log`:

```bash
# Watch in real-time
tail -f ~/clawd/logs/monitor-voice.log

# Check recent runs
tail -100 ~/clawd/logs/monitor-voice.log

# Check for zombies killed
grep ZOMBIES ~/clawd/logs/monitor-voice.log
```

**Log rotation:** Not configured - logs grow indefinitely. Add logrotate if needed.

---

## Troubleshooting

### Monitor not running
```bash
# Check crontab
crontab -l | grep monitor

# Check if script is executable
ls -la ~/Projects/garbo-voice-agent/monitors/monitor

# Test manually
~/Projects/garbo-voice-agent/monitors/monitor
```

### OpenClaw spawn failing
```bash
# Check gateway is running
curl http://localhost:18789/health

# Verify token
jq -r '.gateway.auth.token' ~/.openclaw/openclaw.json

# Check gateway logs
tail -100 ~/.openclaw/logs/gateway.log | grep spawn
```

### No SMS/call alerts
```bash
# Test voip.ms API directly
curl "https://voip.ms/api/v1/rest.php?api_username=you@example.com&api_password=YOUR_PASSWORD&method=getSMS&did=5550100&content_type=json"

# Check state files
cat ~/clawd/state/sms-last-check.txt
cat ~/clawd/state/calls-last-check.txt

# Force reset (will alert on next run if messages exist)
rm ~/clawd/state/{sms,calls}-last-check.txt
```

---

## Token Comparison

| Approach | Frequency | Context Load | Tokens/Run | Runs/Day | Total/Day |
|----------|-----------|--------------|------------|----------|-----------|
| **Old (Isolated cron)** | 5 min | 50KB | 12,500 | 288 | 3.6M |
| **New (Shell monitor)** | 5 min | 0 | 0 | 288 | 0 |
| **On alert (Haiku spawn)** | As needed | 50KB | 12,500 | ~1-5 | ~12k-60k |

**Net savings:** 3.6M tokens/day → ~50k tokens/day (assuming 5 alerts/day)
