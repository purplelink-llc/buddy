#!/usr/bin/env python3
"""Connect or disconnect Buddy's hook in ~/.claude/settings.json.

    python3 scripts/hooks.py install     copies build/buddy-hook to ~/.claude/hooks and adds it
    python3 scripts/hooks.py uninstall   removes every Buddy entry (and the hook)

Run ./build.sh first. Other hooks are left alone. A timestamped backup is written
before any change, and nothing is written when nothing changes.
"""
import json
import shutil
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CLAUDE = Path.home() / ".claude"
SETTINGS = CLAUDE / "settings.json"
HOOK = CLAUDE / "hooks" / "buddy-hook"
OLD_HOOK = CLAUDE / "hooks" / "buddy-hook.sh"
EVENTS = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
          "PermissionRequest", "Notification", "Stop", "StopFailure", "SessionEnd"]


def is_buddy(group):
    return any("buddy-hook" in h.get("command", "") for h in group.get("hooks", []))


def strip(hooks):
    for event in list(hooks):
        hooks[event] = [g for g in hooks[event] if not is_buddy(g)]
        if not hooks[event]:
            del hooks[event]


def main():
    action = sys.argv[1] if len(sys.argv) > 1 else ""
    if action not in ("install", "uninstall"):
        sys.exit(__doc__)

    original = SETTINGS.read_text() if SETTINGS.exists() else "{}"
    settings = json.loads(original)
    hooks = settings.setdefault("hooks", {})
    strip(hooks)

    if action == "install":
        built = ROOT / "build" / "buddy-hook"
        if not built.exists():
            sys.exit("build/buddy-hook is missing: run ./build.sh first")
        HOOK.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(built, HOOK)
        HOOK.chmod(0o755)
        for event in EVENTS:
            # The event name lets the hook trim PostToolUse payloads without parsing JSON.
            command = f'"$HOME/.claude/hooks/buddy-hook" {event}'
            hooks.setdefault(event, []).append(
                {"hooks": [{"type": "command", "command": command, "timeout": 5}]})
    else:
        if not hooks:
            del settings["hooks"]
        HOOK.unlink(missing_ok=True)
    OLD_HOOK.unlink(missing_ok=True)

    if json.loads(original) == settings:
        print(f"{SETTINGS} already up to date")
        return
    if SETTINGS.exists():
        backup = SETTINGS.with_name(f"settings.json.bak-buddy-{time.strftime('%Y%m%d-%H%M%S')}")
        shutil.copy2(SETTINGS, backup)
        print(f"backup: {backup}")
    SETTINGS.write_text(json.dumps(settings, indent=2, ensure_ascii=False) + "\n")
    print(f"{action}ed Buddy hooks in {SETTINGS}")


if __name__ == "__main__":
    main()
