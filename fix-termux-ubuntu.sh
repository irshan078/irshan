#!/data/data/com.termux/files/usr/bin/bash
#
# fix-termux-ubuntu.sh
#
# Run this inside Termux (NOT inside proot-distro). It is idempotent:
# safe to re-run any number of times.
#
#   1. Writes a working /etc/resolv.conf into the proot rootfs (fixes
#      "Could not resolve" / no-internet inside the desktop).
#   2. Installs the official Mozilla Firefox arm64 (or x86_64) tarball into
#      /<home>/firefox, because Ubuntu's snap-based firefox cannot work in proot.
#   3. Regenerates the XFCE launcher (desktop icon + applications menu entry)
#      pointing at that binary with the sandbox-disabled environment.
#
# Usage:
#   bash fix-termux-ubuntu.sh            # do everything
#   DISTRO=ubuntu bash fix-termux-ubuntu.sh
#   DNS1=9.9.9.9 DNS2=149.112.112.112 bash fix-termux-ubuntu.sh
#   bash fix-termux-ubuntu.sh --skip-dns --skip-firefox   # only launcher, etc.
#
set -uo pipefail

DISTRO="${DISTRO:-ubuntu}"
DNS1="${DNS1:-1.1.1.1}"
DNS2="${DNS2:-8.8.8.8}"
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
FF_HOME_DIR="firefox"          # final path is <home-inside-proot>/firefox

DO_DNS=1
DO_FIREFOX=1
DO_LAUNCHER=1

for arg in "$@"; do
  case "$arg" in
    --skip-dns)      DO_DNS=0 ;;
    --skip-firefox)  DO_FIREFOX=0 ;;
    --skip-launcher) DO_LAUNCHER=0 ;;
    -h|--help)       sed -n '2,19p' "$0"; exit 0 ;;
    *) printf 'Unknown option: %s (try --help)\n' "$arg" >&2; exit 2 ;;
  esac
done

log()  { printf '\033[1;34m[*]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- preflight --
[ -d "$PREFIX" ] || die "This must run inside Termux, not inside proot-distro."
command -v proot-distro >/dev/null 2>&1 || die "proot-distro missing: pkg install proot-distro"

# proot-distro logs in and prints a banner; keep only the last line of output.
in_distro() {
  proot-distro login "$DISTRO" -- bash -lc "$1" 2>&1
}
in_distro_last() {
  # proot-distro's login banner sits on stdout, so keep the last non-empty line.
  in_distro "$1" | tr -d '\r' | awk 'NF { last = $0 } END { if (last != "") print last }'
}

find_rootfs() {
  local c
  for c in \
    "$PREFIX/var/lib/proot-distro/installed-rootfs/$DISTRO" \
    "$PREFIX/var/lib/proot-distro/rootfs/$DISTRO" \
    "$HOME/$DISTRO-fs" \
    "$HOME/${DISTRO}fs" \
    "$HOME/$DISTRO"; do
    if [ -d "$c/etc" ] || [ -f "$c/etc/os-release" ]; then
      printf '%s' "$c"
      return 0
    fi
  done

  # Layout changed between proot-distro releases (and some guides use
  # ~/ubuntu-fs), so fall back to a bounded search for a directory that
  # actually looks like a rootfs.
  local hit
  hit="$(find "$PREFIX/var/lib/proot-distro" "$HOME" -maxdepth 4 -type d -name "$DISTRO" 2>/dev/null \
         | while read -r c; do
             [ -d "$c/etc" ] && { printf '%s\n' "$c"; break; }
           done)"
  if [ -n "$hit" ]; then
    printf '%s' "$hit"
    return 0
  fi
  return 1
}

log "Looking for the '$DISTRO' proot rootfs..."
if ! ROOTFS="$(find_rootfs)"; then
  warn "Could not find the rootfs on disk; I will rely on 'proot-distro login' instead."
  ROOTFS=""
else
  ok "Rootfs: $ROOTFS"
fi

