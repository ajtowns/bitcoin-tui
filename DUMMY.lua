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
    local sv = tui_rpc("getnetworkinfo")
    tui_key_hint("AJ: x=" .. tostring(x) .. " " .. tostring(sv.subversion))

    local chaintips = tui_rpc("getchaintips")
    local tips = {}
    local active = nil
    local active_height = 0
    for _, tip in ipairs(chaintips) do
        if tip.status == "active" then
            active = tip.hash
            active_height = tip.height
        end
    end

    local seq = 1
    for _, tip in ipairs(chaintips) do
        if active and tip.height >= active_height - 10000 then
            local letter
            if tip.hash == active then
                letter = "A"
                tip_table:update(1, {
                    height = "height=" .. tostring(tip.height),
                    code = { value = "A", color = "cyan" },
                    status = { value = tip.status, color = "green" },
                    hash = { value = tip.hash, color = "gray" },
                })
            else
                seq = seq + 1
                letter = string.char(seq + 96)
                local status = tip.status
                if status == "valid-fork" or status == "valid-headers" then
                    status = { value = status, color = "yellow" }
                end
                tip_table:update(seq, {
                    height = "height=" .. tostring(tip.height),
                    code = letter,
                    status = status,
                    hash = { value = tip.hash, color = "gray" },
                })
            end
            tips[tip.hash] = { letter = letter, height = tip.height, status = tip.status }
        end
    end
    while tip_table:remove(seq + 1) do
        seq = seq + 1
    end
end

function init()
    tip_table = tui_table({
        key = "seq",
        title = "Recent Chain Tips",
        no_header = true,
        columns = {
            { name = "code", header = "*" },
            { name = "status", header = "Status" },
            { name = "height", header = "Height" },
            { name = "hash", header = "Hash", type = "hash" },
        },
    })
    log_table = tui_table({
        key = "seq",
        title = "Log Watcher",
        columns = {
            { name = "timestamp", header = "Time", type = "timestamp" },
            { name = "msg", header = "Message" },
        },
    })
    tui_watch_log("^", got_raw_log_line)
    tui_set_interval(1, update)
end
