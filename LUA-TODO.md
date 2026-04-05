# Lua Tabs — TODO

## Error handling
- Error pane: auto-display callback errors keyed by callback, auto-clear on success
- Fix `pcall` + coroutine yield interaction (currently returns `true, nil` on RPC error)

## Table features
- Epoch-based refresh: `start_refresh()` before update loop, auto-sweep stale rows after
- Extra header info per table (e.g. log status, line count)

## Log watching
- Structured LogEntry: parse level/category from bracket prefix (e.g. `[net]`, `[error]`)

## Tab lifecycle
- Tab loading via CLI (`--tab path.lua`), auto-load from `~/.config/bitcoin-tui/tabs/`
- Multiple Lua tabs, each with own `sol::state` and thread
- Tab name from script (e.g. `tui_set_name("Slow Blocks")`)

## Performance
- Separate log thread (currently log tailing blocks timer dispatch during backlog)
- Concurrent RPC: multiple coroutines in flight, resume whichever completes first
- Hidden tab behaviour: skip/throttle timers when tab not visible
- Memory management: track Lua heap + table sizes, kill tab if over limit

## Testing
- Catch2 tests: LuaTable (update/remove/keys), JSON-to-Lua conversion, RPC allowlist
