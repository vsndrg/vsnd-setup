#!/bin/bash
# vsnd-setup: AeroSpace (patched) + VsndBar, the Liquid Glass bar, on macOS.
#
#   curl -fsSL https://raw.githubusercontent.com/vsndrg/vsnd-setup/main/install.sh | bash
#
#   install.sh [install] [--yes] [--no-karabiner] [--force]
#   install.sh update    [--yes] [--no-karabiner] [--force]
#   install.sh uninstall [--yes]
#
# Safe to run again: every step checks what is already there.
# Written for /bin/bash 3.2 (the one macOS ships).
set -euo pipefail

REPO="https://github.com/vsndrg/vsnd-setup.git"
SETUP_DIR="${VSND_SETUP_DIR:-$HOME/.config/vsnd-setup}"

# The patches are made for this AeroSpace release; the app and CLI come from
# its GitHub release (the same zip the Homebrew cask installs).
AEROSPACE_VERSION="0.20.3-Beta"
AEROSPACE_SHA256="9d6cc269b773cbcb392623982c4f0ba585a68120b6bb1d179fec1cb4de8e374f"
AEROSPACE_URL="https://github.com/nikitabobko/AeroSpace/releases/download/v$AEROSPACE_VERSION/AeroSpace-v$AEROSPACE_VERSION.zip"

CERT="aerospace-local-codesign"
STATE="$HOME/.local/state/vsnd-setup"
CACHE="$HOME/.cache/vsnd-setup"
SHARE="$HOME/.local/share/vsnd-setup"
PRISTINE="$HOME/.cache/aerospace-original.app"  # patches/build.sh swaps its binary into this
PYTHON=/usr/bin/python3

# --- output ------------------------------------------------------------------

if [[ -t 1 ]]; then
  BOLD=$'\033[1m' DIM=$'\033[2m' RED=$'\033[31m' YELLOW=$'\033[33m' GREEN=$'\033[32m' RESET=$'\033[0m'
else
  BOLD="" DIM="" RED="" YELLOW="" GREEN="" RESET=""
fi
step() { printf '\n%s==> %s%s\n' "$BOLD" "$*" "$RESET"; }
say()  { printf '    %s\n' "$*"; }
warn() { printf '    %s! %s%s\n' "$YELLOW" "$*" "$RESET"; NOTES+=("$*"); }
die()  { printf '\n%serror: %s%s\n' "$RED" "$*" "$RESET" >&2; exit 1; }

has_tty() { { : </dev/tty; } 2>/dev/null; }

YES=0
ask() {  # ask "question" → 0 for yes (the default)
  [[ $YES == 1 ]] && return 0
  has_tty || die "no terminal to ask \"$1\" — run with --yes"
  local answer
  read -r -p "    $1 [Y/n] " answer </dev/tty || return 1
  [[ -z "$answer" || "$answer" == [yY]* ]]
}

NOTES=()  # warnings and manual steps, repeated at the end
TODO=()

usage() {
  sed -n '2,10s/^# \{0,1\}//p' "${BASH_SOURCE[0]}"
  cat <<EOF

  install     clone the configs into ~/.config, build and install everything
  update      pull vsnd-setup, then install (configs move to the pinned commits
              unless they have local changes)
  uninstall   remove VsndBar, put back stock AeroSpace and the macOS settings

  --yes           don't ask
  --no-karabiner  skip Karabiner-Elements (F3–F6) and the screenshot settings
  --force         rebuild AeroSpace even if nothing changed
EOF
}

# --- checks ------------------------------------------------------------------

preflight() {
  [[ "$(uname -s)" == Darwin ]] || die "this is for macOS"
  [[ "$(uname -m)" == arm64 ]] || die "VsndBar is built for Apple Silicon (arm64)"
  local major
  major="$(sw_vers -productVersion | cut -d. -f1)"
  (( major >= 26 )) || die "macOS 26 or newer is needed (the bar is Liquid Glass); this is $(sw_vers -productVersion)"
  if ! xcode-select -p >/dev/null 2>&1; then
    xcode-select --install 2>/dev/null || true
    die "the Command Line Tools are needed: finish the installer macOS just opened, then run this again"
  fi
  local sdk
  sdk="$(xcrun --show-sdk-version 2>/dev/null | cut -d. -f1)"
  (( ${sdk:-0} >= 26 )) || die "the Command Line Tools have SDK ${sdk:-?}, 26+ is needed: update them in System Settings → Software Update"
}

