//+------------------------------------------------------------------+
//| ClaudeSignal.mqh                                                 |
//| Reads the Market Desk Pro signal file and answers:               |
//|   GroupFor(symbol, dir, ...)    - which signal group allows it?  |
//|   IsAllowed(symbol, direction)  - Top 3 (+backup) only, as v1    |
//|   InBlackout(symbol, gmtTime)   - is this a news no-entry window?|
//|                                                                  |
//| Signal groups                                                    |
//|   TOP 3    allow=    Claude's three picks                        |
//|   BACKUP   backup=   Claude's fourth pick                        |
//|   STRENGTH strength= 2 strongest x 2 weakest currencies (4 pairs)|
//|   BIAS     bias=     No edge / Avoid / Excluded pairs that still |
//|                      carry a Long or Short bias                  |
//|   A pair listed in two groups with opposite directions is never  |
//|   traded (conflict = stand aside).                               |
//|                                                                  |
//| Design rules                                                     |
//|  * Fail closed: no file, stale file or bad file => no new trades.|
//|  * Claude only filters. Entries, SL/TP and lots stay in the EA.  |
//|  * Strategy Tester has no WebRequest: the filter passes through  |
//|    there (with a log line) so CEA4 backtests are unaffected.     |
//|                                                                  |
//| Source: github.com/1JTheo/Pro-market-desk-signals                |
//+------------------------------------------------------------------+
#ifndef CLAUDE_SIGNAL_MQH
#define CLAUDE_SIGNAL_MQH

#define CS_DEFAULT_URL "https://raw.githubusercontent.com/1JTheo/Pro-market-desk-signals/main/signals/latest.txt"
#define CS_MAX_ALLOW    3
#define CS_MAX_BACKUP   1
#define CS_MAX_STRENGTH 4
#define CS_MAX_BIAS     30
#define CS_MAX_BLACKOUT 60
#define CS_MAX_VALID_H  30

#define CS_DIR_LONG   1
#define CS_DIR_SHORT -1

#define CS_GROUP_NONE     0
#define CS_GROUP_TOP      1
#define CS_GROUP_BACKUP   2
#define CS_GROUP_STRENGTH 3
#define CS_GROUP_BIAS     4

struct SClaudeAllow
  {
   string            code;     // e.g. "GBPNZD"
   int               dir;      // CS_DIR_LONG / CS_DIR_SHORT
   bool              backup;   // true for the backup pick
   int               group;    // CS_GROUP_*
  };

struct SClaudeBlackout
  {
   datetime          fromGmt;
   datetime          toGmt;
   string            ccy;      // "USD", "AUD"... or "ALL"
  };

