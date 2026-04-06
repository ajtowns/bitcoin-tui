--- bitcoin-tui Lua Tab API
--- Type definitions for IDE autocompletion (LuaLS / lua-language-server).
--- Drop this file into your workspace so your editor knows the API.

----------------------------------------------------------------------
-- Global functions — available at top level and in callbacks
----------------------------------------------------------------------

--- Create a managed table for display. Returns a Table object.
--- Options:
---   key       string   Column name used as row key (default: first column)
---   title     string   Section title (default: "Lua Table")
---   no_header boolean  Hide the header row (default: false)
---   columns   ColumnDef[]  Column definitions (required)
---@param opts TableOpts
---@return Table
function tui_table(opts) end

--- Register a periodic timer callback. The callback runs as a
--- coroutine — tui_rpc() yields transparently within it.
--- Returns an opaque TimerHandle that can be passed to tui_wake().
---@param seconds number   Interval in seconds
---@param callback function  Called each interval
---@return TimerHandle
function tui_set_interval(seconds, callback) end

--- Wake a timer so it fires on the next loop iteration, regardless
--- of its normal interval. If the timer's callback is currently
--- running (waiting for an RPC), the wake is deferred until the
--- current invocation finishes.
---@param handle TimerHandle
function tui_wake(handle) end

--- Set the tab name displayed in the tab bar. Can only be called
--- during script loading (top-level code); calling it from a
--- callback raises an error.
---@param name string
function tui_set_name(name) end

--- Register a log pattern callback. The pattern uses RE2 syntax and
--- is matched against the message portion of each debug.log line.
--- Callback receives (timestamp, message, capture1, capture2, ...).
--- Log callbacks are plain function calls — they cannot call tui_rpc().
---@param pattern string           RE2 pattern (capture groups become extra args)
---@param callback function        fn(ts, msg, ...)
---@param backlog? integer         Bytes of historical log to process (default: 0)
function tui_watch_log(pattern, callback, backlog) end

--- Call a Bitcoin Core RPC method. Can only be called from within a
--- tui_set_interval callback (yields the coroutine). The RPC is
--- dispatched to a background thread, so other timers and log
--- callbacks continue to run while waiting. Returns the parsed
--- JSON result directly, or nil on error.
---@param method string   RPC method name (must be in the allowlist)
---@param ... any         Method parameters
---@return any
function tui_rpc(method, ...) end

--- Set the status line hint text (displayed in the tab bar).
---@param text string
function tui_key_hint(text) end

----------------------------------------------------------------------
-- Timer handle
----------------------------------------------------------------------

--- Opaque handle returned by tui_set_interval, used with tui_wake.
---@class TimerHandle

----------------------------------------------------------------------
-- Table object
----------------------------------------------------------------------

---@class Table
local Table = {}

--- Insert or update a row by key. Values can be plain values or
--- styled tables with { value = v, color = "red", bold = true }.
--- Nil values are skipped (column keeps its previous value).
---@param key any       Key value (matches key column type)
---@param data table    Column values as { name = value, ... }
function Table:update(key, data) end

--- Remove a row by key. Returns true if a row was removed.
---@param key any
---@return boolean
function Table:remove(key) end

--- Return all current keys as an array of strings.
---@return string[]
function Table:keys() end

----------------------------------------------------------------------
-- Table options
----------------------------------------------------------------------

---@class TableOpts
---@field key?       string       Key column name (default: first column)
---@field title?     string       Section title
---@field no_header? boolean      Hide header row
---@field columns    ColumnDef[]  Column definitions

----------------------------------------------------------------------
-- Column definitions
----------------------------------------------------------------------

---@class ColumnDef
---@field name      string   Column identifier, used as key in update() data tables.
---@field header    string   Header text. Use \n for multi-line. Empty string hides the column.
---@field type?     string   "string" (default), "number", or "timestamp".
---@field decimals? integer  Fixed decimal places for number columns (-1 = auto).

--- Column types:
---   "string"    — displayed as-is, left-aligned
---   "number"    — right-aligned; use decimals for fixed precision
---   "timestamp" — unix timestamp displayed as HH:MM:SS.mmm

----------------------------------------------------------------------
-- Cell values
----------------------------------------------------------------------

--- Cell values in Table:update() can be plain values or styled:
---
---   -- Plain value:
---   height = 890123
---
---   -- Styled value:
---   height = { value = 890123, color = "green", bold = true }
---
--- Available colors: "red", "green", "yellow", "cyan", "gray"
---
--- Nil values are skipped (the cell retains its previous value).
--- For numeric columns, unset cells render as blank.

----------------------------------------------------------------------
-- RPC allowlist
----------------------------------------------------------------------

--- The following read-only RPC methods are permitted via tui_rpc():
---
--- Blockchain:
---   getbestblockhash, getblock, getblockchaininfo, getblockcount,
---   getblockhash, getblockheader, getblockstats, getchaintips,
---   getdeploymentinfo, getindexinfo, gettxout, gettxoutsetinfo
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
---   estimatesmartfee, uptime, logging
---
--- Raw transactions (read-only):
---   getrawtransaction, decoderawtransaction, decodescript
