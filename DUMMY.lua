
-- Block tracking state
local blocks = {}         -- hash -> block info
local block_order = {}    -- array of hashes for display order
local pending_connect_ms = nil
local active_height = 0
local block_table

local function seen_block(ts, hash)
    local b = blocks[hash]
    if not b then
        b = {
            height = nil,
            hash = hash,
            time_header = ts,
            compact = nil,
            time_block = nil,
            size = nil,
            tx_count = nil,
        }
        blocks[hash] = b
        table.insert(block_order, hash)
    end
    return b
end

local function on_saw_header(ts, msg, compact, hash, height)
    local b = seen_block(ts, hash)
    b.height = tonumber(height)
    b.compact = (compact ~= "")
end

local function on_reconstructed(ts, msg, hash, prefilled, from_mempool, requested)
    local b = seen_block(ts, hash)
    if not b.time_block then
        b.time_block = ts
        b.compact = true
        b.txns_requested = tonumber(requested)
    end
end

local function on_received(ts, msg, hash)
    local b = seen_block(ts, hash)
    if not b.time_block then
        b.time_block = ts
    end
end

local function on_connect(ts, msg, elapsed)
    pending_connect_ms = tonumber(elapsed)
end

local function on_update_tip(ts, msg, hash, height)
    local h = tonumber(height)
    active_height = h
    local b = seen_block(ts, hash)
    if not b.height then b.height = h end
    if not b.time_block then b.time_block = ts end
    if b.compact == nil then b.compact = false end
    if pending_connect_ms then
        b.validation_ms = pending_connect_ms
        pending_connect_ms = nil
    end
end

local function update()
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
    while tip_table:remove(seq + 1) do seq = seq + 1 end

    for seq, hash in ipairs(block_order) do
        local b = blocks[hash]
        if b then
            local delta = nil
            if b.time_block and b.time_header then delta = b.time_block - b.time_header end
            block_table:update(seq, {
                height = b.height,
                hash = hash,
                header = b.time_header,
                block = delta,
                compact = "",
                validate = b.validation_ms and b.validation_ms / 1000 or nil,
            })
        end
    end
end

-- Tail debug.log state
local log_table
local seq = 0

local function got_raw_log_line(ts, msg)
    seq = seq + 1
    log_table:update(seq, { timestamp = ts, msg = msg })
    local oseq = seq - 10
    while log_table:remove(oseq) do oseq = oseq - 1 end
end

function init()
    block_table = tui_table({
        key = "seq",
        title = "Recent Blocks (lua)",
        columns = {
            { name = "height", header = "Height", type = "number" },
            { name = "code", header = "*" },
            { name = "hash", header = "Hash", type = "hash" },
            { name = "header", header = "Header", type = "timestamp" },
            { name = "block", header = "Block", type = "duration" },
            { name = "compact", header = "Compact" },
            { name = "validate", header = "Validate", type = "duration" },
            { name = "size", header = "Size", type = "bytes" },
            { name = "txs", header = "TXs", type = "number" },
        },
    })
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
    local BACKLOG = 2*1024*1024
    tui_watch_log("Saw new (cmpctblock )?header hash=(\\w+) height=(\\d+)", on_saw_header, BACKLOG)
    tui_watch_log("Successfully reconstructed block (\\w+) with (\\d+) txn prefilled, (\\d+) txn from mempool \\(incl at least \\d+ from extra pool\\) and (\\d+) txn", on_reconstructed, BACKLOG)
    tui_watch_log("received block (\\w+) peer=", on_received, BACKLOG)
    tui_watch_log("- Connect block: ([0-9.]+)ms", on_connect, BACKLOG)
    tui_watch_log("UpdateTip: new best=(\\w+) height=(\\d+)", on_update_tip, BACKLOG)
    tui_watch_log("^", got_raw_log_line, 5000)
    tui_set_interval(1, update)
end