ensure_brew() {
  if ! command -v brew >/dev/null 2>&1; then
    local b
    for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do
      if [[ -x "$b" ]]; then eval "$("$b" shellenv)"; break; fi
    done
  fi
  if ! command -v brew >/dev/null 2>&1; then
    step "Homebrew"
    say "Homebrew is needed (Karabiner-Elements; the aerospace CLI goes into its bin)."
    ask "Install Homebrew now?" || die "install Homebrew (https://brew.sh) and run this again"
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    eval "$(/opt/homebrew/bin/brew shellenv)"
  fi
  BREW_PREFIX="$(brew --prefix)"
}

# --- vsnd-setup itself ---------------------------------------------------------

# Run from a pipe (curl | bash) there is no checkout next to the script: fetch
# the whole thing and run it from there.
bootstrap() {
  local here=""
  [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]] && here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [[ -n "$here" && -f "$here/lib/karabiner.py" ]]; then
    HERE="$here"
    return
  fi
  preflight
  if [[ -d "$SETUP_DIR/.git" ]]; then
    git -C "$SETUP_DIR" pull -q --ff-only || die "couldn't update $SETUP_DIR (local changes?)"
  else
    git clone -q "$REPO" "$SETUP_DIR"
  fi
  # the pipe is stdin: questions are read from the terminal, if there is one
  if has_tty; then
    exec /bin/bash "$SETUP_DIR/install.sh" "$@" </dev/tty
  fi
  exec /bin/bash "$SETUP_DIR/install.sh" "$@" </dev/null
}

# commit of a component pinned by this checkout (the submodule entry)
pin() { git -C "$HERE" ls-tree HEAD "$1" | awk '{print $3}'; }

backup() {
  local to
  to="$1.backup-$(date +%Y%m%d-%H%M%S)"
  mv "$1" "$to"
  say "moved the existing $1 to $to"
  NOTES+=("your previous $(basename "$1") is in $to")
}

# Clones vsndrg/<name> into ~/.config/<name> at the pinned commit. An existing
# checkout of it is fast-forwarded to the pin, never moved back and never
# touched when it has local changes; anything else there is backed up.
sync_repo() {
  local name="$1" dest="$HOME/.config/$1" url="https://github.com/vsndrg/$1.git" want
  want="$(pin "$name")"
  [[ -n "$want" ]] || die "no pinned commit for $name in $HERE"
  if [[ -d "$dest/.git" ]] && git -C "$dest" remote get-url origin 2>/dev/null | grep -qE "vsndrg/$name(\.git)?$"; then
    git -C "$dest" cat-file -e "$want^{commit}" 2>/dev/null || git -C "$dest" fetch -q origin
    if git -C "$dest" merge-base --is-ancestor "$want" HEAD; then
      say "$dest: up to date"
    elif [[ -z "$(git -C "$dest" status --porcelain)" ]] && git -C "$dest" merge-base --is-ancestor HEAD "$want"; then
      git -C "$dest" merge -q --ff-only "$want"
      say "$dest: updated to ${want:0:7}"
    else
      warn "$dest has local changes or has diverged from ${want:0:7}: left as is"
    fi
  else
    [[ -e "$dest" || -L "$dest" ]] && backup "$dest"
    git clone -q "$url" "$dest"
    git -C "$dest" reset -q --hard "$want"
    say "$dest: cloned at ${want:0:7}"
  fi
}

# --- steps ---------------------------------------------------------------------

configs() {
  step "Configs → ~/.config/aerospace, ~/.config/vsndbar"
  mkdir -p "$HOME/.config"
  sync_repo aerospace
  sync_repo vsndbar
  # AeroSpace refuses to start with two configs
  [[ -e "$HOME/.aerospace.toml" ]] && backup "$HOME/.aerospace.toml"
  return 0
}

