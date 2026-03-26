#include <string>

#include <ftxui/dom/elements.hpp>
#include <ftxui/screen/color.hpp>

#include "format.hpp"
#include "render.hpp"

using namespace ftxui;

Element section_box(const std::string& title, Elements rows) {
    Elements content;
    content.reserve(rows.size() + 1);
    content.push_back(text(" " + title + " ") | bold | color(Color::Gold1));
    for (auto& r : rows)
        content.push_back(std::move(r));
    return vbox(std::move(content)) | border;
}

Element label_value(const std::string& lbl, const std::string& val, Color val_color) {
    return hbox({
        text(lbl) | color(Color::GrayDark),
        text(val) | color(val_color) | bold,
    });
}

Element mempool_stats_box(const AppState& s) {
    double usage_frac  = s.mempool_max > 0 ? static_cast<double>(s.mempool_usage) /
                                                static_cast<double>(s.mempool_max)
                                           : 0.0;
    Color  usage_color = usage_frac > 0.8   ? Color::Red
                         : usage_frac > 0.5 ? Color::Yellow
                                            : Color::Cyan;
    return section_box(
        "Mempool",
        {
            label_value("  Transactions    : ", fmt_int(s.mempool_tx)),
            label_value("  Virtual size    : ", fmt_bytes(s.mempool_bytes)),
            label_value("  Total fees      : ", fmt_btc(s.total_fee)),
            label_value("  Min relay fee   : ", fmt_satsvb(s.mempool_min_fee)),
            hbox({
                text("  Memory usage    : ") | color(Color::GrayDark),
                text(fmt_bytes(s.mempool_usage) + " / " + fmt_bytes(s.mempool_max)) | bold,
                text("  "),
                gauge(static_cast<float>(usage_frac)) | flex | color(usage_color),
                text(" " + std::to_string(static_cast<int>(usage_frac * 100)) + "%  ") | bold |
                    color(usage_color),
            }),
        });
}
