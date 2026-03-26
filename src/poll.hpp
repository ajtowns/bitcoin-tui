#pragma once

#include <functional>
#include <mutex>

#include "guarded.hpp"
#include "rpc_client.hpp"
#include "state.hpp"

// Two-phase RPC poll: commits core data (blockchain/network/mempool/peers) and
// calls on_core_ready before the slower per-block stats fetches.
void poll_rpc(RpcClient& rpc, Guarded<AppState>& state,
              const std::function<void()>& on_core_ready = nullptr);
