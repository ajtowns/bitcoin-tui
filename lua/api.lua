--- bitcoin-tui Lua Tab API
--- Type definitions for IDE autocompletion (LuaLS / lua-language-server).
--- Drop this file into your workspace so your editor knows the API.

----------------------------------------------------------------------
-- Tab object — passed to init() and timer callbacks
----------------------------------------------------------------------

---@class Tab
---@field state      table     Persistent table; survives across calls. Initialise in init().
---@field name       string    Tab label shown in the tab bar (default: filename stem).
---@field sections   Section[] Ordered list of sections to display. Set in init().
---@field rpc        fun(method_or_call: string|table, ...: any): any  Call one or more Bitcoin Core RPC methods. See "RPC calls" section below. Yields the coroutine transparently. Only allowlisted read-only methods are permitted.
---@field set_interval fun(seconds: number, callback: fun(tab: Tab), opts?: IntervalOpts)  Register a periodic timer callback. Runs as a coroutine — tab.rpc() yields transparently. If the callback takes longer than the interval, it is re-invoked immediately on return. Multiple timers supported. Can be called in init() or later.
---@field watch_log  fun(pattern: string, callback: fun(entry: LogEntry, captures?: string[]))  Register a log callback. Runs as a plain function call (NOT a coroutine) — cannot call tab.rpc(). Receives only the LogEntry; use captured Table locals to update display. Can be called in init() or later.
---@field table      fun(key: string, columns: ColumnDef[]): Table  Create a managed table object. The key names the field used for update/remove lookups.
---@field now        fun(): number  Current wall-clock time as a unix timestamp (seconds, microsecond precision).
---@field log_status string    Current log reader status: "opening...", "reading...", "tailing", "error: ...". Updated by the host.
---@field log_lines_parsed integer  Number of log lines parsed so far. Updated by the host.

----------------------------------------------------------------------
-- Sections — declarative display layout
----------------------------------------------------------------------

--- A section is a displayable panel. The host renders tab.sections
--- in order, skipping invisible ones. An automatic error pane
--- (managed by the host) appears above all sections when any timer
--- callback raises an error.
---@class Section
---@field name     string    Identifier for this section.
---@field title?   string    Bordered section header (omit for no border/title).
---@field content  Table|string  A Table object or a text string.
---@field visible? boolean   Whether to display (default: true).
---@field bold?    boolean   For text content: render bold.
---@field color?   string    For text content: text color.

----------------------------------------------------------------------
-- Table object — managed keyed table with auto-rendering
----------------------------------------------------------------------

---@class Table
local Table = {}

--- Mark the start of a full refresh. After the timer callback
--- returns, any rows not touched by update() since this call
--- are automatically removed. Only affects tables where
--- start_refresh() was called — other tables keep all rows.
function Table:start_refresh() end

--- Insert or update a row by key. If start_refresh() was called,
--- this also marks the row as current (not stale).
--- The key value is provided as the first argument and is
--- automatically filled into the key column if it is visible.
--- Do not include the key field in the data table.
---@param key any           The key value (matches the key field type)
---@param data table        Column values as { name = value, ... }
function Table:update(key, data) end

--- Remove a row by key.
---@param key any
function Table:remove(key) end

--- Return all current keys as an array.
---@return any[]
function Table:keys() end

----------------------------------------------------------------------
-- Column definitions
----------------------------------------------------------------------

---@class ColumnDef
---@field name   string   Column identifier, used as key in update() data tables.
---@field header string   Column header text displayed in the table.
---@field type   string   Data type for formatting and auto-sizing. See below.

--- Column types and their behaviour:
---   "string"    — displayed as-is, left-aligned
---   "number"    — right-aligned
---   "hash"      — abbreviated with middle elided (e.g. "00000000ab...cdef1234")
---   "bytes"     — formatted as KB/MB (e.g. "1.2MB")
---   "duration"  — formatted as ms/s (e.g. "0.150s", "2.3s")
---   "timestamp" — formatted as HH:MM:SS.mmm

----------------------------------------------------------------------
-- Cell values
----------------------------------------------------------------------

--- Cell values passed to Table:update() can be either plain values
--- (formatted according to the column type) or styled values with
--- explicit color/bold. Styling is resolved at update time so the
--- C++ renderer never calls back into Lua.
---
---@alias CellValue any | StyledValue

---@class StyledValue
---@field value any          The raw value (formatted according to column type).
---@field color? string      Color name ("red", "green", "yellow", etc.) or nil for default.
---@field bold?  boolean     Whether to render bold.
---
--- Example:
---   -- Plain value, default styling:
---   ping = 0.25
---
---   -- Styled value:
---   ping = { value = 8.5, color = "red" }
---
--- A helper function can return either form:
---   local function colorize_ping(v)
---       if v and v > 5 then return { value = v, color = "red" } end
---       return v
---   end

----------------------------------------------------------------------
-- Error handling
----------------------------------------------------------------------

--- The host automatically manages an error pane above all sections.
---
--- When a timer callback raises an error (including from tab.rpc()),
--- the host catches it and adds an entry to the error pane keyed
--- by the callback identity. The corresponding section stays visible
--- with its last good data.
---
--- When the same callback succeeds on a subsequent invocation, its
--- error entry is cleared. The error pane is hidden when empty.
---
--- For manual error display (e.g. to hide a section when an
--- optional RPC is unsupported), use pcall and warn:
---
---   local ok, result = pcall(tab.rpc, "getindexinfo")
---   if not ok then
---       warn("getindexinfo not available: " .. tostring(result))
---       my_section.visible = false
---       return
---   end
---
--- Messages from warn() appear in the error pane but are NOT
--- auto-cleared — they persist until the script calls warn()
--- again or the next successful run of the same callback.

