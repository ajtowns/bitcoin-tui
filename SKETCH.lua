--- Peer Summary tab — shows connected peers, chain tips, and recent log.
--- Usage: bitcoin-tui --tab SKETCH.lua

local peers_table
local tips_table
local log_table
local peers_section
local tips_section
local log_seq = 0

local function colorize_ping(v)
    if v and v > 5 then return { value = v, color = "red" } end
    return v
end

local function colorize_tip_status(status)
    if status == "active" then return { value = status, color = "green" } end
    if status == "valid-fork" or status == "valid-headers" then return { value = status, color = "yellow" } end
    return status
end

local function colorize_level(level)
    if level == "error" then return { value = level, color = "red", bold = true } end
    if level == "warning" then return { value = level, color = "yellow" } end
    return level
end

local function update_peers(tab)
    local peers = tab.rpc("getpeerinfo")

    peers_table:start_refresh()
    for _, p in ipairs(peers) do
        peers_table:update(p.id, {
            addr = p.addr,
            dir = p.inbound and "in" or "out",
            version = p.subver,
            ping = colorize_ping(p.pingtime),
            sent = p.bytessent,
            recv = p.bytesrecv,
        })
    end
    peers_section.title = "Peers (" .. #peers .. ")"
end

local function update_tips(tab)
    local tips = tab.rpc("getchaintips")

    local active_height = 0
    for _, t in ipairs(tips) do
        if t.status == "active" then
            active_height = t.height
            break
        end
    end

    tips_table:start_refresh()
    for _, t in ipairs(tips) do
        if t.status == "active" or t.height > active_height - 100 then
            tips_table:update(t.hash, {
                height = t.height,
                status = colorize_tip_status(t.status),
                branchlen = t.branchlen,
            })
        end
    end
end

local function on_log_line(entry)
    log_seq = log_seq + 1
    log_table:update(log_seq, {
        timestamp = entry.timestamp,
        level = colorize_level(entry.level),
        category = entry.category,
        msg = entry.msg,
    })
    if log_seq > 10 then
        log_table:remove(log_seq - 10)
    end
end

function init(tab)
    tab.name = "Peers (Lua)"

    peers_table = tab.table("id", {
        { name = "id",      header = "ID",       type = "number" },
        { name = "addr",    header = "Address",  type = "string" },
        { name = "dir",     header = "Dir",      type = "string" },
        { name = "version", header = "Version",  type = "string" },
        { name = "ping",    header = "Ping",     type = "duration" },
        { name = "sent",    header = "Sent",     type = "bytes" },
        { name = "recv",    header = "Recv",     type = "bytes" },
    })

    tips_table = tab.table("hash", {
        { name = "status",    header = "Status",    type = "string" },
        { name = "height",    header = "Height",    type = "number" },
        { name = "branchlen", header = "Branch",    type = "number" },
        { name = "hash",      header = "Hash",      type = "hash" },
    })

    log_table = tab.table("seq", {
        { name = "timestamp", header = "Time",     type = "timestamp" },
        { name = "level",     header = "Level",    type = "string" },
        { name = "category",  header = "Cat",      type = "string" },
        { name = "msg",       header = "Message",  type = "string" },
    })

    peers_section = { name = "peers", title = "Peers", content = peers_table }
    tips_section  = { name = "tips",  title = "Chain Tips", content = tips_table }

    tab.sections = {
        peers_section,
        tips_section,
        { name = "log", title = "Log", content = log_table },
    }

    tab.set_interval(5, update_peers)
    tab.set_interval(10, update_tips, { hidden = 60 })
    tab.watch_log(".", on_log_line)
end
