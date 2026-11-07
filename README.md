# Pro-market-desk-signals

The daily signal feed from **Market Desk Pro** (Claude) for the **CEA4** MT5 EA.

Every Market Desk Pro analysis run (the Analyze button, or a scheduled run) also commits a small signal file here. The EA reads it to decide **which pairs it may trade today, in which direction, and when not to enter**. Claude never sets prices, lots or stops; those stay in the EA.

```
signals/latest.txt            <- the file the EA reads
signals/latest.json           <- same signal, plus the headline, for people and tools
signals/history/YYYY-MM-DD_HHMM.txt   <- every signal ever published (UTC time)
mql5/Include/ClaudeSignal.mqh <- drop-in module for CEA4
mql5/Experts/ClaudeSignalMonitor.mq5  <- test EA: shows the signal, never trades
docs/CEA4-integration.md      <- how to wire the module into CEA4
```

## Signal file format (`signals/latest.txt`, version 1)

Plain `key=value` lines, all times in **UTC**. The file must end with `end=1`; the EA rejects a file without it.

```
version=1
generated_utc=2026-11-06T05:15:00Z
valid_until_utc=2026-11-06T17:15:00Z
mood=risk-off
max_trades=3
allow=GBPNZD,LONG
allow=NZDCHF,SHORT
allow=AUDCHF,SHORT
backup=GBPAUD,LONG
strength=GBPNZD,LONG
strength=GBPJPY,LONG
strength=NZDCAD,SHORT
strength=CADJPY,LONG
bias=EURJPY,SHORT
bias=AUDNZD,LONG
blackout=2026-11-06T13:15:00Z,2026-11-06T13:45:00Z,USD
end=1
```

| Key | Group | Meaning |
|---|---|---|
| `allow` | Top 3 | Claude's three picks: symbol (6 letters, no broker suffix) and `LONG` or `SHORT`. 0–3 lines. |
| `backup` | Backup | Optional 4th pick. Used only if `UseBackup` is on. |
| `strength` | Strength | The 2 strongest currencies crossed with the 2 weakest on the strength meter (up to 4 pairs), long the strong side. |
| `bias` | Bias | Pairs ranked No edge, Avoid or Excluded that still carry a Long or Short bias. |
| `blackout` | all | No new entries for pairs containing that currency between the two times. `ALL` blocks everything. |
| `valid_until_utc` | all | After this the EA opens nothing until a new signal arrives. |
| `max_trades` | Top 3 | Daily cap the analysis recommends for the Top 3 (never above 3). |

Priority when a pair is in more than one group: Top 3 > Backup > Strength > Bias. If two groups list the same pair in **opposite** directions, the pair is not traded that day.

Older EAs that only know `allow`/`backup` ignore the `strength` and `bias` lines.

## Safety rules built into `ClaudeSignal.mqh`

- **Fail closed:** missing, stale, half-written or malformed file means no new trades.
- **Validation:** unknown currencies, bad directions, more than 3 picks, future timestamps or a validity window over 30 hours reject the whole file; the previous good signal is kept.
- **Strategy Tester:** WebRequest does not work there, so the filter passes everything through and says so in the log. Backtests of CEA4 are unaffected.
- **Cache:** the last good file is kept in the MT5 Common Files folder, so a restart doesn't wait for the next fetch (freshness rules still apply).

## Setup in MT5

1. **Tools → Options → Expert Advisors → Allow WebRequest for listed URL**, add `https://raw.githubusercontent.com`.
2. Copy `mql5/Include/ClaudeSignal.mqh` to `MQL5/Include/` and `mql5/Experts/ClaudeSignalMonitor.mq5` to `MQL5/Experts/`.
3. Compile and attach **ClaudeSignalMonitor** to any chart. The top-left corner shows the current signal and whether that chart's symbol is allowed.
4. When the monitor shows `ACTIVE`, wire the module into CEA4 (see `docs/CEA4-integration.md`) and run it on a **demo account** first.

If this repo is made private later, create a fine-grained GitHub token with read-only **Contents** access to this repo only and paste it into the `GithubToken` input.
