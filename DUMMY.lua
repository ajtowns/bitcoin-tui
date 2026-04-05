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

function init()
    log_table = tui_table("seq", {
--        { name = "seq", header = "#", type = "number" },
        { name = "timestamp", header = "Time", type = "timestamp" },
        { name = "msg", header = "Message" },
    }, "Log Watcher")
    tui_watch_log("^", got_raw_log_line)
end

x = 1

function update()
    x = x + 2
    return "AJ: x=" .. tostring(x)
    -- return "x=" .. tostring(x) .. " seq=" .. tostring(log_lines.seq)
end