# A self-signed code signing certificate in the login keychain: AeroSpace and
# the bar are signed with it, so the Accessibility grant survives rebuilds.
certificate() {
  step "Code signing certificate \"$CERT\""
  if security find-identity -v -p codesigning | grep -q "\"$CERT\""; then
    say "already there"
    return
  fi
  local tmp
  tmp="$(mktemp -d)"
  if security find-identity -p codesigning | grep -q "\"$CERT\""; then
    security find-certificate -c "$CERT" -p > "$tmp/cert.pem"  # there, but not trusted
  else
    cat > "$tmp/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $CERT
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF
    # macOS' LibreSSL: its PKCS#12 is one `security import` reads
    /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$tmp/cert.cnf" \
      -keyout "$tmp/key.pem" -out "$tmp/cert.pem" 2>/dev/null
    /usr/bin/openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" -name "$CERT" \
      -passout pass:vsnd -out "$tmp/cert.p12"
    security import "$tmp/cert.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P vsnd -T /usr/bin/codesign >/dev/null
    say "created (login keychain)"
  fi
  say "macOS asks for your password to trust it for code signing"
  if ! security add-trusted-cert -r trustRoot -p codeSign -k "$HOME/Library/Keychains/login.keychain-db" "$tmp/cert.pem"; then
    warn "the certificate isn't trusted: builds are signed ad-hoc, Accessibility has to be granted again after each AeroSpace rebuild"
  fi
  rm -rf "$tmp"
}

install_aerospace() {
  step "AeroSpace $AEROSPACE_VERSION + patches"
  local release="$SHARE/AeroSpace-v$AEROSPACE_VERSION" zip="$CACHE/AeroSpace-v$AEROSPACE_VERSION.zip"
  if [[ ! -x "$release/bin/aerospace" ]]; then
    mkdir -p "$CACHE" "$SHARE"
    if [[ ! -f "$zip" ]] || ! shasum -a 256 "$zip" | grep -q "^$AEROSPACE_SHA256 "; then
      say "downloading $AEROSPACE_URL"
      curl -fL --progress-bar -o "$zip.part" "$AEROSPACE_URL"
      mv "$zip.part" "$zip"
    fi
    shasum -a 256 "$zip" | grep -q "^$AEROSPACE_SHA256 " || die "checksum mismatch: $zip"
    local tmp
    tmp="$(mktemp -d)"
    ditto -x -k "$zip" "$tmp"
    rm -rf "$release"
    mv "$tmp/AeroSpace-v$AEROSPACE_VERSION" "$release"
    rm -rf "$tmp"
    xattr -dr com.apple.quarantine "$release" 2>/dev/null || true
  fi

  # brew's cask would bring a newer, unpatched AeroSpace back on `brew upgrade`
  if brew list --cask aerospace >/dev/null 2>&1; then
    say "removing the Homebrew cask (its upgrades would replace the patched app)"
    # keep the app itself: build.sh compares its signer, a changed one resets
    # the Accessibility grant
    local kept=""
    if [[ -d /Applications/AeroSpace.app ]]; then
      kept="$(mktemp -d)"
      mv /Applications/AeroSpace.app "$kept/"
    fi
    brew uninstall --cask aerospace >/dev/null 2>&1 \
      || warn "couldn't uninstall the aerospace cask: don't let \`brew upgrade\` update it"
    if [[ -n "$kept" ]]; then
      rm -rf /Applications/AeroSpace.app
      mv "$kept/AeroSpace.app" /Applications/
      rmdir "$kept"
    fi
  fi
  ln -sf "$release/bin/aerospace" "$BREW_PREFIX/bin/aerospace"
  mkdir -p "$BREW_PREFIX/share/zsh/site-functions"
  ln -sf "$release/shell-completion/zsh/_aerospace" "$BREW_PREFIX/share/zsh/site-functions/_aerospace"
  say "CLI: $BREW_PREFIX/bin/aerospace"

  local version
  version="$(defaults read "$PRISTINE/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || true)"
  if [[ "$version" != "$AEROSPACE_VERSION" ]]; then
    rm -rf "$PRISTINE"
    ditto "$release/AeroSpace.app" "$PRISTINE"
  fi

  # rebuild only when the patches, the build script or the signer changed
  local patches="$HOME/.config/aerospace/patches" stamp signed_by="Signature=adhoc"
  stamp="$( { echo "$AEROSPACE_VERSION"; cat "$patches"/*.patch "$patches/build.sh"; } | shasum -a 256 | cut -c1-16)"
  security find-identity -v -p codesigning | grep -q "\"$CERT\"" && signed_by="Authority=$CERT"
  if [[ $FORCE == 0 && "$(cat "$STATE/aerospace.stamp" 2>/dev/null)" == "$stamp" ]] \
     && codesign -dvv /Applications/AeroSpace.app 2>&1 | grep -q "$signed_by"; then
    say "/Applications/AeroSpace.app: already built from these patches"
    return
  fi
  say "building (the first build fetches AeroSpace's sources and takes a few minutes)…"
  mkdir -p "$STATE"
  PATH="$BREW_PREFIX/bin:$PATH" "$patches/build.sh" --install 2>&1 | tee "$STATE/aerospace-build.log" | sed 's/^/    /'
  echo "$stamp" > "$STATE/aerospace.stamp"
  if grep -q "grant Accessibility" "$STATE/aerospace-build.log"; then
    TODO+=("AeroSpace needs Accessibility: allow it when macOS asks (System Settings → Privacy & Security → Accessibility)")
  fi
}

