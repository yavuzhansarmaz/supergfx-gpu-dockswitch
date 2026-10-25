#!/usr/bin/env bash
# Regression test for supergfx-gpu-dockswitch.sh (runtime recorder + verification).
# No root needed. Mocks sysfs, supergfxctl and notify-send; asserts the
# core invariant that no code path ever invokes the mode-changing
# `supergfxctl -m`, and that the pending store follows policy.
# Usage: ./tests/test-runtime.sh [path/to/supergfx-gpu-dockswitch.sh]
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT=${1:-${SGD_SCRIPT:-$ROOT/bin/supergfx-gpu-dockswitch.sh}}
T=$(mktemp -d /tmp/supergfx-gpu-dockswitch-test.XXXXXX)
export T
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/sys/class/power_supply/AC0" \
         "$T/sys/class/drm/card0/device" "$T/sys/class/drm/card0-DP-1" \
         "$T/sys/class/drm/card1/device" "$T/sys/class/drm/card1-eDP-1" \
         "$T/sys/class/drm/card1-HDMI-A-1" \
         "$T/state" "$T/run" "$T/mockbin"
echo 0x10de > "$T/sys/class/drm/card0/device/vendor"   # NVIDIA dGPU
echo 0x1002 > "$T/sys/class/drm/card1/device/vendor"   # AMD iGPU
echo connected > "$T/sys/class/drm/card1-eDP-1/status" # internal panel
: > "$T/empty.conf"
export SGD_SYSFS="$T/sys" SGD_STATEDIR="$T/state" SGD_STAMPDIR="$T/run"
export SGD_CONFIG="$T/empty.conf" SGD_TEST_NO_SUDO=1 SGD_STABLE_S=0
export SGD_SUPERGFXCTL="$T/mockbin/supergfxctl" SGD_NOTIFY_SEND="$T/mockbin/notify-send"
export SGD_LOGGER="$T/mockbin/logger" SGD_NOTIFY_USER="$(id -un)"
export SGD_LIB="$ROOT/lib/common.sh"

cat > "$T/mockbin/supergfxctl" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$T/calllog"
case "$1" in
  -g) live=$(cat "$T/live"); [[ "$live" == FAIL ]] && exit 1; echo "$live" ;;
  -P) echo Unknown ;;
  -p) echo "No action required" ;;
  -m) echo "$2" > "$T/switch-attempted"; echo "queued $2" ;;
