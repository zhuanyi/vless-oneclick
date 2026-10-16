#!/usr/bin/env bash
# vless-oneclick: set up an Xray VLESS + REALITY server on Debian / Ubuntu.
#
#   sudo ./install.sh               install (or upgrade) and show the share link
#   sudo ./install.sh link          show the share link and QR code again
#   sudo ./install.sh update        update Xray, keep the configuration
#   sudo ./install.sh uninstall     remove Xray, keep the configuration
#   sudo ./install.sh uninstall --purge   also delete the configuration
#
# Environment variables (all optional; without a terminal the defaults are
# used instead of asking):
#   VLESS_PORT      listening port (default 443)
#   VLESS_SNI       website REALITY presents itself as (default
#                   www.microsoft.com)
#   VLESS_HOST      server address put in the share link (default: detected)
#   VLESS_NAME      profile name shown in clients (default: host name)
#   VLESS_BBR=0     don't enable TCP BBR congestion control
#   XRAY_VERSION    Xray release to install, e.g. v26.3.27 (default: latest)
#   XRAY_ZIP        install from this local Xray-linux-*.zip instead of
#                   downloading it
#   VLESS_NONINTERACTIVE=1  never ask, use the values above / defaults

set -euo pipefail

BIN=/usr/local/bin/xray
ASSET_DIR=/usr/local/share/xray
CONF_DIR=/usr/local/etc/xray
CONFIG=$CONF_DIR/config.json
INFO=$CONF_DIR/vless-oneclick.env
UNIT=/etc/systemd/system/xray.service
SERVICE_USER=xray
BBR_CONF=/etc/sysctl.d/90-vless-oneclick-bbr.conf
BBR_MODULE=/etc/modules-load.d/vless-oneclick-bbr.conf
RELEASES=https://github.com/XTLS/Xray-core/releases

DEFAULT_PORT=443
DEFAULT_SNI=www.microsoft.com

say() { printf '%s\n' "$*"; }
step() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

interactive() {
    [ -t 0 ] && [ -z "${VLESS_NONINTERACTIVE:-}" ]
}

# ask "question" default -> answer (the default when not interactive)
ask() {
    local answer
    if interactive; then
        read -r -p "$1 [$2]: " answer || true
    fi
    printf '%s' "${answer:-$2}"
}

confirm() {
    local answer
    interactive || return 0
    read -r -p "$1 [Y/n]: " answer || true
    case "$answer" in [nN]*) return 1 ;; *) return 0 ;; esac
}

need_root() {
    [ "$(id -u)" -eq 0 ] || die "please run as root: sudo $0"
}

base64url() {
    base64 -w0 | tr '+/' '-_' | tr -d '='
}

# --- Xray binary ------------------------------------------------------------

xray_arch() {
    case "$(uname -m)" in
        x86_64 | amd64) echo 64 ;;
        aarch64 | arm64) echo arm64-v8a ;;
        armv7l | armv7*) echo arm32-v7a ;;
        i386 | i686) echo 32 ;;
        riscv64) echo riscv64 ;;
        *) die "unsupported CPU architecture: $(uname -m)" ;;
    esac
}

install_packages() {
    step "installing required packages"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq curl ca-certificates unzip openssl iproute2 >/dev/null
    # optional: QR codes in the terminal
    apt-get install -y -qq qrencode >/dev/null 2>&1 || true
}

