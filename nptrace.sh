#!/bin/sh

# ---- src/header.sh ----
# nullplatform tracing for POSIX shell — producer SDK for the nullplatform
# tracing API. Zero runtime dependencies beyond curl and the POSIX toolset.
#
# Generated file: edit src/*.sh and run ./build.sh.

if [ -n "${NP_TRACE_LOADED:-}" ]; then
  return 0 2>/dev/null || exit 0
fi
NP_TRACE_LOADED=1
NP_TRACE_VERSION="0.1.0"

# ---- src/compat.sh ----
# compat.sh — portability shims. The ONLY place OS differences live.

# ---- src/json.sh ----
# json.sh — JSON emission. The SDK only ever WRITES JSON.

# ---- src/uuid.sh ----
# uuid.sh — UUIDv7 generation.

# ---- src/identity.sh ----
# identity.sh — the node identity grammar, ported from the wire contract.

# ---- src/wire.sh ----
# wire.sh — contract constants, ported from the wire contract.

# ---- src/state.sh ----
# state.sh — the on-disk node registry.

# ---- src/spool.sh ----
# spool.sh — the emit hot path.

# ---- src/http.sh ----
# http.sh — the only module that touches the network.

# ---- src/flush.sh ----
# flush.sh — the spool drain.

# ---- src/api.sh ----
# api.sh — the public producer surface.

# ---- src/cli.sh ----
# cli.sh — argv to function shim (Phase 2).