esac
EOF
cat > "$T/mockbin/notify-send" <<'EOF'
#!/usr/bin/env bash
echo "NOTIFY: $*" >> "$T/calllog"
EOF
cat > "$T/mockbin/logger" <<'EOF'
#!/usr/bin/env bash
echo "LOG: $*" >> "$T/calllog"
EOF
chmod +x "$T"/mockbin/*

set_power() { echo "$1" > "$T/sys/class/power_supply/AC0/online"; }
set_dp()    { echo "$1" > "$T/sys/class/drm/card0-DP-1/status"; }
set_hdmi()  { echo "$1" > "$T/sys/class/drm/card1-HDMI-A-1/status"; }
set_live()  { echo "$1" > "$T/live"; }
calls()     { local c; c=$(grep -c "$1" "$T/calllog" 2>/dev/null); echo "${c:-0}"; }
pending()   { cat "$T/state/pending-mode" 2>/dev/null || echo none; }
reset_all() {
    : > "$T/calllog"; rm -f "$T/switch-attempted" "$T/state/pending-mode" \
        "$T/state/intended-mode" "$T"/run/notify-* "$T/run/event-generation"
    set_dp disconnected; set_hdmi disconnected
}
fail() { echo "FAIL: $1"; echo "--- calllog ---"; cat "$T/calllog" 2>/dev/null; exit 1; }
no_switch() { # $1=scenario label: the invariant, asserted after every run
    [[ "$(calls '^-m')" == 0 ]] || fail "$1 invoked supergfxctl -m"
    [[ ! -e "$T/switch-attempted" ]] || fail "$1 attempted a mode switch"
}

# 1. converged (AC -> want Hybrid, live Hybrid): silent, no switch, no pending
reset_all; set_power 1; set_live Hybrid
out=$("$SCRIPT" 2>&1) || fail "1.converged exits nonzero: $out"
[[ -z "$out" ]] || fail "1.converged not silent: $out"
no_switch "1.converged"
[[ "$(calls '^NOTIFY')" == 0 ]] || fail "1.converged notified"
[[ "$(pending)" == none ]] || fail "1.converged pending: $(pending)"

# 2. battery, laptop-only, live Hybrid: record Integrated, notify once
reset_all; set_power 0; set_live Hybrid
"$SCRIPT" >/dev/null 2>&1 || fail "2.diverged exits nonzero"
no_switch "2.diverged"
[[ "$(pending)" == Integrated ]] || fail "2.diverged pending: $(pending)"
[[ "$(calls '^NOTIFY')" == 1 ]] || fail "2.diverged notify count: $(calls '^NOTIFY')"

# 3. diverged repeat fire: still no switch, notification rate-limited
"$SCRIPT" >/dev/null 2>&1 || fail "3.repeat exits nonzero"
no_switch "3.repeat"
[[ "$(calls '^NOTIFY')" == 1 ]] || fail "3.repeat re-notified"

# 4. battery + dGPU-routed DP connected: want Hybrid again, pending cleared
set_dp connected
"$SCRIPT" >/dev/null 2>&1 || fail "4.dgpu-display exits nonzero"
no_switch "4.dgpu-display"
[[ "$(pending)" == none ]] || fail "4.dgpu-display pending not cleared: $(pending)"

# 5. battery + only an iGPU-routed HDMI display: Integrated still wanted
reset_all; set_power 0; set_hdmi connected; set_live Hybrid
"$SCRIPT" >/dev/null 2>&1 || fail "5.igpu-display exits nonzero"
no_switch "5.igpu-display"
[[ "$(pending)" == Integrated ]] || fail "5.igpu-display pending: $(pending)"

# 6. AC but live Integrated: pending Hybrid recorded (applies next boot)
reset_all; set_power 1; set_live Integrated
"$SCRIPT" >/dev/null 2>&1 || fail "6.ac-integrated exits nonzero"
no_switch "6.ac-integrated"
[[ "$(pending)" == Hybrid ]] || fail "6.ac-integrated pending: $(pending)"

# 7. daemon unreachable: exit 0, existing pending preserved
set_live FAIL
"$SCRIPT" >/dev/null 2>&1 || fail "7.unreachable exits nonzero"
no_switch "7.unreachable"
[[ "$(pending)" == Hybrid ]] || fail "7.unreachable pending not preserved: $(pending)"

# 8. --check reports policy inputs
reset_all; set_power 1; set_dp connected; set_live Hybrid
out=$("$SCRIPT" --check 2>/dev/null) || fail "8.check exits nonzero"
[[ "$out" == *"want=Hybrid"* && "$out" == *"cur=Hybrid"* && "$out" == *"ext_dgpu=1"* && "$out" == *"policy_ok=1"* ]] \
    || fail "8.check output: $out"

# 9. opt-out file disables everything
reset_all; set_power 0; set_live Hybrid; echo Integrated > "$T/state/pending-mode"
: > "$T/off"
out=$(SGD_OPT_OUT="$T/off" "$SCRIPT" 2>&1) || fail "9.optout exits nonzero"
[[ "$out" == *"disabled via"* ]] || fail "9.optout output: $out"
no_switch "9.optout"

# 10. --apply-at-boot verifies a completed transition and cleans state
reset_all; set_power 0; set_live Integrated
echo Integrated > "$T/state/intended-mode"; echo Integrated > "$T/state/pending-mode"
SGD_GRAPHICAL_CHECK=/bin/false "$SCRIPT" --apply-at-boot >/dev/null 2>&1 \
    || fail "10.verified exits nonzero"
no_switch "10.verified"
[[ ! -e "$T/state/intended-mode" ]] || fail "10.verified intended not removed"
[[ "$(pending)" == none ]] || fail "10.verified pending: $(pending)"

# 11. --apply-at-boot with a graphical session up: refuses, records only
reset_all; set_power 0; set_live Hybrid; echo Integrated > "$T/state/pending-mode"
SGD_GRAPHICAL_CHECK=/bin/true "$SCRIPT" --apply-at-boot >/dev/null 2>&1 \
    || fail "11.guarded exits nonzero"
no_switch "11.guarded"
[[ "$(pending)" == Integrated ]] || fail "11.guarded pending: $(pending)"
[[ ! -e "$T/state/intended-mode" ]] || fail "11.guarded wrote intended-mode"

# 12. transient flap inside the stability window: AC returns before the
#     decision, so nothing is recorded or notified.
reset_all; set_power 0; set_live Hybrid
( sleep 0.3; set_power 1 ) &
SGD_STABLE_S=1 "$SCRIPT" >/dev/null 2>&1 || fail "12.flap exits nonzero"
wait
no_switch "12.flap"
[[ "$(pending)" == none ]] || fail "12.flap recorded pending: $(pending)"
[[ "$(calls '^NOTIFY')" == 0 ]] || fail "12.flap notified"

# 13. daemon stops answering entirely (wedged): every query is
#     time-capped, exit 0 quietly, record nothing.
reset_all; set_power 0; set_live Hybrid
printf '#!/usr/bin/env bash\nsleep 120\n' > "$T/mockbin/supergfxctl-hang"
chmod +x "$T/mockbin/supergfxctl-hang"
start=$(date +%s)
timeout 15 env SGD_SUPERGFXCTL="$T/mockbin/supergfxctl-hang" SGD_GET_TIMEOUT_S=2 \
    "$SCRIPT" >/dev/null 2>&1 || fail "13.hang exits nonzero or hit the 15s outer cap"
elapsed=$(( $(date +%s) - start ))
(( elapsed < 10 )) || fail "13.hang took too long: ${elapsed}s"
[[ "$(pending)" == none ]] || fail "13.hang recorded pending: $(pending)"
[[ "$(calls '^NOTIFY')" == 0 ]] || fail "13.hang notified"

# 14. concurrent runtime fires collapse: one decision, one notify.
reset_all; set_power 0; set_live Hybrid
SGD_STABLE_S=1 "$SCRIPT" >/dev/null 2>&1 & p1=$!
SGD_STABLE_S=1 "$SCRIPT" >/dev/null 2>&1 & p2=$!
wait "$p1" "$p2" || fail "14.parallel exits nonzero"
no_switch "14.parallel"
[[ "$(pending)" == Integrated ]] || fail "14.parallel pending: $(pending)"
[[ "$(calls '^NOTIFY')" == 1 ]] || fail "14.parallel notify count: $(calls '^NOTIFY')"

echo "PASS: all supergfx-gpu-dockswitch runtime scenarios green"