install_xray() {
    local tmp zip name url
    tmp=$(mktemp -d)
    # shellcheck disable=SC2064  # expand $tmp now, it is local
    trap "rm -rf -- '$tmp'" EXIT
    name="Xray-linux-$(xray_arch).zip"
    if [ -n "${XRAY_ZIP:-}" ]; then
        step "installing Xray from $XRAY_ZIP"
        zip=$XRAY_ZIP
    else
        if [ -n "${XRAY_VERSION:-}" ]; then
            url="$RELEASES/download/$XRAY_VERSION/$name"
        else
            url="$RELEASES/latest/download/$name"
        fi
        step "downloading $url"
        zip=$tmp/$name
        curl -fsSL --retry 3 -o "$zip" "$url" ||
            die "download failed; you can download $name yourself and run: XRAY_ZIP=/path/to/$name sudo $0"
        curl -fsSL --retry 3 -o "$zip.dgst" "$url.dgst" ||
            die "could not download the checksum file $url.dgst"
        local expected actual
        expected=$(sed -n 's/^SHA2-256= *//p' "$zip.dgst" | tr -d '[:space:]')
        actual=$(sha256sum "$zip" | cut -d' ' -f1)
        if [ -z "$expected" ] || [ "$expected" != "$actual" ]; then
            die "checksum mismatch for $name (expected $expected, got $actual)"
        fi
        say "    checksum OK"
    fi
    mkdir -p "$tmp/x" "$ASSET_DIR"
    unzip -q -o "$zip" -d "$tmp/x"
    [ -f "$tmp/x/xray" ] || die "$zip does not contain xray"
    install -m 755 "$tmp/x/xray" "$BIN.new"
    mv -f "$BIN.new" "$BIN"
    for f in geoip.dat geosite.dat; do
        [ -f "$tmp/x/$f" ] && install -m 644 "$tmp/x/$f" "$ASSET_DIR/$f"
    done
    say "    $("$BIN" version | head -n 1)"
}

# --- configuration ------------------------------------------------------------

load_info() {
    # shellcheck disable=SC1090
    [ -f "$INFO" ] && . "$INFO"
}

detect_host() {
    local ip
    for url in https://api.ipify.org https://ifconfig.me/ip https://icanhazip.com; do
        ip=$(curl -4 -fsS --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]') || true
        case "$ip" in *.*.*.*) printf '%s' "$ip"; return ;; esac
    done
    # the address of the interface used for the default route
    ip=$(ip -4 route get 1.1.1.1 2>/dev/null |
        sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -n 1) || true
    [ -n "$ip" ] || ip=$(hostname -I 2>/dev/null | cut -d' ' -f1)
    printf '%s' "$ip"
}

port_in_use() {
    # look for a TCP socket in LISTEN state (0A) on that port
    local hex f files=()
    hex=$(printf '%04X' "$1")
    for f in /proc/net/tcp /proc/net/tcp6; do
        [ -r "$f" ] && files+=("$f")
    done
    [ ${#files[@]} -gt 0 ] || return 1
    awk -v p="$hex" 'FNR > 1 { split($2, a, ":");
        if (a[length(a)] == p && $4 == "0A") found = 1 }
        END { exit !found }' "${files[@]}"
}

check_sni() {
    # REALITY needs a site that speaks TLS 1.3 (and preferably HTTP/2)
    local out
    out=$(echo | timeout 10 openssl s_client -connect "$1:443" \
        -servername "$1" -verify_hostname "$1" -tls1_3 -alpn h2 \
        2>/dev/null) || true
    if ! printf '%s' "$out" | grep -q '^New, TLSv1.3'; then
        say "    warning: could not reach $1 with TLS 1.3 from this server"
        return 1
    fi
    if ! printf '%s' "$out" | grep -q 'Verify return code: 0 (ok)'; then
        say "    warning: $1 did not show a valid certificate for that name;"
        say "             choose a well-known public website"
        return 1
    fi
    if ! printf '%s' "$out" | grep -q 'ALPN protocol: h2'; then
        say "    note: $1 does not offer HTTP/2; it works, but a site with"
        say "          HTTP/2 blends in better"
    fi
    say "    $1 supports TLS 1.3 and has a valid certificate"
}

new_config() {
    local key
    step "creating a new configuration"
    if interactive; then
        say "Press Enter to accept the suggested value in brackets."
    fi
    while :; do
        PORT=$(ask "Port to listen on" "${VLESS_PORT:-$DEFAULT_PORT}")
        case "$PORT" in
            '' | *[!0-9]*) say "    not a number: $PORT"; continue ;;
        esac
        if [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
            say "    not a valid port: $PORT"; continue
        fi
        if port_in_use "$PORT"; then
            say "    port $PORT is already used by another program"
            interactive && continue
            die "port $PORT is in use; set VLESS_PORT to another port"
        fi
        break
    done
    while :; do
        SNI=$(ask "Website to look like (any large HTTPS site with TLS 1.3)" \
            "${VLESS_SNI:-$DEFAULT_SNI}")
        if check_sni "$SNI" || ! interactive || ! confirm "Pick another site?"
        then
            break
        fi
    done
    HOST=$(ask "Server address for the share link (public IP or domain)" \
        "${VLESS_HOST:-$(detect_host)}")
    [ -n "$HOST" ] || die "no server address; set VLESS_HOST"
    NAME=$(ask "Profile name shown in the apps" "${VLESS_NAME:-$(hostname)}")
    NAME=$(printf '%s' "$NAME" | tr -c 'A-Za-z0-9._-' '-')

    UUID=$(cat /proc/sys/kernel/random/uuid)
    SHORT_ID=$(openssl rand -hex 8)
    key=$(openssl genpkey -algorithm X25519)
    PRIVATE_KEY=$(printf '%s\n' "$key" | openssl pkey -outform DER |
        tail -c 32 | base64url)
    PUBLIC_KEY=$(printf '%s\n' "$key" | openssl pkey -pubout -outform DER |
        tail -c 32 | base64url)
    write_config
}

write_config() {
    mkdir -p "$CONF_DIR"
    umask 077
    cat > "$CONF_DIR/config.new.json" <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "vless-reality",
      "listen": "0.0.0.0",
      "port": $PORT,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$UUID",
            "flow": "xtls-rprx-vision",
            "email": "default"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "target": "$SNI:443",
          "serverNames": ["$SNI"],
          "privateKey": "$PRIVATE_KEY",
          "shortIds": ["$SHORT_ID"]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"],
        "routeOnly": true
      }
    }
  ],
  "outbounds": [
    { "tag": "direct", "protocol": "freedom" },
    { "tag": "block", "protocol": "blackhole" }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "comment": "don't let clients reach this server's own or private networks",
        "type": "field",
        "ip": [
          "0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8",
          "169.254.0.0/16", "172.16.0.0/12", "192.168.0.0/16",
          "::1/128", "fc00::/7", "fe80::/10"
        ],
        "outboundTag": "block"
      }
    ]
  }
}
EOF
    cat > "$INFO.new" <<EOF
