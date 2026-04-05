#pragma once

#include <atomic>
#include <set>
#include <string>
#include <thread>

#include <ftxui/dom/elements.hpp>

#include "guarded.hpp"
#include "luatable.hpp"
#include "tabs/tab.hpp"

struct SlowBlocksState {
    std::string warning;    // e.g. missing log categories
    std::string lua_status; // status output from Lua
};

class SlowBlocksTab : public Tab {
  public:
    SlowBlocksTab(RpcConfig cfg, Guarded<RpcAuth>& auth, ftxui::ScreenInteractive& screen,
                  std::atomic<bool>& running, Guarded<AppState>& state, int refresh_secs,
                  std::string debug_log_path);
    ~SlowBlocksTab() override = default;

    ftxui::Element render(const AppState& snap) override;
    ftxui::Element key_hints(const AppState& snap) const override;
    void           join() override;

  private:
    std::string                 debug_log_path_;
    const std::set<std::string> rpc_allowlist_;
    Guarded<SlowBlocksState>    sb_state_;
    Guarded<LuaTableVec>        lua_tables_;
    std::thread                 tick_thread_;
};
