#!/data/data/com.termux/files/usr/bin/bash
#
# fix-termux-ubuntu.sh
#
# Run this inside Termux (NOT inside proot-distro). It is idempotent:
# safe to re-run any number of times.
#
#   1. Writes a working /etc/resolv.conf inside the proot container (fixes
#      "Could not resolve" / no-internet inside the desktop).
#   2. Installs the official Mozilla Firefox arm64 (or x86_64) tarball into
#      /<home>/firefox, because Ubuntu's snap-based firefox cannot work in proot.
#   3. Regenerates the XFCE launcher (desktop icon + applications menu entry)
#      pointing at that binary with the sandbox-disabled environment.
#   4. Writes user.js sandbox prefs into every Firefox profile, so tabs stop
#      dying with "Gah. Your tab just crashed." (proot cannot run seccomp).
#
# It works whether or not the rootfs can be found on the host: everything can
# be done through `proot-distro login`, so proot-distro layout changes
# (v4 vs v5, containers/ vs installed-rootfs/) do not matter.
#
# It also works when run *inside* the container (e.g. from the XFCE terminal),
# where proot-distro is not usable: it then edits the container directly.
#
# Usage:
#   bash fix-termux-ubuntu.sh
#   DISTRO=ubuntu bash fix-termux-ubuntu.sh
#   DNS1=9.9.9.9 DNS2=149.112.112.112 bash fix-termux-ubuntu.sh
#   bash fix-termux-ubuntu.sh --skip-dns --skip-firefox   # prefs + launcher only
#   bash fix-termux-ubuntu.sh --skip-prefs                # keep the existing prefs
#
set -uo pipefail

DISTRO="${DISTRO:-ubuntu}"
DNS1="${DNS1:-1.1.1.1}"
DNS2="${DNS2:-8.8.8.8}"
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
FF_HOME_DIR="firefox"          # final path is <home-inside-proot>/firefox

DO_DNS=1
DO_FIREFOX=1
DO_PREFS=1
DO_LAUNCHER=1

# Kept inline (not `sed` over $0) so --help works when the script is piped,
# e.g. curl -fsSL <url> | bash -s -- --help
usage() {
  cat <<'USAGE'
fix-termux-ubuntu.sh -- fix DNS and Firefox inside the 'ubuntu' proot container

Usage:
  bash fix-termux-ubuntu.sh
  bash fix-termux-ubuntu.sh --skip-dns --skip-firefox   # prefs + launcher only
  DISTRO=ubuntu bash fix-termux-ubuntu.sh
  DNS1=9.9.9.9 DNS2=149.112.112.112 bash fix-termux-ubuntu.sh

Options:
  --skip-dns        do not touch /etc/resolv.conf
  --skip-firefox    do not download/reinstall Firefox (~90 MB)
  --skip-prefs      do not write user.js into the Firefox profile(s)
  --skip-launcher   do not rewrite the desktop/menu entries
  -h, --help        show this help

Env: DISTRO (default ubuntu), DNS1 (1.1.1.1), DNS2 (8.8.8.8),
     LOCAL_MODE (1 = inside the container, 0 = in Termux; auto-detected)
USAGE
}

for arg in "$@"; do
  case "$arg" in
    --skip-dns)      DO_DNS=0 ;;
    --skip-firefox)  DO_FIREFOX=0 ;;
    --skip-prefs)    DO_PREFS=0 ;;
    --skip-launcher) DO_LAUNCHER=0 ;;
    -h|--help)       usage; exit 0 ;;
    *) printf 'Unknown option: %s (try --help)\n' "$arg" >&2; exit 2 ;;
  esac
done

