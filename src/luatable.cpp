#include "luatable.hpp"

#include <algorithm>
#include <cmath>
#include <ctime>
#include <map>

std::optional<ColumnType> parse_column_type(const std::string& s) {
    if (s.empty() || s == "string")
        return ColumnType::String;
    if (s == "number")
        return ColumnType::Number;
    if (s == "timestamp")
        return ColumnType::Timestamp;
    if (s == "duration")
        return ColumnType::Duration;
    if (s == "bytes")
        return ColumnType::Bytes;
    if (s == "hash")
        return ColumnType::Hash;
    return std::nullopt;
}

std::string format_cell(ColumnType type, const CellData& data) {
    char buf[64];
    switch (type) {
    case ColumnType::Timestamp: {
        double  value = std::holds_alternative<double>(data) ? std::get<double>(data) : 0.0;
        auto    sec   = static_cast<time_t>(value);
        double  frac  = value - sec;
        std::tm tm{};
        localtime_r(&sec, &tm);
        int ms = static_cast<int>(frac * 1000);
        snprintf(buf, sizeof(buf), "%02d:%02d:%02d.%03d", tm.tm_hour, tm.tm_min, tm.tm_sec, ms);
        return buf;
    }
    case ColumnType::Duration: {
        double value = std::holds_alternative<double>(data) ? std::get<double>(data) : 0.0;
        if (value < 1.0) {
            snprintf(buf, sizeof(buf), "%.0fms", value * 1000);
        } else if (value < 60.0) {
            snprintf(buf, sizeof(buf), "%.3fs", value);
        } else {
            int    mins = static_cast<int>(value) / 60;
            double secs = value - mins * 60;
            snprintf(buf, sizeof(buf), "%dm %.0fs", mins, secs);
        }
        return buf;
    }
    case ColumnType::Bytes: {
        double value = std::holds_alternative<double>(data) ? std::get<double>(data) : 0.0;
        if (value < 1000) {
            snprintf(buf, sizeof(buf), "%.0fB", value);
        } else if (value < 1000000) {
            snprintf(buf, sizeof(buf), "%.1fKB", value / 1000);
        } else {
            snprintf(buf, sizeof(buf), "%.2fMB", value / 1000000);
        }
        return buf;
    }
    case ColumnType::Number: {
        if (std::holds_alternative<int64_t>(data)) {
            return std::to_string(std::get<int64_t>(data));
        }
        double value = std::holds_alternative<double>(data) ? std::get<double>(data) : 0.0;
        if (value == std::floor(value)) {
            snprintf(buf, sizeof(buf), "%.0f", value);
        } else {
            snprintf(buf, sizeof(buf), "%g", value);
        }
        return buf;
    }
    case ColumnType::Hash:
    case ColumnType::String:
        if (std::holds_alternative<std::string>(data))
            return std::get<std::string>(data);
        if (std::holds_alternative<int64_t>(data))
            return std::to_string(std::get<int64_t>(data));
        if (std::holds_alternative<double>(data)) {
            snprintf(buf, sizeof(buf), "%g", std::get<double>(data));
            return buf;
        }
        return {};
    }
    return {};
}

static std::vector<ColumnDef> ensure_key_column(std::vector<ColumnDef> columns,
                                                const std::string&     key_column) {
    for (const auto& c : columns) {
        if (c.name == key_column)
            return columns;
    }
    columns.insert(columns.begin(), {key_column, "", ColumnType::Number});
    return columns;
}

LuaTable::LuaTable(const std::string& key_column, std::vector<ColumnDef> columns, std::string title,
                   bool no_header)
    : columns_(ensure_key_column(std::move(columns), key_column)), title_(std::move(title)),
      no_header_(no_header), key_index_(col_index(key_column)),
      rows_(std::set<Row, RowCompare>(RowCompare{key_index_})) {}

size_t LuaTable::col_index(const std::string& name) const {
    for (size_t i = 0; i < columns_.size(); ++i) {
        if (columns_[i].name == name)
            return i;
    }
    return columns_.size();
}

void LuaTable::update(const CellData& key, const std::map<std::string, CellValue>& data) {
    Row row;
    row.cells.resize(columns_.size());

    // Set key column
    row.cells[key_index_].data = key;

    for (const auto& [name, cell] : data) {
        size_t idx = col_index(name);
        if (idx < columns_.size()) {
            row.cells[idx] = cell;
        }
    }

    rows_.update([&](auto& rows) {
        // Remove existing row with this key
        for (auto it = rows.begin(); it != rows.end(); ++it) {
            if (it->cells[key_index_].data == key) {
                rows.erase(it);
                break;
            }
        }
        rows.insert(std::move(row));
    });
}

bool LuaTable::remove(const CellData& key) {
    return rows_.update([&](auto& rows) {
        for (auto it = rows.begin(); it != rows.end(); ++it) {
            if (it->cells[key_index_].data == key) {
                rows.erase(it);
                return true;
            }
        }
        return false;
    });
}

std::vector<std::string> LuaTable::keys() const {
    return rows_.access([&](const auto& rows) {
        std::vector<std::string> result;
        result.reserve(rows.size());
        for (const auto& row : rows) {
            result.push_back(format_cell(columns_[key_index_].type, row.cells[key_index_].data));
        }
        return result;
    });
}