proot-distro login "$DISTRO" -- true >/dev/null 2>&1 \
  || die "'proot-distro login $DISTRO' fails. Fix that first (proot-distro install $DISTRO)."

# --------------------------------------------------------------------- DNS ---
fix_dns() {
  local f="$ROOTFS/etc/resolv.conf"
  log "Writing DNS ($DNS1, $DNS2) to $f"

  if [ ! -d "$ROOTFS/etc" ]; then
    warn "No $ROOTFS/etc — skipping direct write; fixing from inside instead."
    in_distro "printf 'nameserver $DNS1\nnameserver $DNS2\n' > /etc/resolv.conf && cat /etc/resolv.conf"
    return $?
  fi

  # A symlink to /run/systemd/resolve/stub-resolv.conf (127.0.0.53) never works
  # under proot because systemd-resolved is not running there.
  if [ -L "$f" ]; then
    warn "resolv.conf was a symlink -> $(readlink "$f" 2>/dev/null); replacing it with a real file."
  fi
  rm -f "$f" 2>/dev/null

  if printf 'nameserver %s\nnameserver %s\n' "$DNS1" "$DNS2" > "$f" 2>/dev/null; then
    ok "resolv.conf written"
  else
    warn "Cannot write $f; fixing from inside the container instead."
    in_distro "rm -f /etc/resolv.conf && printf 'nameserver $DNS1\nnameserver $DNS2\n' > /etc/resolv.conf"
  fi

  log "Testing DNS inside $DISTRO..."
  local hosts
  hosts="$(in_distro_last 'getent hosts google.com || true')"
  if [ -n "$hosts" ]; then
    ok "DNS works inside $DISTRO: $hosts"
  else
    warn "Still no DNS resolution inside $DISTRO."
    warn "If Termux itself cannot resolve either, check Android Private DNS / VPN, then re-run."
  fi
}

if [ "$DO_DNS" = 1 ]; then
  [ -n "$ROOTFS" ] || die "DNS fix needs the rootfs path, which was not found. Run: proot-distro list"
  fix_dns
fi

# ----------------------------------------------------------------- Firefox ---
install_firefox() {
  local home arch url pkg missing=()

  home="$(in_distro_last 'printf %s "$HOME"')"
  [ -n "$home" ] || home="/root"
  arch="$(in_distro_last 'uname -m')"

  case "$arch" in
    aarch64|arm64) url="https://download.mozilla.org/?product=firefox-latest-ssl&os=linux64-aarch64&lang=en-US" ;;
    x86_64|amd64)  url="https://download.mozilla.org/?product=firefox-latest-ssl&os=linux64&lang=en-US" ;;
    *) die "Unsupported architecture inside proot: '$arch'" ;;
  esac

  log "Installing Firefox for $arch into $home/$FF_HOME_DIR"
  in_distro 'apt-get update -qq' >/dev/null 2>&1 || warn "apt-get update failed (DNS not fixed? continuing anyway)"

  # Package names differ between Ubuntu releases (libasound2 vs libasound2t64),
  # so try each one and only report the ones that are truly unavailable.
  for pkg in ca-certificates wget xz-utils \
             libgtk-3-0t64 libgtk-3-0 libdbus-glib-1-2 \
             libasound2t64 libasound2 libxt6 libx11-xcb1 libxcomposite1 \
             libxdamage1 libxrandr2 libgbm1 libpango-1.0-0 libcairo2 \
             fonts-liberation; do
    in_distro "DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $pkg" \
      >/dev/null 2>&1 || missing+=("$pkg")
  done
  [ ${#missing[@]} -eq 0 ] || log "Not available on this Ubuntu release (fine): ${missing[*]}"

  log "Downloading Firefox (~90 MB, this can take a few minutes)..."
  if ! in_distro "wget -q -O /tmp/firefox.tar.xz '$url' || curl -fsSL -o /tmp/firefox.tar.xz '$url'" >/dev/null 2>&1; then
    die "Firefox download failed. Check Termux connectivity, then re-run."
  fi
  ok "Download complete"

  log "Extracting to $home/$FF_HOME_DIR (replacing any previous copy)..."
  if ! in_distro "rm -rf '$home/$FF_HOME_DIR' && tar -xf /tmp/firefox.tar.xz -C '$home' && rm -f /tmp/firefox.tar.xz" >/dev/null 2>&1; then
    die "Extracting the Firefox tarball failed (out of space? need ~400 MB free)."
  fi
  ok "Extracted"

  log "Checking the binary runs..."
  local ver
  ver="$(in_distro_last "'$home/$FF_HOME_DIR/firefox' --version 2>&1")"
  case "$ver" in
    Mozilla*) ok "$ver" ;;
    *) warn "Firefox did not report a version: ${ver:-<no output>}"
       warn "Usually a missing shared library. Run: ldd $home/$FF_HOME_DIR/firefox | grep 'not found'" ;;
  esac
}

