local log_lines = { seq = 0 }

local function got_raw_log_line(line)
    local seq = log_lines.seq + 1
    log_lines.seq = seq
    log_lines[seq] = line
    local k = seq - 5
    while log_lines[k] ~= nil do
        log_lines[k] = nil
        k = k - 1
    end
    return log_lines
end

function init(tab)
    tab:watch_log("^", got_raw_log_line)
end

x = 1

function update()
    x = x + 2
    return "AJ: x=" .. tostring(x)
    -- return "x=" .. tostring(x) .. " seq=" .. tostring(log_lines.seq)
end
