#include "slowblocks.hpp"

#include <algorithm>
#include <chrono>
#include <fstream>
#include <optional>
#include <set>
#include <string>
#include <vector>

#include <ftxui/component/event.hpp>
#include <re2/re2.h>
#include <sol/sol.hpp>

#include "luatable.hpp"
#include "render.hpp"

using namespace ftxui;
using Clock     = std::chrono::system_clock;
using TimePoint = Clock::time_point;
using namespace std::chrono_literals;

const std::set<std::string> DEFAULT_RPC_ALLOWLIST = {
    "estimatesmartfee",
    "getbestblockhash",
    "getblock",
    "getblockchaininfo",
    "getblockcount",
    "getblockhash",
    "getblockheader",
    "getchaintips",
    "getconnectioncount",
    "getmempoolancestors",
    "getmempooldescendants",
    "getmempoolentry",
    "getmempoolinfo",
    "getmininginfo",
    "getnettotals",
    "getnetworkinfo",
    "getpeerinfo",
    "getrawmempool",
    "logging",
    "uptime",
};

namespace {

struct LogWatch {
    RE2                     pattern;
    int                     ngroups;
    int64_t                 backlog_bytes;
    sol::protected_function callback;
    LogWatch(const std::string& pat, sol::protected_function fn, int64_t backlog = 0)
        : pattern(pat), ngroups(pattern.NumberOfCapturingGroups()),
          backlog_bytes(std::max(int64_t{0}, backlog)), callback(std::move(fn)) {}
};

// Convert a json value to a sol::object for returning RPC results to Lua.
sol::object json_to_lua(sol::state& lua, const json& j) {
    if (j.is_null())
        return sol::nil;
    if (j.is_bool())
        return sol::make_object(lua, j.get<bool>());
    if (j.is_number_integer())
        return sol::make_object(lua, j.get<int64_t>());
    if (j.is_number_float())
        return sol::make_object(lua, j.get<double>());
    if (j.is_string())
        return sol::make_object(lua, j.get<std::string>());
    if (j.is_array()) {
        sol::table t = lua.create_table(static_cast<int>(j.size()), 0);
        for (size_t i = 0; i < j.size(); ++i)
            t[i + 1] = json_to_lua(lua, j[i]);
        return t;
    }
    if (j.is_object()) {
        sol::table t = lua.create_table(0, static_cast<int>(j.size()));
        for (auto& [k, v] : j.items())
            t[k] = json_to_lua(lua, v);
        return t;
    }
    return sol::nil;
}

// Tick/Lua thread: wakes the UI once per second, runs Lua script, tails debug.log.
void tick_thread_fn(std::atomic<bool>& running, const std::function<void()>& wake_ui,
                    Guarded<SlowBlocksState>& sb_state, const std::string& debug_log_path,
                    Guarded<LuaTableVec>& lua_tables, RpcConfig rpc_cfg, Guarded<RpcAuth>& rpc_auth,
                    const std::set<std::string>& rpc_allowlist) {
    sol::state lua;
    lua.open_libraries(sol::lib::base, sol::lib::string, sol::lib::table, sol::lib::math,
                       sol::lib::coroutine);

    // tui_rpc yields from the coroutine; C++ catches the yield and does the RPC call.
    lua.script("function tui_rpc(method, ...) return coroutine.yield('rpc', method, {...}) end");

    // Convert a Lua value to CellData based on column type
    auto to_cell_data = [](ColumnType type, int decimals, const sol::object& v) -> CellData {
        switch (type) {
        case ColumnType::Number:
            if (decimals >= 0) {
                if (v.is<double>())
                    return v.as<double>();
                if (v.is<int64_t>())
                    return static_cast<double>(v.as<int64_t>());
                return 0.0;
            }
            if (v.is<int64_t>())
                return v.as<int64_t>();
            if (v.is<double>())
                return static_cast<int64_t>(v.as<double>());
            return int64_t(0);
        case ColumnType::Timestamp:
            if (v.is<double>())
                return v.as<double>();
            return 0.0;
        default:
            if (v.is<std::string>())
                return v.as<std::string>();
            if (v.is<double>())
                return std::to_string(v.as<double>());
            return std::string{};
        }
    };

    // Convert a Lua key to CellData based on the table's key column type
    auto to_key = [&](LuaTable& self, const sol::object& v) -> CellData {
        return to_cell_data(self.key_type(), -1, v);
    };

    // Register LuaTable usertype
    lua.new_usertype<LuaTable>(
        "LuaTable", "update",
        [&](LuaTable& self, const sol::object& key, sol::table data) {
            std::map<std::string, CellValue> cells;
            const auto&                      cols = self.columns();
            for (auto& [k, v] : data) {
                if (v.is<sol::lua_nil_t>())
                    continue;
                std::string col_name = k.as<std::string>();
                CellValue   cv;
                // Find column type
                ColumnType ct  = ColumnType::String;
                int        dec = -1;
                for (const auto& col : cols) {
                    if (col.name == col_name) {
                        ct  = col.type;
                        dec = col.decimals;
                        break;
                    }
                }
                if (v.is<sol::table>()) {
                    sol::table sv = v;
                    cv.color      = sv.get_or<std::string>("color", "");
                    cv.bold       = sv.get_or("bold", false);
                    cv.data       = to_cell_data(ct, dec, sv["value"]);
                } else {
                    cv.data = to_cell_data(ct, dec, v);
                }
                cells[col_name] = std::move(cv);
            }
            self.update(to_key(self, key), cells);
        },
        "remove",
        [&](LuaTable& self, const sol::object& key) { return self.remove(to_key(self, key)); },
        "keys", &LuaTable::keys);

    // Register globals for Lua scripts
    std::vector<std::unique_ptr<LogWatch>> log_watches;

    lua["tui_watch_log"] = [&](const std::string& pattern, sol::protected_function fn,
                               sol::optional<int64_t> backlog) {
        log_watches.push_back(
            std::make_unique<LogWatch>(pattern, std::move(fn), backlog.value_or(0)));
    };

    lua["tui_table"] = [&](sol::table opts) -> std::shared_ptr<LuaTable> {
        sol::table             col_defs = opts["columns"];
        std::vector<ColumnDef> cols;
        for (size_t i = 1; i <= col_defs.size(); ++i) {
            sol::table  col      = col_defs[i];
            std::string name     = col["name"];
            std::string header   = col.get_or<std::string>("header", name);
            std::string type_str = col.get_or<std::string>("type", "string");
            auto        type     = parse_column_type(type_str);
            if (!type) {
                throw std::runtime_error("unknown column type: " + type_str);
            }
            int decimals = col.get_or("decimals", -1);
            cols.push_back({std::move(name), std::move(header), *type, decimals});
        }
        std::string def_key    = cols.empty() ? std::string{} : cols[0].name;
        std::string key_column = opts.get_or("key", std::move(def_key));
        std::string title      = opts.get_or("title", std::string{});
        bool        no_header  = opts.get_or("no_header", false);
        auto        tbl =
            std::make_shared<LuaTable>(key_column, std::move(cols), std::move(title), no_header);
        lua_tables.update([&](auto& v) { v.push_back(tbl); });
        return tbl;
    };

    lua["tui_key_hint"] = [&](const std::string& hint) {
        sb_state.update([&](auto& st) { st.lua_status = hint; });
    };

    struct LuaTimer {
        Clock::duration         interval;
        sol::protected_function callback;
    };
    std::map<TimePoint, LuaTimer> timers;

    lua["tui_set_interval"] = [&](double secs, sol::protected_function fn) {
        auto interval =
            std::chrono::duration_cast<Clock::duration>(std::chrono::duration<double>(secs));
        timers.insert({Clock::now() + interval, {interval, std::move(fn)}});
    };

    auto load_result = lua.safe_script_file("SLOWBLOCKS.lua", sol::script_pass_on_error);

    if (load_result.valid()) {
        sol::protected_function init_fn = lua["init"];
        if (init_fn.valid())
            init_fn();
    }

    // Open debug.log, seek back by max backlog
    int64_t max_backlog = 0;
    for (const auto& lw : log_watches) {
        max_backlog = std::max(max_backlog, lw->backlog_bytes);
    }

    std::ifstream logfile(debug_log_path);
    int64_t       live_pos = 0;
    if (logfile) {
        logfile.seekg(0, std::ios::end);
        live_pos = logfile.tellg();
        if (max_backlog > 0 && live_pos > max_backlog) {
            logfile.seekg(live_pos - max_backlog);
            // Skip to next newline to avoid partial line
            std::string discard;
            std::getline(logfile, discard);
        }
    }

    std::string line;
    while (running) {
        // Read new log lines, feed to Lua callbacks
        if (logfile) {
            while (std::getline(logfile, line)) {
                int64_t cur_pos         = logfile.tellg();
                int64_t bytes_from_live = std::max(int64_t{0}, live_pos - cur_pos);
                // Parse timestamp and split into (timestamp, message)
                static const RE2 re_ts_msg(
                    R"(^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,6}))?Z (.*)$)");
                std::string y, mo, d, h, mi, s, frac, msg;
                double      ts = 0.0;
                if (RE2::FullMatch(line, re_ts_msg, &y, &mo, &d, &h, &mi, &s, &frac, &msg)) {
                    std::tm tm{};
                    tm.tm_year = std::stoi(y) - 1900;
                    tm.tm_mon  = std::stoi(mo) - 1;
                    tm.tm_mday = std::stoi(d);
                    tm.tm_hour = std::stoi(h);
                    tm.tm_min  = std::stoi(mi);
                    tm.tm_sec  = std::stoi(s);
                    auto tp    = Clock::from_time_t(timegm(&tm));
                    if (!frac.empty()) {
                        while (frac.size() < 6)
                            frac += '0';
                        tp += std::chrono::microseconds(std::stoi(frac));
                    }
                    ts = std::chrono::duration<double>(tp.time_since_epoch()).count();
                } else {
                    msg = line;
                }

                for (auto& lw : log_watches) {
                    if (bytes_from_live > lw->backlog_bytes)
                        continue;
                    int                          n = lw->ngroups;
                    std::vector<std::string>     captures(n);
                    std::vector<RE2::Arg>        args(n);
                    std::vector<const RE2::Arg*> arg_ptrs(n);
                    for (int i = 0; i < n; ++i) {
                        args[i]     = &captures[i];
                        arg_ptrs[i] = &args[i];
                    }
                    if (RE2::PartialMatchN(msg, lw->pattern, arg_ptrs.data(), n)) {
                        sol::variadic_results vr;
                        vr.push_back({lua, sol::in_place, ts});
                        vr.push_back({lua, sol::in_place, msg});
                        for (int i = 0; i < n; ++i) {
                            vr.push_back({lua, sol::in_place, captures[i]});
                        }
                        lw->callback(std::move(vr));
                    }
                }
            }
            logfile.clear();
        }

        // Fire due timers (as coroutines, handling RPC yields)
        auto now = Clock::now();
        while (!timers.empty() && timers.begin()->first <= now) {
            auto  node  = timers.extract(timers.begin());
            auto& timer = node.mapped();

            sol::thread    thread = sol::thread::create(lua);
            sol::coroutine coro(thread.state(), timer.callback);

            auto result = coro();
            while (coro.status() == sol::call_status::yielded) {
                // Extract RPC request from yielded values
                std::string tag = result;
                if (tag == "rpc" && result.return_count() >= 2) {
                    std::string method = result.get<std::string>(1);
                    if (!rpc_allowlist.contains(method)) {
                        result = coro(sol::nil, "RPC method not allowed: " + method);
                        continue;
                    }
                    std::vector<json> pv;
                    if (result.return_count() >= 3) {
                        sol::table args = result.get<sol::table>(2);
                        for (size_t i = 1; i <= args.size(); ++i) {
                            sol::object a = args[i];
                            if (a.is<int64_t>())
                                pv.emplace_back(a.as<int64_t>());
                            else if (a.is<double>())
                                pv.emplace_back(a.as<double>());
                            else if (a.is<bool>())
                                pv.emplace_back(a.as<bool>());
                            else if (a.is<std::string>())
                                pv.emplace_back(a.as<std::string>());
                        }
                    }
                    json params(std::move(pv));
                    try {
                        RpcClient rpc(rpc_cfg, rpc_auth);
                        json      rpc_response = rpc.call(method, params);
                        result                 = coro(json_to_lua(lua, rpc_response["result"]));
                    } catch (const std::exception& e) {
                        result = coro(sol::nil, std::string(e.what()));
                    }
                } else {
                    break; // unknown yield tag
                }
            }
            if (!result.valid()) {
                sol::error err = result;
                sb_state.update(
                    [&](auto& st) { st.lua_status = std::string("error: ") + err.what(); });
            }

            now        = Clock::now();
            node.key() = std::max(now, node.key() + timer.interval);
            timers.insert(std::move(node));
        }

        wake_ui();
        if (!timers.empty()) {
            std::this_thread::sleep_until(std::max(timers.begin()->first, Clock::now()));
        } else {
            std::this_thread::sleep_for(std::chrono::seconds(1));
        }
    }
}

} // namespace