class CClaudeSignal
  {
private:
   // settings
   bool              m_enabled;
   bool              m_passThrough;     // tester or filter switched off
   string            m_url;
   string            m_token;
   int               m_refreshSec;
   int               m_maxAgeHours;
   bool              m_useBackup;
   int               m_timeoutMs;
   string            m_cacheFile;
   // state
   bool              m_loaded;
   datetime          m_generated;
   datetime          m_validUntil;
   string            m_mood;
   int               m_maxTrades;
   SClaudeAllow      m_allow[];
   SClaudeBlackout   m_black[];
   datetime          m_lastFetch;
   datetime          m_lastOk;
   string            m_lastError;

   //--- helpers
   static string     Trim(string s) { StringTrimLeft(s); StringTrimRight(s); return s; }

   static datetime   IsoToTime(string iso)
     {
      // "2026-11-06T13:15:00Z" -> 2026.11.06 13:15:00 (GMT)
      iso = Trim(iso);
      if(StringLen(iso) < 16) return 0;
      StringReplace(iso, "Z", "");
      StringReplace(iso, "T", " ");
      StringReplace(iso, "-", ".");
      return StringToTime(iso);
     }

   static string     TimeIso(datetime t)
     {
      string s = TimeToString(t, TIME_DATE | TIME_MINUTES);
      StringReplace(s, ".", "-");
      return s + "Z";
     }

   static bool       IsUpperCode(const string s, const int len)
     {
      if(StringLen(s) != len) return false;
      for(int i = 0; i < len; i++)
        {
         ushort c = StringGetCharacter(s, i);
         if(c < 'A' || c > 'Z') return false;
        }
      return true;
     }

   static bool       IsCcy(const string c)
     {
      return (c=="USD"||c=="EUR"||c=="GBP"||c=="JPY"||c=="CHF"||c=="CAD"||c=="AUD"||c=="NZD"||c=="XAU"||c=="XAG");
     }

   bool              Fetch(string &text, string &err)
     {
      char   body[];
      char   result[];
      string resHeaders;
      string headers = "Cache-Control: no-cache\r\nUser-Agent: CEA4-ClaudeSignal\r\n";
      if(m_token != "")
         headers += "Authorization: token " + m_token + "\r\n";
      string url = m_url + (StringFind(m_url, "?") >= 0 ? "&" : "?") + "t=" + IntegerToString((long)TimeGMT());
      ResetLastError();
      int code = WebRequest("GET", url, headers, m_timeoutMs, body, result, resHeaders);
      if(code == -1)
        {
         int e = GetLastError();
         if(e == 4014)
            err = "WebRequest blocked: add https://raw.githubusercontent.com in Tools > Options > Expert Advisors > Allow WebRequest";
         else
            err = "WebRequest error " + IntegerToString(e);
         return false;
        }
      if(code != 200)
        {
         err = "HTTP " + IntegerToString(code) + " from signal URL";
         return false;
        }
      text = CharArrayToString(result, 0, WHOLE_ARRAY, CP_UTF8);
      return true;
     }

   //--- parse into locals; commit only if the whole file is valid
   bool              Parse(const string text, string &err)
     {
      string lines[];
      int n = StringSplit(text, '\n', lines);
      if(n <= 0) { err = "empty file"; return false; }

      int      version = 0;
      bool     ended = false;
      datetime gen = 0, valid = 0;
      string   mood = "";
      int      maxTrades = 3;
      SClaudeAllow    al[];
      SClaudeBlackout bl[];
      int nAllow = 0, nBackup = 0, nBlack = 0, nStrength = 0, nBias = 0;

      for(int i = 0; i < n; i++)
        {
         string ln = Trim(lines[i]);
         StringReplace(ln, "\r", "");
         if(ln == "" || StringGetCharacter(ln, 0) == '#') continue;
         int eq = StringFind(ln, "=");
         if(eq <= 0) { err = "bad line " + IntegerToString(i + 1); return false; }
         string key = Trim(StringSubstr(ln, 0, eq));
         string val = Trim(StringSubstr(ln, eq + 1));

         if(key == "version")              version = (int)StringToInteger(val);
         else if(key == "generated_utc")   gen = IsoToTime(val);
         else if(key == "valid_until_utc") valid = IsoToTime(val);
         else if(key == "mood")            mood = val;
         else if(key == "max_trades")      maxTrades = (int)StringToInteger(val);
         else if(key == "end")             ended = (val == "1");
         else if(key == "allow" || key == "backup" || key == "strength" || key == "bias")
           {
            string p[];
            if(StringSplit(val, ',', p) != 2) { err = "bad " + key + " line"; return false; }
            string code = Trim(p[0]); StringToUpper(code);
            string d    = Trim(p[1]); StringToUpper(d);
            if(!IsUpperCode(code, 6) || !IsCcy(StringSubstr(code, 0, 3)) || !IsCcy(StringSubstr(code, 3, 3)))
              { err = "bad symbol " + code; return false; }
            int dir = (d == "LONG" ? CS_DIR_LONG : (d == "SHORT" ? CS_DIR_SHORT : 0));
            if(dir == 0) { err = "bad direction " + d; return false; }
            int grp = (key == "allow" ? CS_GROUP_TOP : key == "backup" ? CS_GROUP_BACKUP
                       : key == "strength" ? CS_GROUP_STRENGTH : CS_GROUP_BIAS);
            if(grp == CS_GROUP_TOP) nAllow++;
            else if(grp == CS_GROUP_BACKUP) nBackup++;
            else if(grp == CS_GROUP_STRENGTH) nStrength++;
            else nBias++;
            int k = ArraySize(al);
            ArrayResize(al, k + 1);
            al[k].code = code; al[k].dir = dir; al[k].backup = (grp == CS_GROUP_BACKUP); al[k].group = grp;
           }
         else if(key == "blackout")
           {
            string p[];
            if(StringSplit(val, ',', p) != 3) { err = "bad blackout line"; return false; }
            datetime f = IsoToTime(p[0]), t = IsoToTime(p[1]);
            string c = Trim(p[2]); StringToUpper(c);
            if(f == 0 || t <= f || (c != "ALL" && !IsCcy(c))) { err = "bad blackout values"; return false; }
            int k = ArraySize(bl);
            ArrayResize(bl, k + 1);
            bl[k].fromGmt = f; bl[k].toGmt = t; bl[k].ccy = c;
            nBlack++;
           }
         // unknown keys are ignored so the format can grow
        }

      if(version != 1)                   { err = "unsupported version"; return false; }
      if(!ended)                         { err = "file incomplete (no end=1)"; return false; }
      if(gen == 0 || valid == 0)         { err = "missing timestamps"; return false; }
      if(gen > TimeGMT() + 600)          { err = "generated time is in the future"; return false; }
      if(valid <= gen || valid - gen > CS_MAX_VALID_H * 3600) { err = "bad validity window"; return false; }
      if(nAllow > CS_MAX_ALLOW || nBackup > CS_MAX_BACKUP)    { err = "too many pairs"; return false; }
      if(nStrength > CS_MAX_STRENGTH || nBias > CS_MAX_BIAS)  { err = "too many strength/bias pairs"; return false; }
      if(nBlack > CS_MAX_BLACKOUT)       { err = "too many blackouts"; return false; }
      if(maxTrades < 0 || maxTrades > 3) maxTrades = 3;

      // commit
      m_generated  = gen;
      m_validUntil = valid;
      m_mood       = mood;
      m_maxTrades  = maxTrades;
      int na = ArraySize(al), nb = ArraySize(bl);
      ArrayResize(m_allow, na);
      for(int j = 0; j < na; j++)
        { m_allow[j].code = al[j].code; m_allow[j].dir = al[j].dir; m_allow[j].backup = al[j].backup; m_allow[j].group = al[j].group; }
      ArrayResize(m_black, nb);
      for(int j = 0; j < nb; j++)
        { m_black[j].fromGmt = bl[j].fromGmt; m_black[j].toGmt = bl[j].toGmt; m_black[j].ccy = bl[j].ccy; }
      m_loaded = true;
      return true;
     }

   void              SaveCache(const string text)
     {
      int h = FileOpen(m_cacheFile, FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_COMMON);
      if(h == INVALID_HANDLE) return;
      FileWriteString(h, text);
      FileClose(h);
     }

   bool              LoadCache(string &text)
     {
      if(!FileIsExist(m_cacheFile, FILE_COMMON)) return false;
      int h = FileOpen(m_cacheFile, FILE_READ | FILE_TXT | FILE_ANSI | FILE_COMMON);
      if(h == INVALID_HANDLE) return false;
      text = "";
      while(!FileIsEnding(h)) text += FileReadString(h) + "\n";
      FileClose(h);
      return (text != "");
     }

public:
                     CClaudeSignal(void)
     {
      m_enabled = true; m_passThrough = false; m_url = CS_DEFAULT_URL; m_token = "";
      m_refreshSec = 300; m_maxAgeHours = 14; m_useBackup = false; m_timeoutMs = 5000;
      m_cacheFile = "ClaudeSignal_cache.txt";
      m_loaded = false; m_generated = 0; m_validUntil = 0; m_mood = ""; m_maxTrades = 3;
      m_lastFetch = 0; m_lastOk = 0; m_lastError = "";
     }

   //--- call once in OnInit
   void              Init(const bool enabled, const string url = CS_DEFAULT_URL, const int refreshMinutes = 5,
                          const int maxAgeHours = 14, const bool useBackup = false, const string token = "")
     {
      m_enabled     = enabled;
      m_url         = (url == "" ? CS_DEFAULT_URL : url);
      m_refreshSec  = (refreshMinutes * 60 < 60 ? 60 : refreshMinutes * 60);
      m_maxAgeHours = (maxAgeHours < 1 ? 1 : maxAgeHours);
      m_useBackup   = useBackup;
      m_token       = token;
      m_passThrough = !enabled || (bool)MQLInfoInteger(MQL_TESTER) || (bool)MQLInfoInteger(MQL_OPTIMIZATION);
      if(enabled && m_passThrough)
         Print("ClaudeSignal: Strategy Tester detected, filter passes all trades (WebRequest is unavailable in the tester).");
      if(m_passThrough) return;

      string cached;
      string err;
      if(LoadCache(cached) && Parse(cached, err))
         Print("ClaudeSignal: loaded cached signal from ", TimeIso(m_generated));
      Refresh(true);
     }

   //--- call from OnTimer (cheap: fetches at most every refreshMinutes)
   void              Refresh(const bool force = false)
     {
      if(m_passThrough) return;
      datetime now = TimeGMT();
      if(!force && now - m_lastFetch < m_refreshSec) return;
      m_lastFetch = now;

      string text, err;
      if(!Fetch(text, err)) { m_lastError = err; Print("ClaudeSignal: ", err); return; }

      datetime prevGen = m_generated;
      if(!Parse(text, err))
        {
         m_lastError = "rejected file: " + err;
         Print("ClaudeSignal: ", m_lastError, " (keeping previous signal)");
         return;
        }
      m_lastOk = now;
      m_lastError = "";
      SaveCache(text);
      if(m_generated != prevGen)
         Print("ClaudeSignal: new signal ", TimeIso(m_generated), " | ", AllowList(), " | valid to ", TimeIso(m_validUntil));
     }

   //--- is the current signal usable?
   bool              IsFresh(void) const
     {
      if(m_passThrough) return true;
      if(!m_loaded) return false;
      datetime now = TimeGMT();
      return (now < m_validUntil && now - m_generated <= m_maxAgeHours * 3600);
     }

   //--- "GBPNZD.a" / "m.GBPNZD" / "GBPNZDm" -> "GBPNZD"
   static string     CodeOf(const string symbol)
     {
      string s = symbol;
      StringToUpper(s);
      int len = StringLen(s);
      for(int i = 0; i + 6 <= len; i++)
        {
         string a = StringSubstr(s, i, 3), b = StringSubstr(s, i + 3, 3);
         if(IsCcy(a) && IsCcy(b) && a != b) return a + b;
        }
      return s;
     }

   //--- news no-entry window for this symbol?
   bool              InBlackout(const string symbol, const datetime gmt) const
     {
      if(m_passThrough) return false;
      string code = CodeOf(symbol);
      for(int i = 0; i < ArraySize(m_black); i++)
        {
         if(gmt < m_black[i].fromGmt || gmt > m_black[i].toGmt) continue;
         if(m_black[i].ccy == "ALL" || StringFind(code, m_black[i].ccy) >= 0) return true;
        }
      return false;
     }

   //--- news ahead for an OPEN position: true if a blackout covering this
   //    symbol is active now or starts within leadSec. fromOut = that
   //    blackout's start (lets the EA act once per news event).
   bool              BlackoutSoon(const string symbol, const datetime gmt, const int leadSec, datetime &fromOut) const
     {
      fromOut = 0;
      if(m_passThrough || !m_loaded) return false;
      string code = CodeOf(symbol);
      for(int i = 0; i < ArraySize(m_black); i++)
        {
         if(m_black[i].ccy != "ALL" && StringFind(code, m_black[i].ccy) < 0) continue;
         if(gmt > m_black[i].toGmt) continue;                       // already over
         if(m_black[i].fromGmt - gmt > leadSec) continue;           // too far ahead
         fromOut = m_black[i].fromGmt;
         return true;
        }
      return false;
     }

   //--- short tag of the best group listing this symbol, e.g. "T:L", "S:S"; "" if none
   string            TagFor(const string symbol) const
     {
      if(m_passThrough || !m_loaded) return "";
      string code = CodeOf(symbol);
      int best = CS_GROUP_NONE, dir = 0;
      for(int i = 0; i < ArraySize(m_allow); i++)
         if(m_allow[i].code == code && (best == CS_GROUP_NONE || m_allow[i].group < best))
           { best = m_allow[i].group; dir = m_allow[i].dir; }
      if(best == CS_GROUP_NONE) return "";
      string g = (best == CS_GROUP_TOP ? "T" : best == CS_GROUP_BACKUP ? "K" : best == CS_GROUP_STRENGTH ? "S" : "B");
      return g + (dir == CS_DIR_LONG ? ":L" : ":S") + (HasConflict(symbol) ? "!" : "");
     }

   //--- true if two groups list this symbol in opposite directions
   bool              HasConflict(const string symbol) const
     {
      string code = CodeOf(symbol);
      int seen = 0;
      for(int i = 0; i < ArraySize(m_allow); i++)
        {
         if(m_allow[i].code != code) continue;
         if(seen == 0) seen = m_allow[i].dir;
         else if(m_allow[i].dir != seen) return true;
        }
      return false;
     }

   //--- which enabled group allows this trade? Highest priority wins:
   //    TOP > BACKUP > STRENGTH > BIAS. Returns CS_GROUP_NONE if none, if the
   //    signal is stale, during a news blackout, or on a direction conflict.
   //    In the tester / with the filter off it returns CS_GROUP_TOP.
   int               GroupFor(const string symbol, const int dir, const bool useTop, const bool useBackup,
                              const bool useStrength, const bool useBias) const
     {
      if(m_passThrough) return CS_GROUP_TOP;
      if(!IsFresh()) return CS_GROUP_NONE;
      if(InBlackout(symbol, TimeGMT())) return CS_GROUP_NONE;
      if(HasConflict(symbol)) return CS_GROUP_NONE;
      string code = CodeOf(symbol);
      int best = CS_GROUP_NONE;
      for(int i = 0; i < ArraySize(m_allow); i++)
        {
         if(m_allow[i].code != code || m_allow[i].dir != dir) continue;
         int g = m_allow[i].group;
         bool on = (g == CS_GROUP_TOP && useTop) || (g == CS_GROUP_BACKUP && useBackup) ||
                   (g == CS_GROUP_STRENGTH && useStrength) || (g == CS_GROUP_BIAS && useBias);
         if(on && (best == CS_GROUP_NONE || g < best)) best = g;
        }
      return best;
     }

   //--- v1 gate (Top 3 + optional backup): dir = CS_DIR_LONG or CS_DIR_SHORT
   bool              IsAllowed(const string symbol, const int dir) const
     {
      return GroupFor(symbol, dir, true, m_useBackup, false, false) != CS_GROUP_NONE;
     }

   int               CountGroup(const int group) const
     {
      int n = 0;
      for(int i = 0; i < ArraySize(m_allow); i++) if(m_allow[i].group == group) n++;
      return n;
     }

   static string     GroupName(const int g)
     {
      switch(g)
        {
         case CS_GROUP_TOP:      return "Top 3";
         case CS_GROUP_BACKUP:   return "Backup";
         case CS_GROUP_STRENGTH: return "Strength";
         case CS_GROUP_BIAS:     return "Bias";
        }
      return "none";
     }

   //--- comma list of one group's pairs, e.g. "GBPNZD L, NZDCHF S"
   string            GroupList(const int group) const
     {
      string s = "";
      for(int i = 0; i < ArraySize(m_allow); i++)
        {
         if(m_allow[i].group != group) continue;
         if(s != "") s += ", ";
         s += m_allow[i].code + (m_allow[i].dir == CS_DIR_LONG ? " L" : " S");
        }
      return (s == "" ? "-" : s);
     }

   //--- convenience for order types
   bool              IsAllowedOrder(const string symbol, const ENUM_ORDER_TYPE type) const
     {
      bool buy = (type == ORDER_TYPE_BUY || type == ORDER_TYPE_BUY_LIMIT || type == ORDER_TYPE_BUY_STOP || type == ORDER_TYPE_BUY_STOP_LIMIT);
      return IsAllowed(symbol, buy ? CS_DIR_LONG : CS_DIR_SHORT);
     }

   int               MaxTrades(void) const { return m_maxTrades; }
   string            Mood(void) const      { return m_mood; }
   bool              PassThrough(void) const { return m_passThrough; }
   datetime          Generated(void) const { return m_generated; }
   datetime          ValidUntil(void) const { return m_validUntil; }

   string            AllowList(void) const
     {
      string s = "";
      for(int i = 0; i < ArraySize(m_allow); i++)
        {
         if(m_allow[i].group != CS_GROUP_TOP && m_allow[i].group != CS_GROUP_BACKUP) continue;
         if(s != "") s += ", ";
         s += m_allow[i].code + (m_allow[i].dir == CS_DIR_LONG ? " LONG" : " SHORT") + (m_allow[i].backup ? " (backup)" : "");
        }
      return (s == "" ? "none (stand aside)" : s);
     }

   //--- multi-line text for Comment() / logs
   string            Status(void) const
     {
      if(m_passThrough) return "Claude filter: OFF / tester pass-through";
      string s = "Claude filter: " + (IsFresh() ? "ACTIVE" : "BLOCKING (no fresh signal)") + "\n";
      if(m_loaded)
        {
         s += "Signal: " + TimeIso(m_generated) + "  valid to " + TimeIso(m_validUntil) + "\n";
         s += "Mood: " + m_mood + "   Max trades: " + IntegerToString(m_maxTrades) + "\n";
         s += "Allowed: " + AllowList() + (m_useBackup ? "" : "  [backup off]") + "\n";
         s += "Strength: " + GroupList(CS_GROUP_STRENGTH) + "\n";
         s += "Bias (" + IntegerToString(CountGroup(CS_GROUP_BIAS)) + "): " + GroupList(CS_GROUP_BIAS) + "\n";
         int active = 0, upcoming = 0;
         datetime now = TimeGMT();
         for(int i = 0; i < ArraySize(m_black); i++)
           {
            if(now >= m_black[i].fromGmt && now <= m_black[i].toGmt) active++;
            else if(m_black[i].fromGmt > now) upcoming++;
           }
         s += "Blackouts: " + IntegerToString(active) + " active, " + IntegerToString(upcoming) + " upcoming\n";
        }
      else s += "No signal loaded yet\n";
      if(m_lastError != "") s += "Last error: " + m_lastError + "\n";
      return s;
     }
  };

#endif // CLAUDE_SIGNAL_MQH
