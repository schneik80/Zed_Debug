#!/usr/bin/env bash
#
# zed-enable-addin.sh
#
# Apply the Zed/debugpy debugging recipe to an Autodesk Fusion add-in.
# The add-in folder can live anywhere — Fusion's Scripts and Add-Ins
# dialog supports loading add-ins from arbitrary paths (green "+" button
# under "My Add-Ins" → browse to the folder). No symlinks needed.
#
# Usage:
#   ./scripts/zed-enable-addin.sh /path/to/addin
#
# What it does:
#   - Installs debugpy into Fusion's user site (via setup-fusion-debug.sh).
#   - Writes .zed/settings.json, .env, .zed/debug.json into the add-in.
#   - Removes any pre-existing .vscode/ folder (Zed owns debugging now).
#   - Adds .zed/ and .env to .gitignore if the folder is a git repo.
#   - Prints (does NOT auto-edit) the two code blocks you need to paste
#     into the add-in's main .py and config.py — these are too codebase-
#     specific to patch blindly.
#   - Prints final instructions on how to register the add-in in Fusion.

set -euo pipefail

if [ "$#" -ne 1 ]; then
    echo "usage: $0 /path/to/addin" >&2
    exit 1
fi

ADDIN_DIR="$(cd "$1" && pwd)"
ADDIN_NAME="$(basename "$ADDIN_DIR")"
MAIN_PY="$ADDIN_DIR/$ADDIN_NAME.py"
CONFIG_PY="$ADDIN_DIR/config.py"

[ -f "$MAIN_PY" ]   || { echo "no $MAIN_PY — expected main file matching folder name" >&2; exit 1; }
[ -f "$CONFIG_PY" ] || { echo "no $CONFIG_PY — is this a Fusion add-in folder?" >&2; exit 1; }

echo "Add-in name: $ADDIN_NAME"
echo "Add-in dir : $ADDIN_DIR"
echo

# Install debugpy and write .zed/settings.json + .env directly into the
# target add-in (no intermediate copy).
"$(cd "$(dirname "$0")" && pwd)/setup-fusion-debug.sh" "$ADDIN_DIR"

if [ -d "$ADDIN_DIR/.vscode" ]; then
    echo "==> Removing $ADDIN_DIR/.vscode (Zed owns debugging now)"
    rm -rf "$ADDIN_DIR/.vscode"
fi

# If the add-in is a git repo, make sure .zed/ is gitignored. .env is
# already covered by the standard Python gitignore template in most repos,
# but we add it as a safety net if missing.
if git -C "$ADDIN_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    GITIGNORE="$ADDIN_DIR/.gitignore"
    touch "$GITIGNORE"
    added=0
    if ! grep -qxE '\.zed/?' "$GITIGNORE"; then
        {
            echo ""
            echo "# Zed debugger config — regenerated per machine by NewAddIn/scripts/zed-enable-addin.sh"
            echo ".zed/"
        } >> "$GITIGNORE"
        added=1
    fi
    if ! grep -qxE '\.env' "$GITIGNORE"; then
        echo ".env" >> "$GITIGNORE"
        added=1
    fi
    [ "$added" = 1 ] && echo "==> Updated $GITIGNORE"
fi

echo "==> Writing $ADDIN_DIR/.zed/debug.json"
mkdir -p "$ADDIN_DIR/.zed"
cat > "$ADDIN_DIR/.zed/debug.json" <<JSON
[
  {
    "adapter": "Debugpy",
    "label": "Attach to Fusion ($ADDIN_NAME)",
    "request": "attach",
    "connect": { "host": "127.0.0.1", "port": 5678 },
    "cwd": "\$ZED_WORKTREE_ROOT",
    "justMyCode": true
  }
]
JSON

cat <<'EOF'

==> Code changes you still need to make by hand (intentional — these are
    too add-in-specific to patch blindly):

# --- Add to config.py ---
# When True, start a debugpy server on startup so Zed (or any DAP client)
# can attach. Leave False for shipping builds.
WAIT_FOR_DEBUGGER = False
DEBUGGER_PORT = 5678
DEBUGGER_BLOCK_UNTIL_ATTACHED = False  # set True to pause run() until Zed attaches

# --- Add to the top of the add-in's main .py (next to the other imports) ---
from . import config

# --- Wrap the body of run() ---
def run(context):
    try:
        if config.WAIT_FOR_DEBUGGER:
            import debugpy
            if not getattr(debugpy, "_fusion_listening", False):
                try:
                    debugpy.listen(
                        ("127.0.0.1", config.DEBUGGER_PORT),
                        in_process_debug_adapter=True,
                    )
                except RuntimeError:
                    pass
                debugpy._fusion_listening = True
            if config.DEBUGGER_BLOCK_UNTIL_ATTACHED:
                debugpy.wait_for_client()
        commands.start()   # or whatever the existing body of run() was
    except:
        futil.handle_error('run')

EOF

echo "==> Done."
echo
echo "Next:"
echo "  1. Open Zed at:  $ADDIN_DIR"
echo "  2. Register the add-in in Fusion (only needed once per machine):"
echo "       Fusion → File → Scripts and Add-Ins → 'Add-Ins' tab"
echo "       → click the green '+' next to 'My Add-Ins' → browse to:"
echo "         $ADDIN_DIR"
echo "     Fusion remembers the path; you do not need a symlink under"
echo "     ~/Library/.../API/AddIns/."
echo "  3. Select the add-in in the list → Run."
echo
echo "Note: setup-fusion-debug.sh pointed Zed's Debugpy adapter at Fusion's"
echo "user-site debugpy via dap.Debugpy.binary in .zed/settings.json, so Zed"
echo "does NOT download debugpy on attach (required on offline / proxy-restricted"
echo "machines). Re-run setup-fusion-debug.sh after each Fusion update to refresh."
echo "In Zed's F4 picker choose 'Attach to Fusion ($ADDIN_NAME)', not the"
echo "auto-generated per-file / project-root scenarios."
