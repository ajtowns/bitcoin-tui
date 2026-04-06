# Lua Tabs — TODO

## Table features
- Extra header info per table next to header (e.g. log status, line count)

## Log watching
- Structured LogEntry: parse level/category from bracket prefix (e.g. `[net]`, `[error]`)

## Performance
- Hidden tab behaviour: skip/throttle timers when tab not visible
- Memory management: track Lua heap + table sizes, kill tab if over limit

## Testing
- Catch2 tests: LuaTable (update/remove/keys), JSON-to-Lua conversion, RPC allowlist
