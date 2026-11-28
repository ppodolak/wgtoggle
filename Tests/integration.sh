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
grep -q "10.99.1.0/24" <<< "$("$W" routes)" || fail "routes missing AllowedIPs"
"$W" status --strict > /dev/null || fail "strict status should be 0 when every state is known"
grep -q "10.99.1" <<< "$(netstat -rn -f inet)" || fail "route not installed"
"$W" down ci
[[ "$(state ci)" == down ]] || fail "expected down after wgtoggle down"

echo "== passwordless helper: real install"
"$APP/Contents/MacOS/WGToggle" --diagnose --print-installer > /tmp/wgt-install.sh
sudo /bin/bash /tmp/wgt-install.sh
[[ -f /etc/wireguard/ci.conf && "$(stat -f %u /etc/wireguard/ci.conf)" == 0 ]] || fail "config not migrated to root-owned /etc/wireguard"
rm -f "$CONF_DIR/ci.conf"   # the app does this after a successful install
H=/Library/PrivilegedHelperTools/wgtoggle/wgtoggle-helper
[[ "$(sudo -n $H version)" == "$(grep -o 'currentVersion = [0-9]*' Sources/Helper.swift | grep -o '[0-9]*')" ]] || fail "helper version"
grep -qi privatekey <<< "$(sudo -n $H meta ci)" && fail "meta leaked a key"
sudo -n $H up '../x' && fail "helper accepted a bad name" || true
[[ "$(sudo -n $H status | tail -1)" == "end 0" ]] || fail "status end marker"

echo "== helper-driven up/down via the CLI"
"$W" up ci
[[ "$(state ci)" == up ]] || fail "expected up via helper"
grep -qE '^ci utun[0-9]+ ' <<< "$(sudo -n $H status)" || fail "helper status missing ci"
grep -q '"interface"' <<< "$("$W" status --json)" || fail "no interface in status"
"$W" down ci
[[ "$(state ci)" == down ]] || fail "expected down via helper"

echo "== reinstall over an existing install (the app's update path), then uninstall"
"$APP/Contents/MacOS/WGToggle" --diagnose --print-installer > /tmp/wgt-install.sh
sudo /bin/bash /tmp/wgt-install.sh
[[ -f /etc/wireguard/ci.conf ]] || fail "config lost on reinstall"
"$W" up ci; [[ "$(state ci)" == up ]] || fail "up after reinstall"; "$W" down ci
[[ ! -e /var/db/wgtoggle-install.journal ]] || fail "journal left after a committed install"
sudo rm -f /etc/sudoers.d/wgtoggle && sudo rm -rf /Library/PrivilegedHelperTools/wgtoggle /etc/wireguard/ci.conf
echo "== connectivity check and Network Inspector data path"
"$W" check ci 127.0.0.1:9 > /dev/null
[[ "$("$W" check ci)" == "127.0.0.1:9" ]] || fail "check not stored"
"$W" check ci --clear > /dev/null
echo "INTEGRATION PASSED"
