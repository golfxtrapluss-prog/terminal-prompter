#!/bin/sh
# Terminal Prompter installer (docs/06-bootstrap-og-installasjon.md).
# POSIX sh: runs under dash, BusyBox ash and bash on Debian, Ubuntu,
# Alma/Rocky and Alpine. Usage:
#   curl -fsSL https://<release site>/install.sh | sudo sh -s -- [options]
#
# Options:
#   --mode proxy|standalone   default: proxy (behind Caddy/nginx/Traefik)
#   --domain NAME             public name; sets up Caddy + HTTPS if no web server
#   --email ADDR              contact for Let's Encrypt (Caddy)
#   --password-file FILE      use this password instead of generating one
#   --sudo / --no-sudo        give the "tp" user passwordless sudo (asked otherwise)
#   --version V               install a specific release (default: latest)
#   --base-url URL            release download base (contains SHA256SUMS)
#   --link CODE               connect to the relay (v1.5, not available yet)
#   --yes                     accept defaults, never prompt
#
# Test hooks (not for production): TP_ROOT=<dir> installs under a prefix,
# TP_NO_USER=1 skips creating the system user, TP_NO_SYSTEMD=1 skips
# service management, TP_NO_HEALTH=1 skips the final health check.

set -eu
umask 022

BASE_URL="${TP_BASE_URL:-__TP_RELEASE_URL__}"
ROOT="${TP_ROOT:-}"
MODE=""
DOMAIN=""
EMAIL=""
PASSWORD_FILE=""
SUDO=""
YES=0
LINK=""
VERSION=""
PORT=7681
TMP=""

say() { printf '%s\n' "$*"; }
warn() { printf 'tp-install: %s\n' "$*" >&2; }
die() { warn "$*"; exit 1; }
cleanup() { [ -n "$TMP" ] && rm -rf "$TMP"; return 0; }
trap cleanup EXIT INT TERM

usage() {
  sed -n '2,24p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//' || true
  exit "${1:-0}"
}

# Asks a yes/no question; with --yes or without a terminal the default wins.
ask_yes() { # $1 question, $2 default y|n
  if [ "$YES" -eq 1 ] || ! [ -r /dev/tty ]; then
    [ "$2" = y ]
    return
  fi
  printf '%s [%s] ' "$1" "$( [ "$2" = y ] && echo Y/n || echo y/N )" >/dev/tty
  read -r answer </dev/tty || answer=""
  case "$answer" in
    [Yy]*) return 0 ;;
    [Nn]*) return 1 ;;
    *) [ "$2" = y ] ;;
  esac
}

while [ $# -gt 0 ]; do
  case "$1" in
    --mode) MODE="${2:-}"; shift 2 ;;
    --mode=*) MODE="${1#*=}"; shift ;;
    --domain) DOMAIN="${2:-}"; shift 2 ;;
    --domain=*) DOMAIN="${1#*=}"; shift ;;
    --email) EMAIL="${2:-}"; shift 2 ;;
    --email=*) EMAIL="${1#*=}"; shift ;;
    --password-file) PASSWORD_FILE="${2:-}"; shift 2 ;;
    --password-file=*) PASSWORD_FILE="${1#*=}"; shift ;;
    --version) VERSION="${2:-}"; shift 2 ;;
    --version=*) VERSION="${1#*=}"; shift ;;
    --base-url) BASE_URL="${2:-}"; shift 2 ;;
    --base-url=*) BASE_URL="${1#*=}"; shift ;;
    --link) LINK="${2:-}"; shift 2 ;;
    --link=*) LINK="${1#*=}"; shift ;;
    --sudo) SUDO=yes; shift ;;
    --no-sudo) SUDO=no; shift ;;
    --yes|-y) YES=1; shift ;;
    -h|--help) usage 0 ;;
    *) warn "unknown option: $1"; usage 64 ;;
  esac
done

if [ -n "$LINK" ]; then
  die "relay linking (--link) arrives with v1.5. Use --domain for HTTPS on your own domain for now."
fi
case "$MODE" in
  ""|proxy|standalone) ;;
  *) die "--mode must be proxy or standalone" ;;
esac
case "$BASE_URL" in
  __TP_*__) die "no release URL in this copy of install.sh; pass --base-url" ;;
esac
case "$DOMAIN" in
  "") ;;
  *[!A-Za-z0-9.-]*|.*|*..*) die "invalid domain: $DOMAIN" ;;
esac
if [ -n "$VERSION" ]; then
  BASE_URL="${BASE_URL%/latest/download*}/download/v$VERSION"
fi
BASE_URL="${BASE_URL%/}"