if [ "$DO_FIREFOX" = 1 ]; then
  install_firefox
fi

# ---------------------------------------------------------------- launcher ---
write_launcher() {
  local home desk src
  home="$(in_distro_last 'printf %s "$HOME"')"
  [ -n "$home" ] || home="/root"
  desk="$(in_distro_last 'command -v xdg-user-dir >/dev/null 2>&1 && xdg-user-dir DESKTOP || printf %s "$HOME/Desktop"')"
  [ -n "$desk" ] || desk="$home/Desktop"

  log "Writing XFCE launchers (desktop: $desk)"

  # Decide the icon before writing the file: the tarball ships it inside
  # browser/chrome/icons/default/, but older builds may not.
  local icon="$home/$FF_HOME_DIR/browser/chrome/icons/default/default128.png"
  if [ -n "$ROOTFS" ] && [ ! -f "$ROOTFS$icon" ]; then
    warn "Icon file missing; the launcher will use the theme's generic icon."
    icon="firefox"
  fi

  src="$(mktemp)" || die "mktemp failed"
  cat > "$src" <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=Firefox
GenericName=Web Browser
Comment=Browse the Web
Exec=env MOZ_DISABLE_CONTENT_SANDBOX=1 MOZ_DISABLE_GMP_SANDBOX=1 LIBGL_ALWAYS_SOFTWARE=1 $home/$FF_HOME_DIR/firefox %u
TryExec=$home/$FF_HOME_DIR/firefox
Icon=$icon
Terminal=false
Categories=Network;WebBrowser;
MimeType=text/html;x-scheme-handler/http;x-scheme-handler/https;application/xhtml+xml;
StartupNotify=true
StartupWMClass=firefox
EOF

  if [ -n "$ROOTFS" ]; then
    # Direct write into the rootfs: no nested-quoting games, works even when
    # the container is not logged in.
    mkdir -p "$ROOTFS$desk" "$ROOTFS$home/.local/share/applications" 2>/dev/null
    install -m 755 "$src" "$ROOTFS$desk/firefox.desktop" 2>/dev/null \
      && ok "Wrote $desk/firefox.desktop"
    install -m 755 "$src" "$ROOTFS$home/.local/share/applications/firefox.desktop" 2>/dev/null \
      && ok "Wrote $home/.local/share/applications/firefox.desktop"
    rm -f "$src"
  else
    warn "Rootfs path unknown; copy the desktop entry in from inside the container."
    cp "$src" "$HOME/firefox.desktop" && ok "Wrote $HOME/firefox.desktop — copy it to $desk inside proot"
    rm -f "$src"
  fi
}

if [ "$DO_LAUNCHER" = 1 ]; then
  write_launcher
fi

# ------------------------------------------------------------------ summary --
echo
ok "Done. Next steps:"
printf '  - If the desktop is already open, right-click the new Firefox icon -> "Allow launching" (XFCE asks once).\n'
printf '  - Restart the VNC session so the menu/icon cache is rebuilt:\n'
printf '        vncserver -kill :1 && vncserver :1 -geometry 1280x720 -depth 24\n'
printf '  - Sanity check inside the container:  proot-distro login %s -- ping -c2 google.com\n' "$DISTRO"
