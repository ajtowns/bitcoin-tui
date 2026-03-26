#pragma once

#include <atomic>

#include <ftxui/dom/elements.hpp>

#include "tabs/tab.hpp"

class DashboardTab : public Tab {
  public:
    DashboardTab(RpcConfig cfg, Guarded<RpcAuth>& auth, ftxui::ScreenInteractive& screen,
                 std::atomic<bool>& running, Guarded<AppState>& state);
    ~DashboardTab() override = default;

    ftxui::Element render(const AppState& snap) override;
    void           join() override;
};