install_vsndbar() {
  step "VsndBar"
  make -s -C "$HOME/.config/vsndbar" install 2>&1 | sed 's/^/    /'
  say "~/Applications/VsndBar.app, LaunchAgent com.vsndrg.vsndbar, CLI ~/.local/bin/vsndbar"
}

setup_menubar() {
  step "Menu bar: hide automatically (the bar lives under it)"
  "$PYTHON" "$HERE/lib/settings.py" apply "$STATE/settings.json" menubar | sed 's/^/    /'
}

setup_karabiner() {
  step "Karabiner-Elements: F3/F4 screenshots, F5 screenshot toolbar, F6 sleep"
  if [[ ! -d "/Applications/Karabiner-Elements.app" ]]; then
    say "installing Karabiner-Elements (Homebrew asks for your password)"
    brew install --cask karabiner-elements
    open -a Karabiner-Elements || true
    TODO+=("Karabiner-Elements: follow its setup (allow the driver extension and Input Monitoring)")
  fi
  "$PYTHON" "$HERE/lib/karabiner.py" apply "$HERE/karabiner/vsnd-setup.json" "$HOME/.config/karabiner" | sed 's/^/    /'
  step "Screenshots: shortcuts for F3/F4, saved to ~/Screenshots"
  "$PYTHON" "$HERE/lib/settings.py" apply "$STATE/settings.json" screenshots | sed 's/^/    /'
}

summary() {
  printf '\n%s==> Done%s\n' "$GREEN$BOLD" "$RESET"
  local line
  for line in ${TODO[@]+"${TODO[@]}"}; do printf '    %s→%s %s\n' "$BOLD" "$RESET" "$line"; done
  for line in ${NOTES[@]+"${NOTES[@]}"}; do printf '    %s%s%s\n' "$DIM" "$line" "$RESET"; done
  cat <<EOF

    cmd-1…0 workspaces, cmd-shift-b swaps the bar and the system menu bar.
    Logs: ~/.local/state/vsndbar/   Update: $HERE/install.sh update
EOF
}

# --- commands ------------------------------------------------------------------

do_install() {
  preflight
  ensure_brew
  cat <<EOF

    ${BOLD}vsnd-setup$RESET will:
      • clone vsndrg/aerospace and vsndrg/vsndbar into ~/.config (anything there is backed up)
      • create the "$CERT" code signing certificate (login keychain)
      • install AeroSpace $AEROSPACE_VERSION built with the patches into /Applications
      • build and start VsndBar (~/Applications, a LaunchAgent)
      • set the menu bar to hide automatically
EOF
  [[ $KARABINER == 1 ]] && cat <<EOF
      • install Karabiner-Elements and add F3/F4/F5/F6 to its config
      • move the screenshot shortcuts F3/F4 use, save screenshots to ~/Screenshots
EOF
  echo
  ask "Continue?" || exit 0
  configs
  certificate
  install_aerospace
  install_vsndbar
  setup_menubar
  [[ $KARABINER == 1 ]] && setup_karabiner
  summary
}

