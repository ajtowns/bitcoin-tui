# Lua Scripted Tabs — Implementation Plan

## Goal

Allow users to define custom bitcoin-tui tabs via Lua scripts, without
recompilation. A `.lua` file defines `init()` to set up declarative
sections and timer callbacks. The host handles rendering, error display,
and thread management automatically.

## Dependencies

- **Lua 5.4.8** — compiled from source (no upstream CMakeLists.txt, we
  add a small `add_library`)
- **Sol2 v3.5.0** — header-only C++/Lua binding layer
- Both added via FetchContent (already wired up in CMakeLists.txt)

## Architecture

### Tab Lifecycle

```
init(tab)  — called once; create tables, define sections, register
             timer callbacks via tab.set_interval()
```

No `render()` function — display is fully declarative via `tab.sections`
and managed Table objects. The host renders sections automatically.

Timer callbacks are registered with `tab.set_interval(secs, fn)`.
Multiple timers with different intervals are supported. Each runs as
its own coroutine.

### Declarative Display Model

`tab.sections` is an ordered list of sections. Each section has a name,
optional title (renders as a bordered box), and content (a Table object
or a string). Sections can be shown/hidden via `visible`.

Table objects are C++ managed objects created via `tab.table(key, columns)`.
They handle:
- Keyed row storage (insert/update/remove by key)
- Auto-sizing columns based on content
- Type-aware formatting (numbers, bytes, durations, hashes, timestamps)
- Per-column color functions
- Epoch-based refresh (`start_refresh()` + auto-sweep of stale rows)

### Error Handling

The host manages an automatic error pane above all sections:
- When a timer callback raises, its error is shown (keyed by callback)
- When the same callback succeeds, its error is cleared
- The pane hides when empty
- Sections keep their last good data during errors
- Scripts can use `pcall` + `warn()` for manual error display

### Memory Management

After each callback (timer or log), the host checks memory usage:
Lua heap (`lua_gc(GCCOUNT)`) plus C++ Table object estimates.

- Usage is displayed in the tab bar: `Peers (Lua) [1.2MB]`
- If usage exceeds the limit (default 64MB, configurable via CLI
  `--tab-memory-limit`), the tab is killed and the error pane shows
  the reason
- Helps catch runaway tables or log callbacks that never trim old rows

### Hidden Tab Behaviour

Timer callbacks support a `hidden` option controlling behaviour when
the tab is not visible:
- `hidden = -1` (default): skip while hidden, fire immediately when
  tab becomes visible. Avoids wasting RPCs on invisible data.
- `hidden = N` (positive): run at N-second intervals while hidden.
  Useful for data that should stay reasonably fresh (e.g. chain tips).
- Log callbacks always run regardless of visibility (they're cheap).

### Threading Model

- **Log thread**: pure C++. Tails debug.log, matches registered RE2
  patterns, queues matches (timestamp + captures) for the script thread.
  No Lua execution on this thread.
- **Script thread**: an event loop that manages all Lua execution:
  1. Drain queued log matches → dispatch as plain function calls
     (no coroutine, no `tab`, cannot yield)
  2. Check which timer callbacks are due (if a callback took longer
     than its interval, re-invoke immediately on return)
  3. Resume/start due timer coroutines (receive `tab`, can yield)
  4. When a coroutine yields (via `tab.rpc()`), dispatch the RPC
  5. When an RPC completes, resume the corresponding coroutine
  6. After a callback returns, sweep stale rows from any table
     that had `start_refresh()` called
  
  Multiple timer coroutines may be active simultaneously (but each
  callback is never concurrent with itself). Each `tab.rpc()` call
  yields its coroutine, releasing the Lua state lock while the HTTP
  call is in flight. Multiple RPCs from different coroutines can be
  in flight at once; results may arrive out of order, and the host
  resumes whichever coroutine's RPC completes first.
  
  Log callbacks run as plain function calls — they cannot call
  `tab.rpc()` (attempting to yield outside a coroutine raises an
  error). They update Table objects via captured locals.
  
  From the script's perspective, `tab.rpc()` looks like a normal
  blocking call.
- **Tick thread**: wakes UI each second (for live timers).

The UI thread reads Table objects and section state directly — Tables
are C++ objects with their own synchronisation, so no Lua lock is needed
for rendering.

### Key Design Decisions

- Each script gets its own `sol::state` (isolated)
- All Lua execution on a single thread (no lua_State thread-safety issues)
- Multiple timer callbacks, each as its own coroutine
- `tab.rpc()` yields the coroutine, releasing the Lua lock during RPC;
  multiple RPCs from different coroutines may be in flight concurrently
- Log pattern matching is pure C++ (RE2); callbacks dispatched on the
  script thread between timer callbacks
- RPC calls are allowlisted (read-only only, no wallet/signing/control)
- Display is declarative — no `render()` callback, host renders sections
  and Table objects automatically
- Table objects are C++ managed with epoch-based stale row sweeping
- Error handling is automatic; manual override via `pcall` + `warn()`
- `tab.state` is a plain Lua table for script-private state

## Implementation Steps

1. **Table C++ object** (`src/lua_table.hpp/cpp`)
   - Keyed row storage with epoch-based refresh
   - Column definitions with type-aware formatting and auto-sizing
   - Per-cell styling resolved at update time (no Lua callbacks at render)
   - Thread-safe read access for the UI thread
   - Sol2 usertype binding

2. **LuaTab class** (`src/tabs/luatab.hpp/cpp`)
   - Inherits from `Tab`
   - Owns `sol::state`, script thread, log thread, tick thread
   - Event loop: timer management, coroutine dispatch, log queue drain
   - Section rendering: walks `tab.sections`, renders Tables and text
   - Automatic error pane management (keyed by callback, auto-clear on success)

3. **RPC binding** — `tab.rpc(method, ...)`
   - Allowlist check before dispatch
   - Yields the coroutine, releases Lua lock, does HTTP call, resumes
   - Fresh `RpcClient` per call (auth rotation)
   - JSON→Lua conversion via Sol2 custom type converter

4. **Log binding** — `tab.watch_log(pattern, callback)`
   - Same registration pattern as `tab.set_interval()`
   - Compile RE2 pattern at registration time
   - Log thread (C++ only) parses lines into structured LogEntry
     (seq, timestamp, level, category, msg, sourceloc?, thread?)
   - Log thread matches pattern against msg, queues matches
   - Script thread drains queue and dispatches callbacks with
     (entry, captures?)
   - Host maintains `tab.log_status` and `tab.log_lines_parsed`

5. **Tab loading** — CLI integration
   - `--tab path/to/script.lua` flag (repeatable)
   - Auto-load from `~/.config/bitcoin-tui/tabs/` (optional)
   - Tab label from `tab.name` or filename stem

6. **Tests**
   - Catch2: Table object (update/remove/refresh/sweep), RPC allowlist,
     JSON-to-Lua conversion, log entry parsing, section rendering

## API Reference

See `lua/api.lua` for the complete LuaLS-annotated type definitions.
See `SKETCH.lua` for a worked example (peer summary + chain tips).