# --- 1. platform ---------------------------------------------------------
if [ -z "$ROOT" ] && [ -z "${TP_NO_USER:-}" ] && [ "$(id -u)" -ne 0 ]; then
  die "run as root, e.g.: curl -fsSL <url>/install.sh | sudo sh"
fi
case "$(uname -m)" in
  x86_64|amd64) ARCH=x64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) die "unsupported CPU: $(uname -m) (supported: x86_64, aarch64)" ;;
esac
ASSET="tp-agent-linux-$ARCH"
if [ -n "${TP_NO_SYSTEMD:-}" ]; then
  INIT=none
elif [ -d /run/systemd/system ]; then
  INIT=systemd
elif command -v rc-service >/dev/null 2>&1; then
  INIT=openrc
else
  INIT=none
fi

if command -v curl >/dev/null 2>&1; then
  fetch() { curl -fsSL --proto '=https,http' --retry 3 -o "$2" "$1"; }
elif command -v wget >/dev/null 2>&1; then
  fetch() { wget -q -O "$2" "$1"; }
else
  die "need curl or wget"
fi
command -v sha256sum >/dev/null 2>&1 || die "need sha256sum (coreutils or BusyBox)"

# --- 2b. prerequisites: glibc and setsid -c (ADR-003) -------------------------
if [ -f /etc/alpine-release ] && [ ! -e /lib/ld-linux-x86-64.so.2 ] && [ ! -e /lib/ld-linux-aarch64.so.1 ]; then
  if [ -z "$ROOT" ]; then
    say "Alpine: installing gcompat (glibc compatibility for the Dart binary)..."
    apk add --no-cache gcompat >/dev/null || die "could not install gcompat"
  fi
fi
if ! (setsid --help 2>&1 || true) | grep -q -- '-c'; then
  if [ -z "$ROOT" ] && command -v apk >/dev/null 2>&1; then
    apk add --no-cache util-linux-misc >/dev/null 2>&1 || apk add --no-cache util-linux >/dev/null || true
  fi
  (setsid --help 2>&1 || true) | grep -q -- '-c' || die "need 'setsid -c' (util-linux, or BusyBox >= 1.30)"
fi

# --- 2. download and verify ------------------------------------------------
TMP="$(mktemp -d)"
say "Downloading $ASSET from $BASE_URL ..."
fetch "$BASE_URL/SHA256SUMS" "$TMP/SHA256SUMS" || die "download failed: $BASE_URL/SHA256SUMS"
fetch "$BASE_URL/$ASSET" "$TMP/$ASSET" || die "download failed: $BASE_URL/$ASSET"
fetch "$BASE_URL/SHA256SUMS.sig" "$TMP/SHA256SUMS.sig" 2>/dev/null || true
LINE="$(grep "  $ASSET\$" "$TMP/SHA256SUMS" || true)"
[ -n "$LINE" ] || die "SHA256SUMS does not list $ASSET"
(cd "$TMP" && printf '%s\n' "$LINE" | sha256sum -c - >/dev/null 2>&1) || die "checksum mismatch for $ASSET; not installing"
chmod 755 "$TMP/$ASSET"
"$TMP/$ASSET" version >/dev/null 2>&1 || die "$ASSET does not run here (missing glibc?)"
say "Checksum OK: $("$TMP/$ASSET" version)"

# --- 3. user and directories -----------------------------------------------
BIN="$ROOT/usr/local/bin/tp-agent"
ETC="$ROOT/etc/tp-agent"
VAR="$ROOT/var/lib/tp-agent"
RUN_USER=tp
if [ -n "${TP_NO_USER:-}" ]; then
  RUN_USER="$(id -un)"
  TP_HOME="${TP_HOME:-$ROOT/home/tp}"
elif id tp >/dev/null 2>&1; then
  TP_HOME="$(getent passwd tp | cut -d: -f6)"
else
  TP_HOME=/home/tp
  if command -v useradd >/dev/null 2>&1; then
    useradd --system --create-home --home-dir "$TP_HOME" --shell /bin/bash tp 2>/dev/null \
      || useradd --system --create-home --home-dir "$TP_HOME" --shell /bin/sh tp
  else
    adduser -S -D -h "$TP_HOME" -s /bin/sh tp
  fi
  say "Created system user tp (home $TP_HOME)."
fi
mkdir -p "$ROOT/usr/local/bin" "$ETC" "$VAR" "$TP_HOME"
cp "$TMP/$ASSET" "$BIN.new" && chmod 755 "$BIN.new" && mv -f "$BIN.new" "$BIN"

# --- 4./5. mode, domain and an existing web server -----------------------------
SERVER=none
if command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' 2>/dev/null | grep -qx coolify-proxy; then
  SERVER=traefik
elif command -v nginx >/dev/null 2>&1; then
  SERVER=nginx
