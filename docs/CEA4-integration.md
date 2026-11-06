# Wiring ClaudeSignal into CEA4

The module adds one gate in front of CEA4's existing entry logic. Nothing else in CEA4 changes: order-block detection, SL/TP, lot sizing and the three-layer risk governor all stay as they are.

## 1. Include and inputs (top of CEA4.mq5)

```mql5
#include <ClaudeSignal.mqh>

input group "=== Claude daily filter ==="
input bool   InpUseClaudeFilter  = true;           // Only trade Claude's daily picks
input string InpClaudeUrl        = CS_DEFAULT_URL; // Signal file URL
input int    InpClaudeRefreshMin = 5;              // Refresh every N minutes
input int    InpClaudeMaxAgeH    = 14;             // Ignore signals older than N hours
input bool   InpClaudeUseBackup  = false;          // Also allow the backup pair
input string InpClaudeToken      = "";             // GitHub token (only if repo is private)

CClaudeSignal g_claude;
```

## 2. OnInit

```mql5
g_claude.Init(InpUseClaudeFilter, InpClaudeUrl, InpClaudeRefreshMin,
              InpClaudeMaxAgeH, InpClaudeUseBackup, InpClaudeToken);
EventSetTimer(30);   // skip if CEA4 already runs a timer; just add the Refresh call below
```

## 3. OnTimer

```mql5
g_claude.Refresh();   // fetches at most every InpClaudeRefreshMin minutes
```

If CEA4 has no `OnTimer`, calling `g_claude.Refresh()` at the start of `OnTick` is fine too; it returns immediately between refreshes. (`WebRequest` blocks for up to 5 s, so the timer is preferred.)

## 4. The gate: in CEA4's per-symbol entry check

Put this **after** CEA4 has decided a setup is valid and **before** it sends the order. CEA4 is a multi-symbol basket EA, so pass the basket symbol being evaluated, not `_Symbol`:

```mql5
// dir: CS_DIR_LONG for buys, CS_DIR_SHORT for sells
if(!g_claude.IsAllowed(sym, isBuy ? CS_DIR_LONG : CS_DIR_SHORT))
  {
   // optional: log once per bar, not every tick
   return;   // or: continue; inside CEA4's symbol loop
  }
```

For pending orders there is a shortcut: `g_claude.IsAllowedOrder(sym, ORDER_TYPE_BUY_LIMIT)`.

`IsAllowed` already checks freshness and news blackouts. Use `g_claude.InBlackout(sym, TimeGMT())` separately only if you want CEA4 to also **manage open trades** around news (e.g. move to break-even before a release).

## 5. Daily trade cap

CEA4's risk governor should keep owning trade counts. To respect Claude's cap as well:

```mql5
int cap = MathMin(YourExistingDailyCap, g_claude.MaxTrades());
```

## 6. Chart status (optional)

```mql5
Comment(g_claude.Status());
```

## What to check on demo

- The log shows `ClaudeSignal: new signal ...` after each Market Desk Pro run.
- Trades only open on the listed pairs, in the listed direction, outside blackouts.
- With the internet off or the file stale, CEA4 opens nothing new (open trades are still managed).
- Keep a simple journal: date, signal, trades taken, result. After a few weeks compare against CEA4 running unfiltered on a second demo to see whether the filter adds an edge.
