local log_table
local seq = 0

local function got_raw_log_line(ts, msg)
    seq = seq + 1
    log_table:update(seq, { timestamp = ts, msg = msg })
    local oseq = seq - 10
    while log_table:remove(oseq) do
        oseq = oseq - 1
    end
end

local x = 1

local function update()
    x = x + 2
    tui_key_hint("AJ: x=" .. tostring(x))
end

function init()
    log_table = tui_table("seq", {
--        { name = "seq", header = "#", type = "number" },
        { name = "timestamp", header = "Time", type = "timestamp" },
        { name = "msg", header = "Message" },
    }, "Log Watcher")
    tui_watch_log("^", got_raw_log_line)
    tui_set_interval(1, update)
end
