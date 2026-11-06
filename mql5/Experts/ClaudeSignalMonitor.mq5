//+------------------------------------------------------------------+
//| ClaudeSignalMonitor.mq5                                          |
//| Test EA: reads the Market Desk Pro signal and shows it on the    |
//| chart. It NEVER places trades. Use it to check the connection    |
//| before wiring ClaudeSignal.mqh into CEA4.                        |
//+------------------------------------------------------------------+
#property copyright "Market Desk Pro"
#property version   "1.00"
#property description "Displays the Claude signal for this chart's symbol. Places no trades."

#include <ClaudeSignal.mqh>

input string InpSignalUrl      = CS_DEFAULT_URL; // Signal file URL
input int    InpRefreshMinutes = 5;              // Refresh every N minutes
input int    InpMaxAgeHours    = 14;             // Ignore signals older than N hours
input bool   InpUseBackup      = false;          // Allow the backup pair too
input string InpGithubToken    = "";             // Only needed if the repo is private

CClaudeSignal g_claude;

int OnInit()
  {
   g_claude.Init(true, InpSignalUrl, InpRefreshMinutes, InpMaxAgeHours, InpUseBackup, InpGithubToken);
   EventSetTimer(30);
   Draw();
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   EventKillTimer();
   Comment("");
  }

void OnTimer()
  {
   g_claude.Refresh();
   Draw();
  }

void Draw()
  {
   string sym = _Symbol;
   string verdict;
   if(g_claude.IsAllowed(sym, CS_DIR_LONG))       verdict = "LONG allowed";
   else if(g_claude.IsAllowed(sym, CS_DIR_SHORT)) verdict = "SHORT allowed";
   else if(g_claude.InBlackout(sym, TimeGMT()))   verdict = "BLOCKED: news blackout";
   else                                          verdict = "not on today's list";
   Comment(g_claude.Status(), "\n", CClaudeSignal::CodeOf(sym), " (", sym, "): ", verdict);
  }