elif command -v caddy >/dev/null 2>&1; then
  SERVER=caddy
fi
[ -n "${TP_FAKE_SERVER:-}" ] && SERVER="$TP_FAKE_SERVER"
[ -n "$MODE" ] || MODE=proxy
LISTEN="127.0.0.1:$PORT"
UPSTREAM="127.0.0.1:$PORT"
if [ "$MODE" = standalone ]; then
  LISTEN="0.0.0.0:443"
elif [ "$SERVER" = traefik ]; then
  # Traefik runs in Docker (Coolify) and reaches the host via the bridge.
  LISTEN="172.17.0.1:$PORT"
  UPSTREAM="host.docker.internal:$PORT"
fi
ORIGIN=""
[ -n "$DOMAIN" ] && ORIGIN="https://$DOMAIN"

if [ -n "$DOMAIN" ] && [ -z "$ROOT" ]; then
  RESOLVED="$(getent hosts "$DOMAIN" | awk '{print $1; exit}')"
  [ -n "$RESOLVED" ] || die "$DOMAIN does not resolve. Create an A/AAAA record pointing to this server first."
  PUBLIC="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
  if [ -n "$PUBLIC" ] && [ "$PUBLIC" != "$RESOLVED" ]; then
    warn "$DOMAIN points to $RESOLVED, but this server's public address looks like $PUBLIC."
    ask_yes "Continue anyway?" n || die "fix the DNS record and run again"
  fi
fi

SNIPPET=""
SNIPPET_DEST=""
case "$SERVER" in
  none)
    if [ -n "$DOMAIN" ] && [ "$MODE" = proxy ]; then
      if [ -z "$ROOT" ]; then
        say "No web server found; installing Caddy for automatic HTTPS..."
        if command -v apt-get >/dev/null 2>&1; then
          DEBIAN_FRONTEND=noninteractive apt-get install -y caddy >/dev/null || die "apt-get install caddy failed"
        elif command -v apk >/dev/null 2>&1; then
          apk add --no-cache caddy >/dev/null || die "apk add caddy failed"
        elif command -v dnf >/dev/null 2>&1; then
          dnf install -y caddy >/dev/null 2>&1 || die "dnf install caddy failed; install Caddy (caddyserver.com) and run again"
        else
          die "install Caddy (caddyserver.com) and run again"
        fi
      fi
      SERVER=caddy
    fi ;;
esac
case "$SERVER" in
  caddy)
    SNIPPET="${DOMAIN:-tp.example.com} {
	reverse_proxy $UPSTREAM
}"
    if [ -n "$EMAIL" ]; then
      SNIPPET="{
	email $EMAIL
}