# client settings for the share link, written by vless-oneclick
HOST='$HOST'
PORT='$PORT'
UUID='$UUID'
SNI='$SNI'
PUBLIC_KEY='$PUBLIC_KEY'
SHORT_ID='$SHORT_ID'
NAME='$NAME'
EOF
    umask 022
    "$BIN" run -test -config "$CONF_DIR/config.new.json" >/dev/null ||
        die "Xray rejected the generated configuration ($CONF_DIR/config.new.json)"
    mv -f "$CONF_DIR/config.new.json" "$CONFIG"
    mv -f "$INFO.new" "$INFO"
    chown root:"$SERVICE_USER" "$CONFIG"
    chmod 640 "$CONFIG"
    chmod 600 "$INFO"
    say "    saved $CONFIG"
}

share_link() {
    local host=$HOST
    case "$host" in *:*) host="[$host]" ;; esac
    printf 'vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp&headerType=none#%s' \
        "$UUID" "$host" "$PORT" "$SNI" "$PUBLIC_KEY" "$SHORT_ID" "$NAME"
}

show_link() {
    load_info || die "no configuration found; run: sudo $0"
    local link
    link=$(share_link)
    say ""
    say "Share link (import it into v2rayN / v2rayNG / Shadowrocket / etc.):"
    say ""
    say "$link"
    say ""
    if command -v qrencode >/dev/null 2>&1; then
        qrencode -t ansiutf8 "$link"
    else
        say "(install qrencode to show a QR code: apt-get install qrencode)"
    fi
    say "Keep it private: anyone with this link can use your server."
}

# --- system -------------------------------------------------------------------

create_user() {
    if ! id "$SERVICE_USER" >/dev/null 2>&1; then
        step "creating system user $SERVICE_USER"
        useradd --system --no-create-home --home-dir /nonexistent \
            --shell /usr/sbin/nologin "$SERVICE_USER"
    fi
}

install_service() {
    step "installing the xray systemd service"
    cat > "$UNIT" <<EOF
[Unit]
Description=Xray (VLESS + REALITY), set up by vless-oneclick
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$SERVICE_USER
Group=$SERVICE_USER
Environment=XRAY_LOCATION_ASSET=$ASSET_DIR
ExecStart=$BIN run -config $CONFIG
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictNamespaces=true
LockPersonality=true

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable xray >/dev/null 2>&1
    systemctl restart xray
    sleep 1
    if systemctl is-active --quiet xray; then
        say "    xray is running"
    else
        say "    xray did not start, see: journalctl -u xray -n 50"
    fi
}