log()  { printf '\033[1;34m[*]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- preflight --
# Termux has no /etc/os-release (Android keeps its own under /system/etc), the
# proot container does. Running this from the desktop terminal must work too:
# it is the very place where "my tab crashed" shows up.
inside_container() {
  if [ -f /etc/os-release ] \
     && grep -qiE '^(ID|ID_LIKE)=.*(ubuntu|debian|kali|linuxmint|fedora|arch|alpine)' /etc/os-release 2>/dev/null; then
    return 0
  fi
  [ -d /etc/apt ] && command -v dpkg >/dev/null 2>&1 && return 0
  return 1
}

if [ -z "${LOCAL_MODE:-}" ]; then
  # LOCAL_MODE=1/0 forces the mode; the default is the detection above.
  if inside_container; then LOCAL_MODE=1; else LOCAL_MODE=0; fi
fi

if [ "$LOCAL_MODE" = 1 ]; then
  ok "Running inside the container: no proot-distro needed, changing things directly."
else
  [ -d "$PREFIX" ] || die "This must run inside Termux, not inside proot-distro."
  command -v proot-distro >/dev/null 2>&1 || die "proot-distro missing: pkg install proot-distro"
fi

# proot-distro prints a login banner on stdout; keep only the last real line.
if [ "$LOCAL_MODE" = 1 ]; then
  in_distro()      { bash -c "$1" 2>&1; }
  in_distro_q()    { bash -c "$1" >/dev/null 2>&1; }
else
  in_distro() {
    proot-distro login "$DISTRO" -- /bin/bash -lc "$1" 2>&1
  }
  in_distro_q() {
    proot-distro login "$DISTRO" -- /bin/bash -lc "$1" >/dev/null 2>&1
  }
fi
in_distro_last() {
  in_distro "$1" | tr -d '\r' | awk 'NF { last = $0 } END { if (last != "") print last }'
}

# The home directory *inside* the container (/root usually). Cached so the
# summary does not need an extra login round trip.
container_home() {
  if [ -z "$CONTAINER_HOME" ]; then
    CONTAINER_HOME="$(in_distro_last 'printf %s "$HOME"')"
    [ -n "$CONTAINER_HOME" ] || CONTAINER_HOME="$HOME"
  fi
  printf '%s' "$CONTAINER_HOME"
}
CONTAINER_HOME=""

# Push a file into the container over stdin-friendly base64, so no host-side
# rootfs path is needed and no nested quoting can break.
push_into_distro() {
  local dest="$1" src="$2" b64
  b64="$(base64 < "$src" | tr -d '\n')"
  [ -n "$b64" ] || return 1
  in_distro_q "mkdir -p \"\$(dirname '$dest')\" && printf '%s' '$b64' | base64 -d > '$dest' && chmod 755 '$dest'"
}

# Everything Firefox needs under proot: no seccomp sandbox anywhere.
SANDBOX_ENV="MOZ_DISABLE_CONTENT_SANDBOX=1 MOZ_DISABLE_GMP_SANDBOX=1 \
MOZ_DISABLE_SOCKET_PROCESS_SANDBOX=1 MOZ_DISABLE_RDD_SANDBOX=1 \
MOZ_DISABLE_GPU_SANDBOX=1 MOZ_CRASHREPORTER_DISABLE=1 LIBGL_ALWAYS_SOFTWARE=1"
SANDBOX_ENV="$(printf '%s' "$SANDBOX_ENV" | tr -d '\n')"

# Host-side rootfs discovery. Optional: everything works without it, this just
# avoids one extra `proot-distro login` round trip per operation.
find_rootfs() {
  local c g
  for c in \
    "$PREFIX/var/lib/proot-distro/installed-rootfs/$DISTRO" \
    "$PREFIX/var/lib/proot-distro/rootfs/$DISTRO" \
    "$PREFIX/var/lib/proot-distro/containers/$DISTRO/rootfs" \
    "$PREFIX/var/lib/proot-distro/containers/$DISTRO" \
    "$HOME/$DISTRO-fs" \
    "$HOME/${DISTRO}fs" \
    "$HOME/$DISTRO"; do
    [ -d "$c/etc" ] && { printf '%s' "$c"; return 0; }
  done

  # Unknown layout: glob one level deep instead of relying on `find`,
  # which is not part of base Termux.
  for g in "$PREFIX"/var/lib/proot-distro/*/"$DISTRO" \
           "$PREFIX"/var/lib/proot-distro/*/"$DISTRO"/rootfs; do
    [ -d "$g/etc" ] && { printf '%s' "$g"; return 0; }
  done

  if command -v find >/dev/null 2>&1; then
    c="$(find "$PREFIX/var/lib/proot-distro" "$HOME" -maxdepth 5 -type d -name "$DISTRO" 2>/dev/null \
         | while read -r g; do
             [ -d "$g/etc" ] && { printf '%s\n' "$g"; break; }
           done)"
    [ -n "$c" ] && { printf '%s' "$c"; return 0; }
  fi
  return 1
}

if [ "$LOCAL_MODE" = 1 ]; then
  # Already inside: host-side writes are unnecessary (and would be wrong).
  ROOTFS=""
