#!/bin/bash
# uninstall.command: Just Aloud uninstaller for macOS
# Double-click this file in Finder to run.

set -e

# Guard Terminal.app-specific AppleScript (user may use iTerm2, Warp, etc.)
_IS_TERMINAL_APP=false
[ "$TERM_PROGRAM" = "Apple_Terminal" ] && _IS_TERMINAL_APP=true

# ── Capture Terminal window ID for cleanup ────────────────────────
_TERM_WINDOW_ID=""
if $_IS_TERMINAL_APP; then
    _TERM_WINDOW_ID=$(osascript -e 'tell application "Terminal" to id of front window' 2>/dev/null || true)
fi

# ── Cleanup ───────────────────────────────────────────────────────
cleanup() {
    if $_IS_TERMINAL_APP && [ -n "$_TERM_WINDOW_ID" ]; then
        osascript -e "tell application \"Terminal\" to close (every window whose id is $_TERM_WINDOW_ID)" 2>/dev/null &
    fi
}
trap cleanup EXIT

result=$(osascript -e 'button returned of (display dialog "This will completely remove Just Aloud:\n\n  • Stop and remove the menu bar app\n  • Remove Accessibility permission\n  • Remove the speak script\n  • Remove the Services workflow\n  • Remove settings and config\n  • Remove the local TTS environment\n  • Remove the API key from Keychain\n  • Remove the login item (if set)" with title "Just Aloud" buttons {"Cancel", "Uninstall"} default button "Cancel" with icon caution)' 2>/dev/null || true)
[ "$result" = "Uninstall" ] || exit 0

printf '\033[2J\033[H'
printf '\n'
printf '  \033[1mJust Aloud\033[0m — Uninstalling\n'
printf '  ───────────────────────\n\n'

step() { printf '  \033[32m✓\033[0m  %s\n' "$1"; }

# ── Quit the menu bar app ─────────────────────────────────────────
pkill -x "JustAloud" 2>/dev/null || true
sleep 0.5
step "Menu bar app stopped"

# ── Remove Accessibility permission ───────────────────────────────
tccutil reset Accessibility space.exlumina.justaloud 2>/dev/null || true
step "Accessibility permission removed"

# ── Remove the app bundle ─────────────────────────────────────────
rm -rf "$HOME/Applications/Just Aloud.app"
step "App bundle removed"

# ── Remove scripts ────────────────────────────────────────────────
rm -f "$HOME/.local/bin/just-aloud"
rm -f "$HOME/.local/bin/just-aloud-tts-server.py"
rm -f "$HOME/.local/bin/just-aloud-normalize.py"
rm -f "$HOME/.local/bin/just-aloud-install-local"
rm -f "$HOME/.local/bin/just-aloud-uninstall"
rm -f "$HOME/.local/bin/just-aloud-audio"
step "Scripts removed"

# ── Remove the Services workflow ──────────────────────────────────
rm -rf "$HOME/Library/Services/Speak Selection with Just Aloud.workflow"
step "Quick Action removed"

# ── Remove config directory ───────────────────────────────────────
rm -rf "$HOME/.config/just-aloud"
step "Config removed"

# ── Kill TTS daemon if running ───────────────────────────────────
if [ -f "$HOME/.local/share/just-aloud/tts_server.pid" ]; then
    _daemon_pid=$(cat "$HOME/.local/share/just-aloud/tts_server.pid" 2>/dev/null)
    if [ -n "$_daemon_pid" ] && kill -0 "$_daemon_pid" 2>/dev/null; then
        if ps -p "$_daemon_pid" -o args= 2>/dev/null | grep -q tts_server; then
            kill "$_daemon_pid" 2>/dev/null || true
        fi
    fi
fi

# ── Remove local TTS data (venv, daemon, standalone Python) ────
rm -rf "$HOME/.local/share/just-aloud"
step "Local TTS data removed"

# ── Remove API key from Keychain ──────────────────────────────────
security delete-generic-password \
    -a "just-aloud" \
    -s "just-aloud-api-key" 2>/dev/null || true
step "API key removed from Keychain"

# ── Remove login item ────────────────────────────────────────────
osascript -e 'tell application "System Events" to delete (every login item whose name is "Just Aloud")' 2>/dev/null || true
step "Login item removed"

# ── Remove installer lock if stale ────────────────────────────────
rmdir /tmp/just_aloud_install.lock 2>/dev/null || rm -rf /tmp/just_aloud_install.lock 2>/dev/null || true

printf '\n  \033[32mJust Aloud has been removed.\033[0m\n\n'

# ── Done ──────────────────────────────────────────────────────────
osascript -e 'display dialog "Just Aloud has been removed.\n\nIf you assigned a Services keyboard shortcut, remove it manually:\nSystem Settings → Keyboard → Keyboard Shortcuts → Services" with title "Just Aloud" buttons {"Done"} default button "Done" with icon note' 2>/dev/null || true
