#!/usr/bin/env bash
#
# zed-enable-addin.sh
#
# Apply the Zed/debugpy debugging recipe to another Fusion add-in.
#
# Two layouts are supported:
#
#   (A) In-place: the add-in already lives under
#       ~/Library/Application Support/Autodesk/Autodesk Fusion 360/API/AddIns/<name>/
#       Just pass that path.
#
#   (B) ~/Source/: you develop in ~/Source/<name>/ and want Fusion to
#       load from there. Pass the ~/Source/<name>/ path; this script
#       creates the AddIns/<name>/ symlink for you and configures
#       pathMappings so breakpoints work across the symlink boundary.
#
# Usage:
#   ./scripts/zed-enable-addin.sh /path/to/addin
#
# What it does:
#   - Creates .zed/debug.json, .zed/settings.json, .env in the add-in
#     (using current webdeploy paths via setup-fusion-debug.sh first).
#   - Removes any pre-existing .vscode/ folder. Zed owns debugging now.
#   - For ~/Source/ layout: symlinks AddIns/<name> -> ~/Source/<name>.
#   - Prints (does NOT auto-edit) the two code blocks you need to paste
#     into the add-in's main .py and config.py — these are too codebase-
#     specific to patch blindly.

set -euo pipefail

if [ "$#" -ne 1 ]; then
    echo "usage: $0 /path/to/addin" >&2
    exit 1
fi

ADDIN_DIR="$(cd "$1" && pwd)"
ADDIN_NAME="$(basename "$ADDIN_DIR")"
MAIN_PY="$ADDIN_DIR/$ADDIN_NAME.py"
CONFIG_PY="$ADDIN_DIR/config.py"
FUSION_ADDINS="$HOME/Library/Application Support/Autodesk/Autodesk Fusion 360/API/AddIns"
FUSION_LOAD_PATH="$FUSION_ADDINS/$ADDIN_NAME"

[ -f "$MAIN_PY" ]   || { echo "no $MAIN_PY — expected main file matching folder name" >&2; exit 1; }
[ -f "$CONFIG_PY" ] || { echo "no $CONFIG_PY — is this a Fusion add-in folder?" >&2; exit 1; }

# Detect layout.
case "$ADDIN_DIR" in
    "$FUSION_ADDINS"/*)
        LAYOUT="in-place"
        LOCAL_ROOT="\${ZED_WORKTREE_ROOT}"
        REMOTE_ROOT="\${ZED_WORKTREE_ROOT}"
        ;;
    *)
        LAYOUT="source-symlink"
        LOCAL_ROOT="\${ZED_WORKTREE_ROOT}"
        REMOTE_ROOT="$FUSION_LOAD_PATH"
        ;;
esac

echo "Add-in name: $ADDIN_NAME"
echo "Add-in dir : $ADDIN_DIR"
echo "Layout     : $LAYOUT"
echo

# For ~/Source/ layout, ensure Fusion has a path to load the add-in from.
if [ "$LAYOUT" = "source-symlink" ]; then
    mkdir -p "$FUSION_ADDINS"
    if [ -L "$FUSION_LOAD_PATH" ]; then
        existing="$(readlink "$FUSION_LOAD_PATH")"
        if [ "$existing" = "$ADDIN_DIR" ]; then
            echo "==> Symlink already in place: $FUSION_LOAD_PATH -> $ADDIN_DIR"
        else
            echo "Refusing to overwrite existing symlink: $FUSION_LOAD_PATH -> $existing" >&2
            exit 1
        fi
    elif [ -e "$FUSION_LOAD_PATH" ]; then
        echo "Refusing to overwrite existing file/dir at $FUSION_LOAD_PATH" >&2
        exit 1
    else
        ln -s "$ADDIN_DIR" "$FUSION_LOAD_PATH"
        echo "==> Created symlink: $FUSION_LOAD_PATH -> $ADDIN_DIR"
    fi
fi

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
    "label": "Attach to Fusion 360 ($ADDIN_NAME)",
    "request": "attach",
    "connect": { "host": "127.0.0.1", "port": 5678 },
    "cwd": "\$ZED_WORKTREE_ROOT",
    "pathMappings": [
      {
        "localRoot": "$LOCAL_ROOT",
        "remoteRoot": "$REMOTE_ROOT"
      }
    ],
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
echo "    Open Zed at: $ADDIN_DIR"
if [ "$LAYOUT" = "source-symlink" ]; then
    echo "    Fusion will load the add-in from the symlink at:"
    echo "      $FUSION_LOAD_PATH"
fi