else
  log "Looking for the '$DISTRO' proot rootfs on the host..."
  if ROOTFS="$(find_rootfs)"; then
    ok "Rootfs: $ROOTFS"
  else
    ROOTFS=""
    warn "Rootfs path not found on the host (new proot-distro layout?)."
    warn "That is fine: DNS and the launcher will be written from inside the container."
  fi

  # `/proc/sys/kernel/random/*` errors above come from proot itself and are
  # harmless; what matters is whether the login actually works.
  proot-distro login "$DISTRO" -- true >/dev/null 2>&1 || die \
    "'proot-distro login $DISTRO' fails. If you are already *inside* the container, run this script there instead (it edits the container directly). Otherwise: proot-distro install $DISTRO."
fi

# --------------------------------------------------------------------- DNS ---
fix_dns() {
  local wrote=0 f

  if [ -n "$ROOTFS" ]; then
    f="$ROOTFS/etc/resolv.conf"
    log "Writing DNS ($DNS1, $DNS2) to $f"
    # A symlink to /run/systemd/resolve/stub-resolv.conf (127.0.0.53) never
    # works under proot: systemd-resolved is not running there.
    [ -L "$f" ] && warn "resolv.conf was a symlink -> $(readlink "$f" 2>/dev/null); replacing it."
    rm -f "$f" 2>/dev/null
    if printf 'nameserver %s\nnameserver %s\n' "$DNS1" "$DNS2" > "$f" 2>/dev/null; then
      wrote=1
      ok "resolv.conf written (host side)"
    else
      warn "Could not write $f from the host; falling back to the inside path."
    fi
  fi

  if [ "$wrote" = 0 ]; then
    log "Writing DNS ($DNS1, $DNS2) from inside $DISTRO"
    if in_distro_q "rm -f /etc/resolv.conf && printf 'nameserver $DNS1\nnameserver $DNS2\n' > /etc/resolv.conf"; then
      wrote=1
      ok "resolv.conf written (inside container)"
    else
      warn "/etc/resolv.conf is not writable inside $DISTRO (bind-mounted read-only?)."
      warn "The desktop will keep using whatever DNS the host provides."
    fi
  fi

  echo "--- /etc/resolv.conf inside $DISTRO ---"
  # Drop proot-distro's login banner so only the real file is shown.
  in_distro 'cat /etc/resolv.conf 2>/dev/null || echo "<missing>"' \
    | tr -d '\r' | grep -v -e '^Welcome to ' -e '^$' || true

  log "Testing DNS inside $DISTRO..."
  local hosts
  hosts="$(in_distro_last 'getent hosts google.com || true')"
  if [ -n "$hosts" ]; then
    ok "DNS works inside $DISTRO: $hosts"
  else
    warn "Still no DNS resolution inside $DISTRO."
    warn "If Termux itself cannot resolve either, check Android Private DNS / VPN."
  fi

  # DNS can work while actual traffic does not (broken IPv6 route), which looks
  # like "no internet" in the desktop.
  log "Testing HTTPS egress inside $DISTRO..."
  if in_distro_q 'command -v wget >/dev/null 2>&1 || command -v curl >/dev/null 2>&1'; then
    if in_distro_q 'if command -v wget >/dev/null 2>&1; then wget -q -O /dev/null -T 15 https://example.com; else curl -fsS -m 15 -o /dev/null https://example.com; fi'; then
      ok "HTTPS egress works inside $DISTRO"
    else
      warn "DNS resolves but HTTPS failed inside $DISTRO (IPv6-only route?)."
      warn "Compare: proot-distro login $DISTRO -- curl -4 -I https://example.com"
    fi
  else
    log "wget/curl not installed yet; skipping the egress check."
  fi
}

if [ "$DO_DNS" = 1 ]; then
  fix_dns
fi

