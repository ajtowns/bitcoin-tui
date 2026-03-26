#pragma once

#include <atomic>
#include <mutex>

#include <ftxui/component/screen_interactive.hpp>
#include <ftxui/dom/elements.hpp>

#include "guarded.hpp"
#include "rpc_client.hpp"
#include "state.hpp"
#include "tabs/tab.hpp"

class DashboardTab : public Tab {
  public:
    DashboardTab(RpcConfig cfg, Guarded<RpcAuth>& auth, ftxui::ScreenInteractive& screen,
                 std::atomic<bool>& running, Guarded<AppState>& state);
    ~DashboardTab() override = default;

    ftxui::Element render(const AppState& snap) override;
    void           join() override;
};