SlowBlocksTab::SlowBlocksTab(RpcConfig cfg, Guarded<RpcAuth>& auth, ScreenInteractive& screen,
                             std::atomic<bool>& running, Guarded<AppState>& state, int refresh_secs,
                             std::string debug_log_path)
    : Tab(std::move(cfg), auth, screen, running, state, refresh_secs),
      debug_log_path_(std::move(debug_log_path)), rpc_allowlist_(DEFAULT_RPC_ALLOWLIST) {
    auto wake = [&screen] { screen.PostEvent(ftxui::Event::Custom); };

    tick_thread_ = std::thread(tick_thread_fn, std::ref(running_), wake, std::ref(sb_state_),
                               std::cref(debug_log_path_), std::ref(lua_tables_), cfg_,
                               std::ref(auth_), std::cref(rpc_allowlist_));
}

Element SlowBlocksTab::key_hints(const AppState& snap) const {
    auto lua_str = sb_state_.access([](const auto& s) { return s.lua_status; });
    return hbox({text("  " + lua_str) | color(Color::Cyan), refresh_indicator(snap),
                 text("  [Tab/\u2190/\u2192] switch  [q] quit ") | color(Color::GrayDark)});
}

Element SlowBlocksTab::render(const AppState& /*snap*/) {
    std::string warning = sb_state_.access([](const auto& s) { return s.warning; });

    // Lua tables
    Elements lua_panels;
    auto     tables = lua_tables_.get();
    for (const auto& tbl : tables) {
        const auto& cols  = tbl->columns();
        size_t      ncols = cols.size();

        // Visible columns (non-empty header)
        std::vector<size_t> vis;
        for (size_t i = 0; i < ncols; ++i) {
            if (!cols[i].header.empty())
                vis.push_back(i);
        }

        // Compute column widths for visible columns
        // For multi-line headers, use the widest line
        // First column has no leading space; others have 1 char leading space
        std::vector<int> widths(vis.size());
        for (size_t vi = 0; vi < vis.size(); ++vi) {
            const auto& hdr   = cols[vis[vi]].header;
            int         max_w = 0;
            size_t      pos   = 0;
            while (pos <= hdr.size()) {
                size_t nl = hdr.find('\n', pos);
                if (nl == std::string::npos)
                    nl = hdr.size();
                int w = static_cast<int>(nl - pos);
                if (w > max_w)
                    max_w = w;
                pos = nl + 1;
            }
            widths[vi] = max_w + (vi == 0 ? 1 : 2);
        }
        tbl->access([&](const auto& rows) {
            for (const auto& row : rows) {
                for (size_t vi = 0; vi < vis.size() && vis[vi] < row.cells.size(); ++vi) {
                    auto s = format_cell(cols[vis[vi]].type, row.cells[vis[vi]].data,
                                         cols[vis[vi]].decimals);
                    int  w = static_cast<int>(s.size()) + (vi == 0 ? 1 : 2);
                    if (w > widths[vi])
                        widths[vi] = w;
                }
            }
        });

        // Right-aligned columns
        std::vector<bool> ralign(vis.size(), false);
        for (size_t vi = 0; vi < vis.size(); ++vi) {
            switch (cols[vis[vi]].type) {
            case ColumnType::Number:
                ralign[vi] = true;
                break;
            default:
                break;
            }
        }

        // Header row (supports multi-line headers with \n, bottom-aligned)
        // First pass: split headers and find max line count
        std::vector<std::vector<std::string>> hdr_lines(vis.size());
        size_t                                max_lines = 1;
        for (size_t vi = 0; vi < vis.size(); ++vi) {
            const std::string& hdr = cols[vis[vi]].header;
            size_t             pos = 0;
            while (pos <= hdr.size()) {
                size_t nl = hdr.find('\n', pos);
                if (nl == std::string::npos)
                    nl = hdr.size();
                hdr_lines[vi].push_back(hdr.substr(pos, nl - pos));
                pos = nl + 1;
            }
            if (hdr_lines[vi].size() > max_lines)
                max_lines = hdr_lines[vi].size();
        }
        // Second pass: build cells, padding short headers with blank lines above
        Elements hdr_cells;
        for (size_t vi = 0; vi < vis.size(); ++vi) {
            Elements lines;
            size_t   pad_lines = max_lines - hdr_lines[vi].size();
            for (size_t i = 0; i < pad_lines; ++i)
                lines.push_back(text(""));
            std::string prefix = (vi == 0) ? "" : " ";
            for (const auto& line : hdr_lines[vi]) {
                std::string s = line;
                if (ralign[vi]) {
                    int pad =
                        widths[vi] - static_cast<int>(s.size()) - static_cast<int>(prefix.size());
                    if (pad > 0)
                        s = std::string(pad, ' ') + s;
                }
                lines.push_back(text(prefix + s));
            }
            auto el = (max_lines == 1) ? std::move(lines[0]) : vbox(std::move(lines));
            if (vi + 1 < vis.size() || ralign[vi])
                el = el | size(WIDTH, EQUAL, widths[vi]);
            else
                el = el | flex;
            hdr_cells.push_back(std::move(el));
        }
        Elements tbl_rows;
        if (!tbl->no_header()) {
            tbl_rows.push_back(hbox(hdr_cells) | color(Color::Cyan) | bold);
            tbl_rows.push_back(separator());
        }

        // Data rows
        tbl->access([&](const auto& rows) {
            for (const auto& row : rows) {
                Elements cells;
                for (size_t vi = 0; vi < vis.size() && vis[vi] < row.cells.size(); ++vi) {
                    const auto& cv = row.cells[vis[vi]];
                    std::string val =
                        format_cell(cols[vis[vi]].type, cv.data, cols[vis[vi]].decimals);
                    std::string prefix = (vi == 0) ? "" : " ";
                    if (ralign[vi]) {
                        int pad = widths[vi] - static_cast<int>(val.size()) -
                                  static_cast<int>(prefix.size());
                        if (pad > 0)
                            val = std::string(pad, ' ') + val;
                    }
                    auto el = text(prefix + val);
                    if (!cv.color.empty()) {
                        if (cv.color == "red")
                            el = el | color(Color::Red);
                        else if (cv.color == "green")
                            el = el | color(Color::Green);
                        else if (cv.color == "yellow")
                            el = el | color(Color::Yellow);
                        else if (cv.color == "cyan")
                            el = el | color(Color::Cyan);
                        else if (cv.color == "gray")
                            el = el | color(Color::GrayDark);
                    }
                    if (cv.bold)
                        el = el | ftxui::bold;
                    if (vi + 1 < vis.size() || ralign[vi])
                        el = el | size(WIDTH, EQUAL, widths[vi]);
                    else
                        el = el | flex;
                    cells.push_back(el);
                }
                tbl_rows.push_back(hbox(cells));
            }
        });

        std::string box_title = tbl->title().empty() ? "Lua Table" : tbl->title();
        lua_panels.push_back(section_box(box_title, tbl_rows));
    }

    Elements panels;
    if (!warning.empty()) {
        panels.push_back(text(" " + warning) | bold | color(Color::Red) | border);
    }
    for (auto& lp : lua_panels) {
        panels.push_back(std::move(lp));
    }
    return vbox(panels) | flex;
}

void SlowBlocksTab::join() {
    if (tick_thread_.joinable())
        tick_thread_.join();
}