# ----------------------------------------------------------------- Firefox ---
install_firefox() {
  local home arch url pkg missing=()
  local ffbin

  home="$(container_home)"
  [ -n "$home" ] || home="/root"
  arch="$(in_distro_last 'uname -m')"

  case "$arch" in
    aarch64|arm64) url="https://download.mozilla.org/?product=firefox-latest-ssl&os=linux64-aarch64&lang=en-US" ;;
    x86_64|amd64)  url="https://download.mozilla.org/?product=firefox-latest-ssl&os=linux64&lang=en-US" ;;
    *) die "Unsupported architecture inside proot: '$arch'" ;;
  esac

  log "Installing Firefox for $arch into $home/$FF_HOME_DIR"
  [ "$LOCAL_MODE" = 1 ] && log "(inside the container: no proot-distro round trips)"
  in_distro_q 'apt-get update -qq' || warn "apt-get update failed (DNS not fixed yet? continuing anyway)"

  # Package names differ between Ubuntu releases (libasound2 vs libasound2t64),
  # so try each and only report what is truly unavailable.
  for pkg in ca-certificates wget xz-utils \
             libgtk-3-0t64 libgtk-3-0 libdbus-glib-1-2 \
             libasound2t64 libasound2 libxt6 libx11-xcb1 libxcomposite1 \
             libxdamage1 libxrandr2 libgbm1 libpango-1.0-0 libcairo2 \
             fonts-liberation; do
    in_distro_q "DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $pkg" \
      || missing+=("$pkg")
  done
  [ ${#missing[@]} -eq 0 ] || log "Not available on this release (fine): ${missing[*]}"

  log "Downloading Firefox (~90 MB, this can take a few minutes)..."
  if ! in_distro_q "wget -q -O /tmp/firefox.tar.xz '$url' || curl -fsSL -o /tmp/firefox.tar.xz '$url'"; then
    die "Firefox download failed. Check connectivity, then re-run."
  fi
  ok "Download complete"

  log "Extracting to $home/$FF_HOME_DIR (replacing any previous copy)..."
  if ! in_distro_q "rm -rf '$home/$FF_HOME_DIR' && tar -xf /tmp/firefox.tar.xz -C '$home' && rm -f /tmp/firefox.tar.xz"; then
    die "Extracting the Firefox tarball failed (out of space? need ~400 MB free)."
  fi
  ok "Extracted"

  log "Checking the binary runs..."
  ffbin="$(in_distro_last "'$home/$FF_HOME_DIR/firefox' --version 2>&1")"
  case "$ffbin" in
    Mozilla*) ok "$ffbin" ;;
    *) warn "Firefox did not report a version: ${ffbin:-<no output>}"
       warn "Usually a missing library. Run: ldd $home/$FF_HOME_DIR/firefox | grep 'not found'" ;;
  esac
}

if [ "$DO_FIREFOX" = 1 ]; then
  install_firefox
fi

# ------------------------------------------------------------------- prefs ---
# proot cannot start a seccomp sandbox, so the content process dies the moment a
# tab loads ("Gah. Your tab just crashed."). Level 0 plus in-process tabs keep
# everything in the single process that proot can actually run.
write_prefs() {
  local src n
  src="$(mktemp)" || die "mktemp failed"
  cat > "$src" <<'EOF'
// Installed by fix-termux-ubuntu.sh -- proot-distro cannot start the seccomp
// sandbox, which makes every tab crash. Do not edit; re-run the script instead.
user_pref("security.sandbox.content.level", 0);
user_pref("security.sandbox.gpu.level", 0);
user_pref("security.sandbox.rdd.level", 0);
user_pref("security.sandbox.socket.process.level", 0);
user_pref("browser.tabs.remote.autostart", false);
user_pref("browser.tabs.remote.autostart.2", false);
user_pref("browser.tabs.remote.separatePrivilegedContentProcess", false);
user_pref("fission.autostart", false);
user_pref("layers.acceleration.disabled", true);
user_pref("gfx.webrender.all", false);
user_pref("media.hardware-video-decoding.enabled", false);
EOF

  log "Writing sandbox prefs into every Firefox profile"
  if ! push_into_distro /tmp/ff-user.js "$src"; then
    warn "Could not push user.js into $DISTRO."
    rm -f "$src"
    return
  fi
  in_distro_q 'for p in "$HOME"/.mozilla/firefox/*/; do [ -d "$p" ] && cp -f /tmp/ff-user.js "$p/user.js" && chmod 644 "$p/user.js"; done; rm -f /tmp/ff-user.js'

  n="$(in_distro_last 'ls -d "$HOME"/.mozilla/firefox/*/ 2>/dev/null | wc -l')"
  n="${n//[^0-9]/}"
  if [ -z "$n" ] || [ "$n" = 0 ]; then
    warn "No Firefox profile yet: launch Firefox once, then re-run:"
    warn "    bash fix-termux-ubuntu.sh --skip-dns --skip-firefox"
  else
    ok "user.js written to $n profile(s)"
    warn "Quit Firefox completely before starting it again (new prefs load on start)."
  fi
  rm -f "$src"
}