do_update() {
  step "vsnd-setup"
  git -C "$HERE" pull -q --ff-only || die "couldn't update $HERE (local changes?)"
  say "$HERE: $(git -C "$HERE" log -1 --format='%h %s')"
  exec /bin/bash "$HERE/install.sh" install "$@"
}

do_uninstall() {
  cat <<EOF

    ${BOLD}vsnd-setup uninstall$RESET will:
      • stop and remove VsndBar
      • put back stock AeroSpace $AEROSPACE_VERSION (unpatched)
      • remove its keys from Karabiner's config
      • put back the menu bar and screenshot settings it changed
    Your configs in ~/.config stay.

EOF
  ask "Continue?" || exit 0

  step "VsndBar"
  if [[ -f "$HOME/.config/vsndbar/Makefile" ]]; then
    make -s -C "$HOME/.config/vsndbar" uninstall
  else
    launchctl bootout "gui/$(id -u)/com.vsndrg.vsndbar" 2>/dev/null || true
    pkill -x VsndBar || true
    rm -rf "$HOME/Library/LaunchAgents/com.vsndrg.vsndbar.plist" "$HOME/.local/bin/vsndbar" "$HOME/Applications/VsndBar.app"
  fi
  say "removed"

  step "AeroSpace"
  if [[ -d "$PRISTINE" ]]; then
    osascript -e 'quit app "AeroSpace"' 2>/dev/null || true
    for _ in {1..50}; do pgrep -xq AeroSpace || break; sleep 0.1; done
    pkill -x AeroSpace 2>/dev/null || true
    rm -rf /Applications/AeroSpace.app
    ditto "$PRISTINE" /Applications/AeroSpace.app
    tccutil reset Accessibility bobko.aerospace >/dev/null 2>&1 || true
    open /Applications/AeroSpace.app
    rm -f "$STATE/aerospace.stamp"
    say "stock AeroSpace $AEROSPACE_VERSION is back (grant Accessibility again when asked)"
  else
    say "no stock copy at $PRISTINE: left as is"
  fi

  step "Karabiner"
  "$PYTHON" "$HERE/lib/karabiner.py" remove "$HERE/karabiner/vsnd-setup.json" "$HOME/.config/karabiner" | sed 's/^/    /'

  step "macOS settings"
  "$PYTHON" "$HERE/lib/settings.py" restore "$STATE/settings.json" | sed 's/^/    /'

  printf '\n%s==> Done%s\n' "$GREEN$BOLD" "$RESET"
  cat <<EOF
    Left in place (remove by hand if you want):
      configs        ~/.config/aerospace ~/.config/vsndbar $HERE
      certificate    security delete-identity -c $CERT
      AeroSpace      rm -rf /Applications/AeroSpace.app $BREW_PREFIX_HINT/bin/aerospace $SHARE
      Karabiner      brew uninstall --cask karabiner-elements
EOF
}

main() {
  bootstrap "$@"
  local command=install
  KARABINER=1 FORCE=0
  local args=("$@")
  while (( $# )); do
    case "$1" in
      install|update|uninstall) command="$1" ;;
      -y|--yes) YES=1 ;;
      --no-karabiner) KARABINER=0 ;;
      --force) FORCE=1 ;;
      -h|--help|help) usage; exit 0 ;;
      *) usage >&2; die "unknown argument: $1" ;;
    esac
    shift
  done
  case "$command" in
    install) do_install ;;
    update)
      local rest=() a
      for a in "${args[@]}"; do [[ "$a" == update ]] || rest+=("$a"); done
      do_update ${rest[@]+"${rest[@]}"} ;;
    uninstall)
      BREW_PREFIX_HINT="$(brew --prefix 2>/dev/null || echo /opt/homebrew)"
      do_uninstall ;;
  esac
}

main "$@"