enable_bbr() {
    [ "${VLESS_BBR:-1}" = 0 ] && return 0
    if [ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" = bbr ]
    then
        step "TCP BBR is already enabled"
        return 0
    fi
    modprobe tcp_bbr 2>/dev/null || true
    if ! sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null |
            grep -qw bbr; then
        say "note: this kernel has no TCP BBR support; skipped"
        return 0
    fi
    step "enabling TCP BBR congestion control"
    if sysctl -q -w net.ipv4.tcp_congestion_control=bbr 2>/dev/null; then
        {
            echo "# added by vless-oneclick; delete this file (and"
            echo "# $BBR_MODULE) to go back to the default"
            echo "net.ipv4.tcp_congestion_control = bbr"
        } > "$BBR_CONF"
        # fq pacing helps BBR, but kernels >= 4.13 pace without it
        if sysctl -q -w net.core.default_qdisc=fq 2>/dev/null; then
            echo "net.core.default_qdisc = fq" >> "$BBR_CONF"
        fi
        echo tcp_bbr > "$BBR_MODULE"
    else
        say "note: could not enable TCP BBR (not allowed on this VPS type?)"
    fi
}

open_firewall() {
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null |
            grep -q 'Status: active'; then
        step "allowing TCP port $PORT in ufw"
        ufw allow "$PORT/tcp" >/dev/null
    else
        say "Remember to allow TCP port $PORT in your provider's firewall."
    fi
}

# --- commands -----------------------------------------------------------------

cmd_install() {
    need_root
    command -v apt-get >/dev/null 2>&1 ||
        die "this script supports Debian / Ubuntu only"
    command -v systemctl >/dev/null 2>&1 || die "systemd is required"
    install_packages
    install_xray
    create_user
    if [ -f "$INFO" ] && [ -f "$CONFIG" ]; then
        step "keeping the existing configuration"
        load_info
    else
        if [ -f "$CONFIG" ]; then
            say "An Xray configuration that wasn't made by this script exists:"
            say "  $CONFIG"
            confirm "Back it up and replace it?" ||
                die "nothing changed; move $CONFIG away first"
            cp -p "$CONFIG" "$CONFIG.bak-$(date +%Y%m%d%H%M%S)"
        fi
        new_config
    fi
    enable_bbr
    install_service
    open_firewall
    show_link
    say ""
    say "Useful commands:"
    say "  sudo $0 link          show this link again"
    say "  sudo $0 update        update Xray"
    say "  systemctl status xray, journalctl -u xray -f"
}

cmd_update() {
    need_root
    [ -f "$CONFIG" ] || die "not installed yet; run: sudo $0"
    install_xray
    "$BIN" run -test -config "$CONFIG" >/dev/null ||
        die "the new Xray rejects $CONFIG; see: $BIN run -test -config $CONFIG"
    systemctl restart xray
    step "xray restarted"
}

cmd_uninstall() {
    need_root
    step "removing the xray service"
    systemctl disable --now xray >/dev/null 2>&1 || true
    rm -f "$UNIT"
    systemctl daemon-reload 2>/dev/null || true
    rm -f "$BIN"
    rm -rf "$ASSET_DIR"
    if [ -f "$BBR_CONF" ]; then
        step "removing the TCP BBR setting (back to the default, cubic)"
        rm -f "$BBR_CONF" "$BBR_MODULE"
        sysctl -q -w net.ipv4.tcp_congestion_control=cubic 2>/dev/null || true
        sysctl -q --system >/dev/null 2>&1 || true
    fi
    if [ "${1:-}" = --purge ]; then
        step "removing $CONF_DIR and user $SERVICE_USER"
        rm -rf "$CONF_DIR"
        userdel "$SERVICE_USER" 2>/dev/null || true
    else
        say "kept the configuration in $CONF_DIR (use --purge to delete it)"
    fi
}

case "${1:-install}" in
    install) cmd_install ;;
    link) need_root; show_link ;;
    update) cmd_update ;;
    uninstall) shift; cmd_uninstall "$@" ;;
    -h | --help | help) sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//' ;;
    *) die "unknown command: $1 (try --help)" ;;
esac
