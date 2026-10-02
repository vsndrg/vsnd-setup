#!/usr/bin/env python3
"""Adds (or removes) the vsnd-setup keys in Karabiner-Elements' config.

    karabiner.py apply  RULES KARABINER_DIR
    karabiner.py remove RULES KARABINER_DIR

RULES is a complex-modifications asset (karabiner/vsnd-setup.json): its rules
go into the selected profile, replacing rules with the same description. F6
goes into the profile's fn_function_keys (it has to beat the default F6
mapping). Everything else in karabiner.json is left alone; the file is only
rewritten when something changes, after a backup next to it. The asset is also
copied to assets/complex_modifications, so the rules show in Karabiner's UI.
"""
import json
import os
import shutil
import sys
import time

F6 = {"from": {"key_code": "f6"}, "to": [{"shell_command": "~/.local/bin/vsndbar sleep"}]}


def is_ours_f6(entry):
    return entry.get("from", {}).get("key_code") == "f6" and any(
        "vsndbar sleep" in to.get("shell_command", "") for to in entry.get("to", [])
    )


def profile_of(config):
    profiles = config.setdefault("profiles", [])
    if not profiles:
        profiles.append({"name": "Default profile", "selected": True})
    return next((p for p in profiles if p.get("selected")), profiles[0])


def main():
    action, rules_path, kdir = sys.argv[1:4]
    with open(rules_path) as f:
        asset = json.load(f)
    ours = {r["description"] for r in asset["rules"]}

    # dotfile setups often symlink the file: write through the link
    path = os.path.realpath(os.path.join(kdir, "karabiner.json"))
    if os.path.exists(path):
        with open(path) as f:
            config = json.load(f)
    elif action == "apply":
        config = {}
    else:
        return
    before = json.dumps(config, sort_keys=True)

    profile = profile_of(config)
    rules = profile.setdefault("complex_modifications", {}).setdefault("rules", [])
    rules[:] = [r for r in rules if r.get("description") not in ours]
    fn_keys = profile.setdefault("fn_function_keys", [])
    if action == "apply":
        rules.extend(asset["rules"])
        fn_keys[:] = [k for k in fn_keys if k.get("from", {}).get("key_code") != "f6"] + [F6]
    else:
        fn_keys[:] = [k for k in fn_keys if not is_ours_f6(k)]

    asset_path = os.path.join(kdir, "assets", "complex_modifications", os.path.basename(rules_path))
    if action == "apply":
        os.makedirs(os.path.dirname(asset_path), exist_ok=True)
        shutil.copyfile(rules_path, asset_path)
    elif os.path.exists(asset_path):
        os.remove(asset_path)

    if json.dumps(config, sort_keys=True) == before:
        print("karabiner.json: already up to date")
        return
    if os.path.exists(path):
        backup = f"{path}.backup-{time.strftime('%Y%m%d-%H%M%S')}"
        shutil.copyfile(path, backup)
        print(f"karabiner.json: backed up to {backup}")
    os.makedirs(kdir, exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(config, f, indent=4, ensure_ascii=False)
        f.write("\n")
    os.replace(tmp, path)  # Karabiner reloads the file on change
    print("karabiner.json: " + ("rules added" if action == "apply" else "rules removed"))


if __name__ == "__main__":
    main()