----------------------------------------------------------------------
-- Log entries
----------------------------------------------------------------------

--- Structured log entry, parsed by the C++ host from debug.log lines.
--- Passed to callbacks registered via tab.watch_log().
---@class LogEntry
---@field seq       integer    Auto-incrementing sequence number (unique key).
---@field timestamp number     Unix timestamp with microsecond precision.
---@field level     string     "error", "warning", "info", "debug", "trace".
---@field category  string     Log category ("net", "validation", "", etc.).
---@field msg       string     The message text.
---@field sourceloc? string    Source location if enabled (e.g. "net_processing.cpp:3540").
---@field thread?   string     Thread name if enabled (e.g. "msghand", "scheduler").

--- Level is derived from the log line bracket prefix:
---   [error]        → level="error"   category=""
---   [warning]      → level="warning" category=""
---   [net]          → level="debug"   category="net"
---   [net:trace]    → level="trace"   category="net"
---   (no bracket)   → level="info"    category=""

----------------------------------------------------------------------
-- RPC calls
----------------------------------------------------------------------

--- Single RPC call:
---   local block = tab.rpc("getblock", hash, 1)
---
--- Multiple RPCs (dispatched in parallel, yields until all complete):
---   local header, block = tab.rpc(
---       {"getblockheader", hash},
---       {"getblock", hash, 1}
---   )
---
--- The host distinguishes the two forms by checking whether the first
--- argument is a string (single call) or a table (multi call).
--- Both forms raise on RPC error.
---
--- The following RPC methods are permitted via tab.rpc().
--- All are read-only; wallet, signing, and control RPCs are blocked.
---
--- Blockchain:
---   getblock, getblockchaininfo, getblockcount, getblockhash,
---   getblockheader, getblockstats, getchaintips, gettxout,
---   gettxoutsetinfo
---
--- Mempool:
---   getmempoolinfo, getrawmempool, getmempoolentry,
---   getmempoolancestors, getmempooldescendants
---
--- Network:
---   getpeerinfo, getnetworkinfo, getnettotals,
---   getconnectioncount, getnodeaddresses
---
--- Mining:
---   getmininginfo, getnetworkhashps
---
--- Util:
---   estimatesmartfee, uptime, logging, getindexinfo,
---   getdeploymentinfo
---
--- Raw transactions (read-only):
---   getrawtransaction, decoderawtransaction, decodescript

----------------------------------------------------------------------
-- Tab callbacks — define these in your script
----------------------------------------------------------------------

--- Called once when the tab loads. Set up state, create tables,
--- define sections, register timer callbacks via tab.set_interval().
---@param tab Tab
function init(tab) end

----------------------------------------------------------------------
-- Timer options
----------------------------------------------------------------------

---@class IntervalOpts
---@field hidden? number  Interval in seconds when the tab is not visible. Default: -1 (skip while hidden, fire immediately when tab becomes visible). Set to a positive number to run at a reduced frequency while hidden.

----------------------------------------------------------------------
-- Timer callbacks (coroutines)
----------------------------------------------------------------------

--- Timer callbacks are registered via tab.set_interval(secs, fn, opts).
--- Each runs as its own coroutine on the script thread.
---
--- Coroutine behaviour:
---   tab.rpc() yields the coroutine, releasing the Lua state lock
---   while the RPC is in flight. Multiple RPCs from different
---   coroutines may be in flight simultaneously; results may arrive
---   out of order. From the script's perspective, tab.rpc() looks
---   like a normal blocking call.
---
--- Scheduling:
---   If a callback takes longer than its interval (e.g. slow RPC),
---   it is re-invoked immediately when it returns — no queueing,
---   no skipping. It is never run concurrently with itself.
---
--- Hidden tab behaviour:
---   By default (hidden = -1), callbacks are skipped while the tab
---   is not visible and fire immediately when the tab becomes active
---   again. Set opts.hidden to a positive number to run at a reduced
---   frequency while hidden (e.g. hidden = 60 to poll every 60s).
---
--- Error handling:
---   If a callback raises, the host displays the error in the
---   automatic error pane and retries on the next interval. The
---   error clears automatically on the next successful run.
---
--- Stale row sweep:
---   After a callback returns, any tables that had start_refresh()
---   called will have their untouched rows removed automatically.
---
--- Log dispatch:
---   Queued watch_log matches are dispatched between timer callbacks.

----------------------------------------------------------------------
-- Log callbacks (plain function calls)
----------------------------------------------------------------------

--- Log callbacks are registered via tab.watch_log(pattern, fn).
--- They run as plain function calls (NOT coroutines) and cannot
--- call tab.rpc() — attempting to do so will raise an error.
---
--- Log callbacks receive only the LogEntry (and captures). To
--- update the display, use captured Table object locals:
---
---   local log_table = tab.table("seq", { ... })
---   local seq = 0
---   tab.watch_log(".", function(entry)
---       seq = seq + 1
---       log_table:update(seq, { msg = entry.msg })
---       if seq > 10 then log_table:remove(seq - 10) end
---   end)
