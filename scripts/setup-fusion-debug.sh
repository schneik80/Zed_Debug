#!/usr/bin/env bash
#
# setup-fusion-debug.sh
#
# Run this once on a fresh machine AND after every Autodesk Fusion auto-update.
# It:
#   1. Auto-detects the currently-installed Fusion's bundled Python
#      (the webdeploy hash rotates on every upgrade, so we never hardcode).
#   2. Bootstraps pip into Fusion's Python via ensurepip (Fusion ships
#      without pip).
#   3. Installs/upgrades debugpy into Fusion's user site-packages.
#   4. Rewrites the webdeploy-path lines in this add-in's
#      .zed/settings.json and .env so pyright + tooling stay valid after
#      the Fusion upgrade.
#
# Usage:
#   ./scripts/setup-fusion-debug.sh                  # refresh this add-in
#   ./scripts/setup-fusion-debug.sh /path/to/addin   # refresh another add-in
#
# Re-run any time `lsof -nP -iTCP:5678 -sTCP:LISTEN` or pyright import
# resolution stops working after a Fusion upgrade — it's almost always
# the webdeploy hash rotating.

set -euo pipefail

WEBDEPLOY="$HOME/Library/Application Support/Autodesk/webdeploy/production"
if [ "$#" -ge 1 ]; then
    ADDIN_DIR="$(cd "$1" && pwd)"
else
    ADDIN_DIR="$(cd "$(dirname "$0")/.." && pwd)"
fi

find_fusion_python() {
    local d py
    [ -d "$WEBDEPLOY" ] || { echo "no webdeploy dir at $WEBDEPLOY" >&2; return 1; }
    # newest-first; pick the first webdeploy that has a working python.
    while IFS= read -r d; do
        py="$WEBDEPLOY/$d/Autodesk Fusion.app/Contents/Frameworks/Python.framework/Versions/Current/bin/python"
        if [ -x "$py" ]; then
            printf '%s\n' "$py"
            return 0
        fi
    done < <(ls -1t "$WEBDEPLOY")
    return 1
}

FUSION_PY="$(find_fusion_python)" || { echo "could not locate Fusion's Python" >&2; exit 1; }
FUSION_ROOT="${FUSION_PY%/Autodesk Fusion.app/*}"
WEBDEPLOY_HASH="$(basename "$FUSION_ROOT")"
FUSION_APP="$FUSION_ROOT/Autodesk Fusion.app"
FUSION_API_PACKAGES="$FUSION_ROOT/Api/Python/packages"
FUSION_API_DEFS="$HOME/Library/Application Support/Autodesk/Autodesk Fusion 360/API/Python/defs"

echo "Fusion Python : $FUSION_PY"
echo "Webdeploy hash: $WEBDEPLOY_HASH"
echo "Add-in dir    : $ADDIN_DIR"
echo

echo "==> Bootstrapping pip via ensurepip --user"
"$FUSION_PY" -m ensurepip --user --upgrade || true

echo "==> Installing/upgrading debugpy into Fusion's user site"
if ! "$FUSION_PY" -m pip install --user --upgrade --quiet debugpy; then
    echo "    pip install failed (offline / proxy-restricted network?)."
    echo "    Will reuse an existing debugpy if one is already present."
fi

# The debugpy 'adapter' directory (…/site-packages/debugpy/adapter) is what Zed's
# Debugpy DAP adapter is pointed at below. Empty if debugpy is unavailable.
echo "==> Verifying debugpy"
DEBUGPY_ADAPTER=""
if "$FUSION_PY" -c "import debugpy" >/dev/null 2>&1; then
    "$FUSION_PY" -c "import debugpy; print('  debugpy', debugpy.__version__, 'at', debugpy.__file__)"
    FUSION_USER_SITE="$("$FUSION_PY" -c 'import site; print(site.getusersitepackages())')"
    DEBUGPY_ADAPTER="$FUSION_USER_SITE/debugpy/adapter"
else
    echo "  debugpy is NOT available in Fusion's user site and could not be installed."
    echo "  Zed's debugger needs it. If PyPI is blocked, copy an install in offline:"
    echo "    US=\"\$('$FUSION_PY' -c 'import site;print(site.getusersitepackages())')\""
    echo "    cp -R /path/to/debugpy /path/to/debugpy-*.dist-info \"\$US/\""
fi

# Zed's Debugpy adapter otherwise downloads its own copy of debugpy from PyPI on
# every attach, which fails offline / behind a proxy. Zed reads
# dap.<adapter>.binary (crates/project/.../dap_store.rs -> user_installed_path)
# as the adapter path and SKIPS the download when it is set. Point it at the
# user-site adapter so debugging works with no network. Omitted when debugpy is
# unavailable (keeps the JSON valid — pyright still works).
DAP_BLOCK=""
if [ -n "$DEBUGPY_ADAPTER" ]; then
    DAP_BLOCK=$(printf ',\n  "dap": {\n    "Debugpy": {\n      "binary": "%s"\n    }\n  }' "$DEBUGPY_ADAPTER")
fi

echo "==> Refreshing $ADDIN_DIR/.zed/settings.json"
mkdir -p "$ADDIN_DIR/.zed"
cat > "$ADDIN_DIR/.zed/settings.json" <<JSON
{
  "lsp": {
    "pyright": {
      "settings": {
        "python": {
          "analysis": {
            "extraPaths": [
              "$FUSION_API_DEFS"
            ]
          },
          "pythonPath": "$FUSION_PY"
        }
      }
    }
  }$DAP_BLOCK
}
JSON

echo "==> Refreshing $ADDIN_DIR/.env"
cat > "$ADDIN_DIR/.env" <<ENV
PYTHONPATH=$FUSION_API_PACKAGES
ENV

echo
if [ -n "$DEBUGPY_ADAPTER" ]; then
    echo "Zed debug adapter wired to: $DEBUGPY_ADAPTER"
    echo "  (Zed uses this instead of downloading debugpy — works offline/behind a proxy.)"
fi
echo "Done. Next:"
echo "  1. Set WAIT_FOR_DEBUGGER = True in $ADDIN_DIR/config.py"
echo "  2. In Fusion: Scripts and Add-Ins -> Run (NOT Debug)"
echo "  3. Verify: lsof -nP -iTCP:5678 -sTCP:LISTEN"
echo "  4. In Zed: F4 -> Attach to Fusion"
