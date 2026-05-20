#!/usr/bin/env bash
#
# setup-fusion-debug.sh
#
# Run this once on a fresh machine AND after every Fusion 360 auto-update.
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
"$FUSION_PY" -m ensurepip --user --upgrade

echo "==> Installing/upgrading debugpy into Fusion's user site"
"$FUSION_PY" -m pip install --user --upgrade --quiet debugpy

echo "==> Verifying debugpy"
"$FUSION_PY" -c "import debugpy; print('  debugpy', debugpy.__version__, 'at', debugpy.__file__)"

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
  }
}
JSON

echo "==> Refreshing $ADDIN_DIR/.env"
cat > "$ADDIN_DIR/.env" <<ENV
PYTHONPATH=$FUSION_API_PACKAGES
ENV

echo
echo "Done. Next:"
echo "  1. Set WAIT_FOR_DEBUGGER = True in $ADDIN_DIR/config.py"
echo "  2. In Fusion: Scripts and Add-Ins -> Run (NOT Debug)"
echo "  3. Verify: lsof -nP -iTCP:5678 -sTCP:LISTEN"
echo "  4. In Zed: F4 -> Attach to Fusion 360"