# ---------------------------------------------------------------- launcher ---
write_launcher() {
  local home desk icon src

  home="$(container_home)"
  desk="$(in_distro_last 'command -v xdg-user-dir >/dev/null 2>&1 && xdg-user-dir DESKTOP || printf %s "$HOME/Desktop"')"
  [ -n "$desk" ] || desk="$home/Desktop"

  log "Writing XFCE launchers (desktop: $desk)"

  # Decide the icon before writing the file; older builds may lack it.
  icon="$home/$FF_HOME_DIR/browser/chrome/icons/default/default128.png"
  if [ -n "$ROOTFS" ]; then
    [ -f "$ROOTFS$icon" ] || { warn "Icon file missing; using the theme's generic icon."; icon="firefox"; }
  elif [ "$LOCAL_MODE" = 1 ]; then
    [ -f "$icon" ] || { warn "Icon file missing; using the theme's generic icon."; icon="firefox"; }
  fi

  src="$(mktemp)" || die "mktemp failed"
  cat > "$src" <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=Firefox
GenericName=Web Browser
Comment=Browse the Web
Exec=env $SANDBOX_ENV $home/$FF_HOME_DIR/firefox %u
TryExec=$home/$FF_HOME_DIR/firefox
Icon=$icon
Terminal=false
Categories=Network;WebBrowser;
MimeType=text/html;x-scheme-handler/http;x-scheme-handler/https;application/xhtml+xml;
StartupNotify=true
StartupWMClass=firefox
EOF

  if [ -n "$ROOTFS" ]; then
    mkdir -p "$ROOTFS$desk" "$ROOTFS$home/.local/share/applications" 2>/dev/null
    if install -m 755 "$src" "$ROOTFS$desk/firefox.desktop" 2>/dev/null; then
      ok "Wrote $desk/firefox.desktop"
      install -m 755 "$src" "$ROOTFS$home/.local/share/applications/firefox.desktop" 2>/dev/null \
        && ok "Wrote $home/.local/share/applications/firefox.desktop"
      rm -f "$src"
      return 0
    fi
    warn "Host-side write failed; pushing the launcher from inside instead."
  fi

  if push_into_distro "$desk/firefox.desktop" "$src"; then
    ok "Wrote $desk/firefox.desktop"
    push_into_distro "$home/.local/share/applications/firefox.desktop" "$src" \
      && ok "Wrote $home/.local/share/applications/firefox.desktop"
  else
    warn "Could not write the launcher into $DISTRO."
  fi
  rm -f "$src"

  # Same environment as the launcher, for people who start Firefox from a
  # terminal (`~/firefox/firefox` on its own crashes the first tab).
  src="$(mktemp)" || die "mktemp failed"
  cat > "$src" <<EOF
#!/bin/sh
# Written by fix-termux-ubuntu.sh -- run THIS instead of ~/firefox/firefox.
export $SANDBOX_ENV
exec $home/$FF_HOME_DIR/firefox "\$@"
EOF
  if push_into_distro "$home/start-firefox.sh" "$src"; then
    ok "Wrote $home/start-firefox.sh (terminal-friendly starter)"
  else
    warn "Could not write $home/start-firefox.sh."
  fi
  rm -f "$src"
}

if [ "$DO_PREFS" = 1 ]; then
  write_prefs
fi

if [ "$DO_LAUNCHER" = 1 ]; then
  write_launcher
fi

# ------------------------------------------------------------------ summary --
echo
ok "Done. Next steps:"
printf '  - If the desktop is open, right-click the new Firefox icon -> "Allow launching" (XFCE asks once).\n'
FINAL_HOME="$(container_home)"
printf '  - Start Firefox from the icon, or from a terminal with  %s/start-firefox.sh\n' "$FINAL_HOME"
printf '    (a bare %s/%s/firefox call has no sandbox-off env and crashes the first tab).\n' "$FINAL_HOME" "$FF_HOME_DIR"
printf '  - Restart the VNC session so menu/icon caches are rebuilt, e.g.:\n'
printf '        vncserver -kill :1 && vncserver :1 -geometry 1280x720 -depth 24\n'
if [ "$LOCAL_MODE" = 1 ]; then
  printf '  - Sanity check:  ping -c2 google.com\n'
  printf '  - This run happened inside the container, so DNS/Firefox were left alone only if you passed --skip-*.\n'
else
  printf '  - Sanity check inside the container:  proot-distro login %s -- ping -c2 google.com\n' "$DISTRO"
fi
