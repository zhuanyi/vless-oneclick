# vless-oneclick

One command to set up a private [Xray](https://github.com/XTLS/Xray-core)
**VLESS + REALITY** server on a Debian or Ubuntu VPS, and get a share link
and QR code for your devices.

REALITY makes the server look like an ordinary, well-known HTTPS website:
visitors without your key simply see that website, with its real
certificate. No domain name or certificate of your own is needed.

## Install

On the server (Debian 11+ / Ubuntu 20.04+, with systemd), as root:

    git clone https://github.com/zhuanyi/vless-oneclick.git
    cd vless-oneclick
    sudo ./install.sh

or, without git:

    curl -fsSLO https://raw.githubusercontent.com/zhuanyi/vless-oneclick/main/install.sh
    sudo bash install.sh

It asks a few questions (press Enter to accept the suggested value):

| question | default | notes |
|---|---|---|
| port | 443 | 443 is where HTTPS normally runs, so it blends in best |
| website to look like | www.microsoft.com | see [Choosing the website](#choosing-the-website) |
| server address | detected public IP | used in the share link; a domain name also works |
| profile name | the server's host name | shown in the apps |

Then it:

1. downloads the latest Xray release from its official GitHub releases and
   verifies its SHA-256 checksum,
2. generates a user ID, an X25519 key pair and a short ID,
3. writes `/usr/local/etc/xray/config.json` and checks it with Xray,
4. enables TCP BBR congestion control (usually faster on long-distance
   links; skipped if the VPS doesn't allow it),
5. installs and starts the `xray` systemd service, running as an
   unprivileged `xray` user,
6. opens the port in `ufw` if it is active,
7. prints the `vless://` share link and a QR code.

Remember to also allow the TCP port in your VPS provider's firewall /
security group, if it has one.

## Connecting your devices

Scan the QR code or import the link from the clipboard in:

| platform | app |
|---|---|
| Windows, Linux, macOS | [v2rayN](https://github.com/2dust/v2rayN/releases) |
| Android | [v2rayNG](https://github.com/2dust/v2rayNG/releases) (`*_arm64-v8a.apk` for current phones) |
| iOS | Shadowrocket, or other apps that support VLESS + REALITY |
| any | apps based on sing-box, Xray or mihomo (Hiddify, Clash Verge Rev, ...) |

All your devices can use the same link at the same time.

## Commands

    sudo ./install.sh                     install, or re-run to repair / upgrade
    sudo ./install.sh link                show the share link and QR code again
    sudo ./install.sh update              update Xray, keep the configuration
    sudo ./install.sh uninstall           remove Xray, keep the configuration
    sudo ./install.sh uninstall --purge   remove everything

Running `install.sh` again keeps the existing configuration, so the share
link stays the same. To start over with new keys, run
`uninstall --purge` first.

Service: `systemctl status xray`, `systemctl restart xray`,
`journalctl -u xray -f`.

## Choosing the website

The server imitates a real website, and connects to it on behalf of
visitors who don't have your key. A good choice:

* is a large, well-known HTTPS site that is reachable from your server and
  from where your devices are,
* supports TLS 1.3 and HTTP/2 (the installer checks this, and that the site
  has a valid certificate),
* is ideally hosted close to your server (same country or provider), so the
  timing looks natural,
* is not your own site and not behind a login.

You can change it later: edit `target` and `serverNames` in
`/usr/local/etc/xray/config.json` and `SNI` in
`/usr/local/etc/xray/vless-oneclick.env`, run `systemctl restart xray`,
then share the new link (`sudo ./install.sh link`).

## Options

Set these before running the script, e.g.
`sudo VLESS_PORT=8443 ./install.sh`:

| variable | meaning |
|---|---|
| `VLESS_PORT` | listening port (default 443) |
| `VLESS_SNI` | website to look like (default www.microsoft.com) |
| `VLESS_HOST` | server address in the share link (default: detected) |
| `VLESS_NAME` | profile name in the apps |
| `VLESS_BBR=0` | don't enable TCP BBR |
| `XRAY_VERSION` | Xray release to install, e.g. `v26.3.27` (default: latest) |
| `XRAY_ZIP` | install from a local `Xray-linux-*.zip` instead of downloading |
| `VLESS_NONINTERACTIVE=1` | never ask; use the variables above or the defaults |

Without a terminal (e.g. from a provisioning script) it never asks either.

If GitHub downloads are slow or unavailable from the server, download the
right `Xray-linux-*.zip` (`64` for x86-64, `arm64-v8a` for ARM) from the
[Xray releases](https://github.com/XTLS/Xray-core/releases) elsewhere, copy
it to the server and run `sudo XRAY_ZIP=./Xray-linux-64.zip ./install.sh`.

## Files

| path | contents |
|---|---|
| `/usr/local/bin/xray` | Xray |
| `/usr/local/share/xray/` | Xray's geoip / geosite data |
| `/usr/local/etc/xray/config.json` | server configuration (root and `xray` only) |
| `/usr/local/etc/xray/vless-oneclick.env` | values for the share link (root only) |
| `/etc/systemd/system/xray.service` | systemd service |
| `/etc/sysctl.d/90-vless-oneclick-bbr.conf` | TCP BBR setting |

## Notes

* The share link contains the key: anyone who has it can use your server,
  so share it privately.
* Clients can't reach the server's own `localhost` or private networks
  through it.
* Other services on the same server keep working, e.g. a Shadowsocks
  server on a different port.
* The default flow is `xtls-rprx-vision` with the `chrome` TLS fingerprint,
  which is what most clients expect.

## License

MIT, see [LICENSE](LICENSE). Xray itself is developed by Project X and
licensed under MPL-2.0; this script only downloads and configures it.
