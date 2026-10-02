#!/usr/bin/env python3
"""macOS settings vsnd-setup changes, and puts back on uninstall.

    settings.py apply STATE GROUP...   (groups: menubar, screenshots)
    settings.py restore STATE

The first time a setting is changed its previous value (or its absence) is
saved in STATE (JSON), so `restore` brings back what the Mac had before the
first install, not what a later reinstall found.
"""
import json
import os
import plistlib
import re
import subprocess
import sys

HOTKEYS = ("com.apple.symbolichotkeys", "AppleSymbolicHotKeys")
HYPER = 1966080  # cmd + shift + option + control


def hotkey(char, keycode, modifiers):
    return {"enabled": True, "value": {"parameters": [char, keycode, modifiers], "type": "standard"}}


GROUPS = {
    # The bar sits under the auto-hidden menu bar (Settings → Control Center →
    # Automatically hide and show the menu bar: Always).
    "menubar": {
        ("NSGlobalDomain", "_HIHideMenuBar"): True,
        ("NSGlobalDomain", "AppleMenuBarVisibleInFullscreen"): False,
        ("com.apple.controlcenter", "AutoHideMenuBarOption"): 0,
    },
    # Karabiner's F3 / F4 send hyper-3 / hyper-4: the system shortcuts for
    # "save picture of screen / selected area as a file" are moved there;
    # "screenshot and recording options" is ctrl-shift-cmd-5 (F5 opens it).
    "screenshots": {
        HOTKEYS + ("28",): hotkey(51, 20, HYPER),
        HOTKEYS + ("30",): hotkey(52, 21, HYPER),
        HOTKEYS + ("184",): hotkey(53, 23, 1441792),
        ("com.apple.screencapture", "location"): "~/Screenshots",
        ("com.apple.screencapture", "location-screenshot"): "~/Screenshots",
        ("com.apple.screencapture", "location-screenrecording"): "~/Screenshots",
    },
}


def domain_plist(domain):
    out = subprocess.run(["defaults", "export", domain, "-"], capture_output=True).stdout
    return plistlib.loads(out) if out else {}


def read(path):
    value = domain_plist(path[0]).get(path[1])
    if len(path) == 3:
        value = (value or {}).get(path[2])
    return value


def xml(value):
    """A value as the plist fragment `defaults write` accepts."""
    text = plistlib.dumps(value).decode()
    return re.search(r"<plist[^>]*>\s*(.*)\s*</plist>", text, re.S).group(1)


def write(path, value):
    domain, key = path[:2]
    if len(path) == 3:
        whole = dict(domain_plist(domain).get(key) or {})
        if value is None:
            whole.pop(path[2], None)
        else:
            whole[path[2]] = value
        value = whole
    if value is None:
        subprocess.run(["defaults", "delete", domain, key], capture_output=True)
        return
    if isinstance(value, bool):
        args = ["-bool", "true" if value else "false"]
    elif isinstance(value, int):
        args = ["-int", str(value)]
    elif isinstance(value, str):
        args = ["-string", value]
    else:
        args = [xml(value)]
    subprocess.run(["defaults", "write", domain, key] + args, check=True)


def key_of(path):
    return "|".join(path)


def path_of(key):
    return tuple(key.split("|"))


def take_effect(paths):
    """Make changed settings live without logging out."""
    domains = {p[0] for p in paths}
    if HOTKEYS[0] in domains:
        subprocess.run(
            ["/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings", "-u"],
            capture_output=True,
        )
    if "com.apple.screencapture" in domains:
        subprocess.run(["killall", "SystemUIServer"], capture_output=True)
    if "NSGlobalDomain" in domains:
        hide = "true" if read(("NSGlobalDomain", "_HIHideMenuBar")) else "false"
        script = f'tell application "System Events" to tell dock preferences to set autohide menu bar to {hide}'
        if subprocess.run(["osascript", "-e", script], capture_output=True).returncode != 0:
            print("  menu bar: log out and back in for the auto-hide setting to apply")


def load(state_path):
    try:
        with open(state_path) as f:
            return json.load(f)
    except FileNotFoundError:
        return {}


def save(state_path, state):
    os.makedirs(os.path.dirname(state_path), exist_ok=True)
    with open(state_path, "w") as f:
        json.dump(state, f, indent=2)


def main():
    action, state_path, groups = sys.argv[1], sys.argv[2], sys.argv[3:]
    state = load(state_path)
    changed = []
    if action == "apply":
        for group in groups:
            for path, value in GROUPS[group].items():
                current = read(path)
                state.setdefault(key_of(path), current)
                if current != value:
                    write(path, value)
                    changed.append(path)
        save(state_path, state)
        if "screenshots" in groups:
            os.makedirs(os.path.expanduser("~/Screenshots"), exist_ok=True)
    elif action == "restore":
        for key, value in list(state.items()):
            path = path_of(key)
            if read(path) != value:
                write(path, value)
                changed.append(path)
            del state[key]
        save(state_path, state)
    take_effect(changed)
    print(f"settings: {len(changed)} changed" if changed else "settings: already up to date")


if __name__ == "__main__":
    main()
