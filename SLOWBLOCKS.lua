
-- Block tracking state
local blocks = {}         -- hash -> block info
local block_order = {}    -- array of hashes for display order
local pending_connect_secs = nil
local active_height = 0
local block_table

local function seen_block(ts, hash)
    local b = blocks[hash]
    if not b then
        b = {
            height = nil,
            hash = hash,
            time_header = ts,
            time_block = nil,
            compact = nil,
            txns_requested = nil,
            validation_secs = nil,
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
    pending_connect_secs = tonumber(elapsed) / 1000.0
end

local function on_update_tip(ts, msg, hash, height)
    local h = tonumber(height)
    active_height = h
    local b = seen_block(ts, hash)
    if not b.height then b.height = h end
    if not b.time_block then b.time_block = ts end
    if b.compact == nil then b.compact = false end
    if pending_connect_secs then
        b.validation_secs = pending_connect_secs
        pending_connect_secs = nil
    end
end

local function embolden(v)
    if v == nil then return nil end
    if type(v) == "table" then
        v.bold = true
        return v
    else
        return { value = v, bold = true }
    end
end

local function gray_all_if(cond, tbl)
    if cond then
        for k, v in pairs(tbl) do
            if type(v) == "table" then
                v.color = "gray"
            elseif v ~= nil then
                tbl[k] = { value = v, color = "gray" }
            end
        end
    end
    return tbl
end

local function num_colour(n, max_green, max_yellow)
    if n == nil then return nil end
    if n < max_green then
        return { value = n, color = "green" }
    elseif n < max_yellow then
        return { value = n, color = "yellow" }
    else
        return { value = n, color = "red" }
    end
end

local function tip_labels(chaintips, tips)
    local labels = {}
    local prefix = ""
    for _, tip in ipairs(chaintips) do
        local info = tips[tip.hash]
        if info then
            local cur = tip.hash
            for i = 1, 100 do
                if not cur or not blocks[cur] then break end
                if not labels[cur] then labels[cur] = prefix end
                labels[cur] = labels[cur] .. info.letter
                cur = blocks[cur].prev
            end
            prefix = prefix .. " "
        end
    end
    return labels
end

local function code_colour(code)
    if code ~= nil and code:sub(1,1) == "A" then return { value = code, color = "cyan" } end
    return code
end

local function abbrev_hash(h)
    if h == nil then return h end
    return h:sub(1,8) .. "..." .. h:sub(-12)
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

    for _, hash in ipairs(block_order) do
        local b = blocks[hash]
        if b and not b.prev then
            local hdr = tui_rpc("getblockheader", hash)
            if hdr then b.prev = hdr.previousblockhash end
        end
        if b and not b.size then
            local blk = tui_rpc("getblock", hash, 1)
            if blk and blk.size then b.size = blk.size/1000; b.tx_count = blk.nTx end
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

    if not active_height then return end

    local labels = tip_labels(chaintips, tips)
    for seq, hash in ipairs(block_order) do
        local b = blocks[hash]
        if b and b.height >= active_height - 15 then
            local delta = nil
            if b.time_block and b.time_header then delta = b.time_block - b.time_header end
            local compact = ""
            if b.time_block then
                if b.compact then
                    if b.txns_requested == nil then
                        compact = { value = "yes (header)", color = "yellow" }
                    elseif b.txns_requested > 0 then
                        compact = { value = "yes (" .. tostring(b.txns_requested) .. " req)", color = "yellow" }
                    else
                        compact = { value = "yes", color = "green" }
                    end
                else
                    compact = { value = "no", color = "gray" }
                end
            end
            local code = labels[hash]
            local inactive = (code == nil or code:sub(1,1) ~= "A")
            block_table:update(seq, gray_all_if(inactive, {
                height = b.height,
                code = code_colour(code),
                hash = abbrev_hash(hash),
                header = b.time_header,
                compact = compact,
                block = num_colour(delta, 1, 10),
                validate = embolden(num_colour(b.validation_secs, 0.5, 5.0)),
                size = b.size,
                txs = b.tx_count,
            }))
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

block_table = tui_table({
    key = "seq",
    title = "Recent Blocks (lua)",
    columns = {
        { name = "height", header = "Height", type = "number" },
        { name = "code", header = " " },
        { name = "hash", header = "Hash" },
        { name = "header", header = "Header", type = "timestamp" },
        { name = "compact", header = "Compact" },
        { name = "block", header = "Block\nDelay (s)", type = "number", decimals = 3 },
        { name = "validate", header = "Validation\nDelay (s)", type = "number", decimals = 3 },
        { name = "size", header = "Size (kB)", type = "number", decimals = 1 },
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
        { name = "hash", header = "Hash" },
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
