#!/bin/bash
# Pins the newest pushed commits of vsndrg/aerospace and vsndrg/vsndbar (the
# submodule entries install.sh reads) and commits that. No submodule checkout
# needed. Push afterwards.
set -euo pipefail
cd "$(dirname "$0")"

changed=()
for repo in aerospace vsndbar; do
  new="$(git ls-remote "https://github.com/vsndrg/$repo.git" refs/heads/main | cut -f1)"
  old="$(git ls-tree HEAD "$repo" | awk '{print $3}')"
  [[ -n "$new" ]] || { echo "can't read vsndrg/$repo" >&2; exit 1; }
  if [[ "$new" != "$old" ]]; then
    git update-index --add --cacheinfo "160000,$new,$repo"
    changed+=("$repo ${old:0:7}→${new:0:7}")
  fi
done

if (( ${#changed[@]} == 0 )); then
  echo "pins are up to date"
  exit 0
fi
git commit -q -m "Pin $(IFS=,; echo "${changed[*]}" | sed 's/,/, /g')"
git log -1 --format=%s
