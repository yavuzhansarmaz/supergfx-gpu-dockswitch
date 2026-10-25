#!/usr/bin/env bash
# Regression test for supergfx-gpu-dockswitch-pre.sh. No root needed.
# Mocks sysfs and a temporary supergfxd.conf; asserts the daemon config
# mode is rewritten only on a stable, confident policy decision, that
# all other config fields survive, and that uncertain sensors leave the
# config untouched.
# Usage: ./tests/test-pre.sh [path/to/supergfx-gpu-dockswitch-pre.sh]
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT=${1:-${SGD_PRE_SCRIPT:-$ROOT/bin/supergfx-gpu-dockswitch-pre.sh}}
T=$(mktemp -d /tmp/supergfx-gpu-dockswitch-pre-test.XXXXXX)
export T
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/sys/class/power_supply/AC0" \
         "$T/sys/class/drm/card0/device" "$T/sys/class/drm/card0-DP-1" \
         "$T/sys/class/drm/card1/device" "$T/sys/class/drm/card1-eDP-1" \
         "$T/state"
echo 0x10de > "$T/sys/class/drm/card0/device/vendor"
echo 0x1002 > "$T/sys/class/drm/card1/device/vendor"
echo connected > "$T/sys/class/drm/card1-eDP-1/status"
: > "$T/empty.conf"
export SGD_SYSFS="$T/sys" SGD_STATEDIR="$T/state" SGD_CONFIG="$T/empty.conf"
export SGD_SUPERGFXD_CONF="$T/supergfxd.conf" SGD_LOGGER=/bin/true
export SGD_LIB="$ROOT/lib/common.sh"
export SGD_PRE_STABLE_ATTEMPTS=3 SGD_PRE_STABLE_DELAY_S=0

set_power() { echo "$1" > "$T/sys/class/power_supply/AC0/online"; }
set_dp()    { echo "$1" > "$T/sys/class/drm/card0-DP-1/status"; }
set_conf()  { # $1=mode
    cat > "$T/supergfxd.conf" <<EOF
{
  "mode": "$1",
  "vfio_enable": false,
  "vfio_save": false,
  "always_reboot": true,
  "no_logind": false,
  "logout_timeout_s": 30,
  "hotplug_type": "None"
}
EOF
}
conf_mode() { /usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["mode"])' "$T/supergfxd.conf"; }
conf_field() { /usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$T/supergfxd.conf" "$1"; }
intended() { cat "$T/state/intended-mode" 2>/dev/null || echo none; }
reset_state() { rm -f "$T/state/intended-mode" "$T/state/pending-mode"; set_dp disconnected; }
fail() { echo "FAIL: $1"; exit 1; }

# 1. AC, config Integrated -> rewritten to Hybrid, intent recorded,
#    unrelated fields preserved byte-value.
reset_state; set_power 1; set_conf Integrated
"$SCRIPT" >/dev/null 2>&1 || fail "1.ac exits nonzero"
[[ "$(conf_mode)" == Hybrid ]] || fail "1.ac conf mode: $(conf_mode)"
[[ "$(intended)" == Hybrid ]] || fail "1.ac intended: $(intended)"
[[ "$(conf_field logout_timeout_s)" == 30 ]] || fail "1.ac logout_timeout_s changed"
[[ "$(conf_field always_reboot)" == True ]] || fail "1.ac always_reboot changed"

# 2. AC, config already Hybrid -> untouched mode, intent still recorded.
reset_state; set_power 1; set_conf Hybrid
"$SCRIPT" >/dev/null 2>&1 || fail "2.already exits nonzero"
[[ "$(conf_mode)" == Hybrid ]] || fail "2.already conf mode: $(conf_mode)"
[[ "$(intended)" == Hybrid ]] || fail "2.already intended: $(intended)"

# 3. battery laptop-only, config Hybrid -> rewritten to Integrated.
reset_state; set_power 0; set_conf Hybrid
"$SCRIPT" >/dev/null 2>&1 || fail "3.battery exits nonzero"
[[ "$(conf_mode)" == Integrated ]] || fail "3.battery conf mode: $(conf_mode)"
[[ "$(intended)" == Integrated ]] || fail "3.battery intended: $(intended)"

# 4. battery + dGPU-routed DP connected, config Integrated -> Hybrid.
reset_state; set_power 0; set_dp connected; set_conf Integrated
"$SCRIPT" >/dev/null 2>&1 || fail "4.battery-dp exits nonzero"
[[ "$(conf_mode)" == Hybrid ]] || fail "4.battery-dp conf mode: $(conf_mode)"

# 5. no AC information at all -> sensors uncertain, config untouched,
#    stale intent removed, pending preserved.
reset_state; rm -f "$T/sys/class/power_supply/AC0/online"; set_conf Integrated
echo Hybrid > "$T/state/intended-mode"; echo Hybrid > "$T/state/pending-mode"
"$SCRIPT" >/dev/null 2>&1 || fail "5.uncertain exits nonzero"
[[ "$(conf_mode)" == Integrated ]] || fail "5.uncertain conf changed: $(conf_mode)"
[[ "$(intended)" == none ]] || fail "5.uncertain intended not removed: $(intended)"
[[ "$(cat "$T/state/pending-mode")" == Hybrid ]] || fail "5.uncertain pending not preserved"
set_power 1 # restore for later scenarios

# 6. config mode outside Hybrid/Integrated (e.g. Vfio): never rewritten.
reset_state; set_power 1; set_conf Vfio
"$SCRIPT" >/dev/null 2>&1 || fail "6.invalid exits nonzero"
[[ "$(conf_mode)" == Vfio ]] || fail "6.invalid conf changed: $(conf_mode)"
[[ "$(intended)" == none ]] || fail "6.invalid intended written: $(intended)"

# 7. opt-out file: config untouched, exits quietly.
reset_state; set_power 1; set_conf Integrated; : > "$T/off"
SGD_OPT_OUT="$T/off" "$SCRIPT" >/dev/null 2>&1 || fail "7.optout exits nonzero"
[[ "$(conf_mode)" == Integrated ]] || fail "7.optout conf changed: $(conf_mode)"

# 8. malformed JSON config: untouched, exits quietly (deferred).
reset_state; set_power 1; echo 'not json' > "$T/supergfxd.conf"
"$SCRIPT" >/dev/null 2>&1 || fail "8.malformed exits nonzero"
[[ "$(cat "$T/supergfxd.conf")" == 'not json' ]] || fail "8.malformed conf changed"

echo "PASS: all supergfx-gpu-dockswitch-pre scenarios green"