$SNIPPET"
    fi
    SNIPPET_DEST="$ROOT/etc/caddy/Caddyfile" ;;
  nginx)
    SNIPPET="server {
    listen 443 ssl;
    server_name ${DOMAIN:-tp.example.com};
    # ssl_certificate ... (certbot) ...
    location / {
        proxy_pass http://$UPSTREAM;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \"upgrade\";
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_read_timeout 3600s;
        proxy_buffering off;
    }
}"
    SNIPPET_DEST="$ROOT/etc/nginx/conf.d/tp-agent.conf" ;;
  traefik)
    SNIPPET="http:
  routers:
    tp:
      rule: Host(\`${DOMAIN:-tp.example.com}\`)
      entryPoints: [https]
      service: tp
      tls: { certResolver: letsencrypt }
  services:
    tp:
      loadBalancer:
        servers: [{ url: \"http://$UPSTREAM\" }]"
    SNIPPET_DEST="$ROOT/data/coolify/proxy/dynamic/tp-agent.yaml" ;;
esac

# --- 6. configuration, password, service -----------------------------------------
CONFIG="$ETC/config.toml"
if [ -f "$CONFIG" ]; then
  say "Keeping existing $CONFIG (use 'tp-agent passwd' to change the password)."
  PASSWORD_LINE=""
else
  set -- init --config "$CONFIG" --mode "$MODE" --listen "$LISTEN" --state-dir "$VAR"
  [ -n "$ORIGIN" ] && set -- "$@" --public-origin "$ORIGIN"
  [ -n "$PASSWORD_FILE" ] && set -- "$@" --password-file "$PASSWORD_FILE"
  INIT_OUT="$("$BIN" "$@")" || die "tp-agent init failed"
  PASSWORD_LINE="$(printf '%s\n' "$INIT_OUT" | grep 'Password (shown once' || true)"
fi
if [ -z "${TP_NO_USER:-}" ]; then
  chown -R tp: "$ETC" "$VAR"
fi
chmod 700 "$ETC" "$VAR"

if [ -z "$SUDO" ]; then
  if ask_yes "Give the 'tp' user sudo (needed to administer the server from the browser)?" y; then SUDO=yes; else SUDO=no; fi
fi
if [ "$SUDO" = yes ]; then
  mkdir -p "$ROOT/etc/sudoers.d"
  printf 'tp ALL=(ALL) NOPASSWD: ALL\n' >"$ROOT/etc/sudoers.d/tp-agent.tmp"
  chmod 440 "$ROOT/etc/sudoers.d/tp-agent.tmp"
  if command -v visudo >/dev/null 2>&1 && [ -z "$ROOT" ]; then
    visudo -cf "$ROOT/etc/sudoers.d/tp-agent.tmp" >/dev/null || die "sudoers check failed"
  fi
  mv -f "$ROOT/etc/sudoers.d/tp-agent.tmp" "$ROOT/etc/sudoers.d/tp-agent"
fi

if [ -n "$SNIPPET" ]; then
  say ""
  say "Reverse proxy ($SERVER) configuration for $DOMAIN:"
  say "$SNIPPET" | sed 's/^/    /'
  if [ -f "$SNIPPET_DEST" ] && [ "$SERVER" != traefik ]; then
    say "($SNIPPET_DEST exists; add the block above yourself.)"
  elif ask_yes "Write it to $SNIPPET_DEST?" n; then
    mkdir -p "$(dirname "$SNIPPET_DEST")"
    printf '%s\n' "$SNIPPET" >"$SNIPPET_DEST"
    say "Wrote $SNIPPET_DEST"
    if [ -z "$ROOT" ]; then
      case "$SERVER" in
        caddy) systemctl reload caddy 2>/dev/null || systemctl restart caddy 2>/dev/null || rc-service caddy restart 2>/dev/null || true ;;
        nginx) nginx -t && (systemctl reload nginx 2>/dev/null || rc-service nginx reload 2>/dev/null || true) ;;
      esac
    fi
  fi
fi

CAPS=""
[ "$MODE" = standalone ] && CAPS="AmbientCapabilities=CAP_NET_BIND_SERVICE"
UNIT="$ROOT/etc/systemd/system/tp-agent.service"
mkdir -p "$(dirname "$UNIT")"
cat >"$UNIT" <<UNIT_EOF
[Unit]
Description=Terminal Prompter agent
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/local/bin/tp-agent run --config /etc/tp-agent/config.toml
User=$RUN_USER
WorkingDirectory=$TP_HOME
Restart=always
RestartSec=2
KillMode=control-group
ProtectSystem=full
ReadWritePaths=/var/lib/tp-agent $TP_HOME
$CAPS

[Install]
WantedBy=multi-user.target
UNIT_EOF

case "$INIT" in
  systemd)
    systemctl daemon-reload
    systemctl enable --now tp-agent >/dev/null 2>&1 || die "systemctl enable --now tp-agent failed (see: journalctl -u tp-agent)"
    systemctl restart tp-agent ;;
  openrc)
    cat >"$ROOT/etc/init.d/tp-agent" <<'RC_EOF'
#!/sbin/openrc-run
description="Terminal Prompter agent"
command=/usr/local/bin/tp-agent
command_args="run --config /etc/tp-agent/config.toml"
command_user=tp
command_background=true
pidfile=/run/tp-agent.pid
depend() { need net; }
RC_EOF
    chmod 755 "$ROOT/etc/init.d/tp-agent"
    rc-update add tp-agent default >/dev/null
    rc-service tp-agent restart >/dev/null ;;
  none)
    say "No service manager used; start it with: $BIN run --config $CONFIG" ;;
esac

# --- 7. check and summary ---------------------------------------------------------
if [ "$INIT" != none ] && [ -z "${TP_NO_HEALTH:-}" ]; then
  i=0
  until fetch "http://$(echo "$LISTEN" | sed 's/^0\.0\.0\.0/127.0.0.1/')/healthz" "$TMP/health" 2>/dev/null; do
    i=$((i + 1))
    [ "$i" -ge 15 ] && die "agent did not answer /healthz (see: journalctl -u tp-agent)"
    sleep 1
  done
fi

say ""
say "Terminal Prompter is installed."
if [ -n "$DOMAIN" ]; then
  say "  Open:      https://$DOMAIN/"
else
  say "  Listening: $LISTEN (put a reverse proxy with HTTPS in front, or reach it via an SSH tunnel)"
fi
[ -n "$PASSWORD_LINE" ] && say "  $(printf '%s' "$PASSWORD_LINE" | sed 's/^ *//')"
say "  Next:      log in, then Settings > Security: add a passkey and create backup codes."
say "  Update:    sudo tp-agent selfupdate --restart"
