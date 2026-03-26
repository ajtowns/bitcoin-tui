#pragma once

#include <string>
#include <vector>

#include <ftxui/dom/elements.hpp>
#include <ftxui/screen/color.hpp>

#include "state.hpp"

// Shared helpers used by render_* functions and tab classes
ftxui::Element section_box(const std::string& title, ftxui::Elements rows);
ftxui::Element label_value(const std::string& lbl, const std::string& val,
                           ftxui::Color val_color = ftxui::Color::Default);
ftxui::Element mempool_stats_box(const AppState& s);
