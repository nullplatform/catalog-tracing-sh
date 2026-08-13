# Security Policy

## Reporting a vulnerability

Please report security issues privately to security@nullplatform.com rather
than opening a public issue.

## Notes on this SDK

- **The bearer token is never exposed.** It is passed to `curl` via `--config`
  from a mode-600 file, never in argv, and every credential path suppresses
  shell xtrace — CI scripts routinely run with `set -x`, and shell options are
  global, so a sourced function would otherwise print the token into the build
  log. `test/unit/http.sh` contains a regression canary for this.
- **The SDK never verifies the JWT.** It only forwards it; the API performs
  verification and authorization. Do not treat any claim read here as trusted.
- **State lives in `NP_TRACE_DIR`** (default under `TMPDIR`). Spooled events
  contain whatever labels, io and explain text the producer supplied — treat the
  directory as containing application data and avoid pointing it at a shared or
  world-readable location.
