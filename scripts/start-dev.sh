#!/usr/bin/env bash
# Reliable local start: Jac client build needs bun (JAC_BUN or bundled).
# Microservice mode shells out to `jac build --client web`, which can SIGABRT on
# macOS (unversioned libcrypto). Prebuild via WebTarget so the gateway can skip.
set -euo pipefail
cd "$(dirname "$0")/.."

export PATH="${HOME}/.local/bin:${HOME}/.nvm/versions/node/v22.20.0/bin:/opt/homebrew/bin:/usr/local/bin:${PATH}"
if command -v bun >/dev/null 2>&1; then
  export JAC_BUN="$(command -v bun)"
fi

if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

echo "Prebuilding client bundle..."
jac run scripts/compile_client.jac

exec jac start --dev main.jac
