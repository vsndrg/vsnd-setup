#!/bin/bash
# Pins the newest pushed commits of vsndrg/aerospace and vsndrg/vsndbar (the
# submodule entries install.sh reads) and commits that. No submodule checkout
# needed. Push afterwards, or pass --push.
#
# The README's Keys table and install.sh's PATCHED_ONLY_FLAGS follow
# aerospace.toml by hand: the bindings that changed between the pins are
# printed (read from ~/.config/aerospace, when it has both commits).
set -euo pipefail
cd "$(dirname "$0")"

push=0
[[ "${1:-}" == "--push" ]] && push=1

changed=()
aerospace_old="" aerospace_new=""
for repo in aerospace vsndbar; do
  new="$(git ls-remote "https://github.com/vsndrg/$repo.git" refs/heads/main | cut -f1)"
  old="$(git ls-tree HEAD "$repo" | awk '{print $3}')"
  [[ -n "$new" ]] || { echo "can't read vsndrg/$repo" >&2; exit 1; }
  if [[ "$new" != "$old" ]]; then
    git update-index --add --cacheinfo "160000,$new,$repo"
    changed+=("$repo ${old:0:7}→${new:0:7}")
    if [[ "$repo" == aerospace ]]; then aerospace_old="$old" aerospace_new="$new"; fi
  fi
done

if (( ${#changed[@]} == 0 )); then
  echo "pins are up to date"
  exit 0
fi
git commit -q -m "Pin $(IFS=,; echo "${changed[*]}" | sed 's/,/, /g')"
git log -1 --format=%s

config="$HOME/.config/aerospace"
if [[ -n "$aerospace_new" ]]; then
  if git -C "$config" cat-file -e "$aerospace_new^{commit}" 2>/dev/null \
    && git -C "$config" cat-file -e "$aerospace_old^{commit}" 2>/dev/null; then
    keys="$(git -C "$config" diff "$aerospace_old" "$aerospace_new" -- aerospace.toml | grep -E '^[+-] +[a-z0-9-]+ = ' || true)"
    if [[ -n "$keys" ]]; then
      echo
      echo "aerospace.toml bindings changed — check the README's Keys table and install.sh's PATCHED_ONLY_FLAGS:"
      echo "$keys"
    fi
  else
    echo "($config doesn't have ${aerospace_old:0:7} and ${aerospace_new:0:7}: binding changes not checked)"
  fi
fi

if (( push )); then git push -q && echo "pushed"; fi
