#!/bin/bash
# Real-system test (CI runner with passwordless sudo): a real wg-quick tunnel, the CLI, the real
# passwordless helper install, helper-driven up/down, and uninstall. Needs: wireguard-tools, ./build.sh done.
set -euo pipefail
cd "$(dirname "$0")/.."
APP=build/WGToggle.app
W="$APP/Contents/Resources/wgtoggle"
CONF_DIR="$(brew --prefix)/etc/wireguard"
fail() { echo "FAIL: $*" >&2; exit 1; }
state() { "$W" status --json | python3 -c "import json,sys; print({t['name']: t['state'] for t in json.load(sys.stdin)['tunnels']}.get('$1', 'missing'))"; }

mkdir -p "$CONF_DIR"
cat > "$CONF_DIR/ci.conf" <<CONF
[Interface]
PrivateKey = $(wg genkey)
Address = 10.99.0.2/32

[Peer]
PublicKey = $(wg genkey | wg pubkey)
Endpoint = 127.0.0.1:51820
AllowedIPs = 10.99.1.0/24
CONF
chmod 600 "$CONF_DIR/ci.conf"

echo "== CLI with Homebrew wg-quick (sudo)"
[[ "$(state ci)" == down ]] || fail "expected down before up"
"$W" up ci
[[ "$(state ci)" == up ]] || fail "expected up after wgtoggle up"
"$W" routes | grep -q "10.99.1.0/24" || fail "routes missing AllowedIPs"
"$W" status --strict > /dev/null || fail "strict status should be 0 when every state is known"
netstat -rn -f inet | grep -q "10.99.1" || fail "route not installed"
"$W" down ci
[[ "$(state ci)" == down ]] || fail "expected down after wgtoggle down"

echo "== passwordless helper: real install"
"$APP/Contents/MacOS/WGToggle" --diagnose --print-installer | sed -n '/^#!\/bin\/bash/,$p' > /tmp/wgt-install.sh
sudo /bin/bash /tmp/wgt-install.sh
[[ -f /etc/wireguard/ci.conf && "$(stat -f %u /etc/wireguard/ci.conf)" == 0 ]] || fail "config not migrated to root-owned /etc/wireguard"
rm -f "$CONF_DIR/ci.conf"   # the app does this after a successful install
H=/Library/PrivilegedHelperTools/wgtoggle/wgtoggle-helper
[[ "$(sudo -n $H version)" == "$(grep -o 'currentVersion = [0-9]*' Sources/Helper.swift | grep -o '[0-9]*')" ]] || fail "helper version"
sudo -n $H meta ci | grep -qi privatekey && fail "meta leaked a key"
sudo -n $H up '../x' && fail "helper accepted a bad name" || true
sudo -n $H status | tail -1 | grep -q '^end 0$' || fail "status end marker"

echo "== helper-driven up/down via the CLI"
"$W" up ci
[[ "$(state ci)" == up ]] || fail "expected up via helper"
sudo -n $H status | grep -q '^ci utun[0-9]* ' || fail "helper status missing ci"
"$W" status --json | grep -q '"interface"' || fail "no interface in status"
"$W" down ci
[[ "$(state ci)" == down ]] || fail "expected down via helper"

echo "== reinstall over an existing install (transaction path), then uninstall"
sudo /bin/bash /tmp/wgt-install.sh
[[ ! -e /var/db/wgtoggle-install.journal ]] || fail "journal left after a committed install"
sudo rm -f /etc/sudoers.d/wgtoggle && sudo rm -rf /Library/PrivilegedHelperTools/wgtoggle /etc/wireguard/ci.conf
echo "INTEGRATION PASSED"
