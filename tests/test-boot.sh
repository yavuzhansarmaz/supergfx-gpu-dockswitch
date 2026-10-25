#!/usr/bin/env bash
# Regression test for supergfx-gpu-dockswitch-boot.sh. No root needed.
# Mocks supergfxctl and the policy script; asserts the readiness wait is
# time-bounded even when a daemon call hangs forever, that a ready daemon
# leads to exactly one policy run, that a missing daemon exits quietly
# without running the policy, and that the UCSI Type-C re-negotiation
# fires only in the guarded boot-switch case.
# Usage: ./tests/test-boot.sh [path/to/supergfx-gpu-dockswitch-boot.sh]
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT=${1:-${SGD_BOOT_SCRIPT:-$ROOT/bin/supergfx-gpu-dockswitch-boot.sh}}
T=$(mktemp -d /tmp/supergfx-gpu-dockswitch-boot-test.XXXXXX)
export T
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/mockbin"
export SGD_SUPERGFXCTL="$T/mockbin/supergfxctl"
export SGD_GFX_AUTO="$T/mockbin/supergfx-gpu-dockswitch.sh"
export SGD_GET_TIMEOUT_S=2 SGD_BOOT_WAIT_ATTEMPTS=3 SGD_BOOT_WAIT_DELAY_S=0
export SGD_LOGGER=/bin/true

cat > "$T/mockbin/supergfxctl" <<'EOF'
#!/usr/bin/env bash
case "$(cat "$T/mode")" in
  hang) sleep 120 ;;
  dead) exit 1 ;;
  *)    echo Hybrid ;;
esac
EOF
cat > "$T/mockbin/supergfx-gpu-dockswitch.sh" <<'EOF'
#!/usr/bin/env bash
echo "POLICY-RUN" >> "$T/calllog"
EOF
chmod +x "$T"/mockbin/*

set_mode() { echo "$1" > "$T/mode"; }
policy_runs() { local c; c=$(grep -c '^POLICY-RUN' "$T/calllog" 2>/dev/null); echo "${c:-0}"; }
fail() { echo "FAIL: $1"; exit 1; }

# 1. hanging daemon call: must give up bounded and quiet, policy never runs.
set_mode hang; : > "$T/calllog"
start=$(date +%s)
timeout 25 "$SCRIPT" >/dev/null 2>&1 || fail "1.hang exits nonzero or hit the 25s outer cap"
elapsed=$(( $(date +%s) - start ))
(( elapsed < 20 )) || fail "1.hang took too long: ${elapsed}s"
[[ "$(policy_runs)" == 0 ]] || fail "1.hang ran the policy"

# 2. ready daemon: policy runs exactly once.
set_mode ready; : > "$T/calllog"
timeout 25 "$SCRIPT" >/dev/null 2>&1 || fail "2.ready exits nonzero"
[[ "$(policy_runs)" == 1 ]] || fail "2.ready policy runs: $(policy_runs)"

# 3. daemon never appears: quiet exit 0, policy never runs.
set_mode dead; : > "$T/calllog"
start=$(date +%s)
timeout 25 "$SCRIPT" >/dev/null 2>&1 || fail "3.dead exits nonzero or hit the 25s outer cap"
elapsed=$(( $(date +%s) - start ))
(( elapsed < 20 )) || fail "3.dead took too long: ${elapsed}s"
[[ "$(policy_runs)" == 0 ]] || fail "3.dead ran the policy"

# --- Type-C DP re-negotiation after an Integrated -> Hybrid boot switch ---
# Stateful mocks: live mode flips to Hybrid when the policy runs; mock sysfs
# carries a Type-C partner that never entered an alternate mode plus a
# disconnected DP connector; the UCSI driver bind/unbind files record writes.
mkdir -p "$T/sys/class/drm/card0-DP-1" "$T/sys/class/typec/port0-partner" \
         "$T/sys/bus/platform/drivers/ucsi_acpi/USBC000:00"
export SGD_SYSFS="$T/sys" SGD_UCSI_SETTLE_S=0 SGD_CONVERGE_ATTEMPTS=5 SGD_CONVERGE_DELAY_S=0
cat > "$T/mockbin/supergfxctl" <<'EOF'
#!/usr/bin/env bash
case "$(cat "$T/mode")" in
  hang) sleep 120 ;;
  dead) exit 1 ;;
  *)    cat "$T/live" ;;
esac
EOF
cat > "$T/mockbin/supergfx-gpu-dockswitch.sh" <<'EOF'
#!/usr/bin/env bash
echo "POLICY-RUN" >> "$T/calllog"
echo Hybrid > "$T/live"
EOF
chmod +x "$T"/mockbin/*
echo disconnected > "$T/sys/class/drm/card0-DP-1/status"
echo 0 > "$T/sys/class/typec/port0-partner/number_of_alternate_modes"
: > "$T/sys/bus/platform/drivers/ucsi_acpi/unbind"
: > "$T/sys/bus/platform/drivers/ucsi_acpi/bind"
ucsi_writes() { cat "$T/sys/bus/platform/drivers/ucsi_acpi/$1"; }

# 4. booted Integrated, policy switched to Hybrid, DP still dark with a
#    partner stuck at 0 alt modes: UCSI rebind fires exactly once.
set_mode ready; echo Integrated > "$T/live"; : > "$T/calllog"
: > "$T/sys/bus/platform/drivers/ucsi_acpi/unbind"; : > "$T/sys/bus/platform/drivers/ucsi_acpi/bind"
timeout 25 "$SCRIPT" >/dev/null 2>&1 || fail "4.rebind exits nonzero"
[[ "$(policy_runs)" == 1 ]] || fail "4.rebind policy runs: $(policy_runs)"
[[ "$(ucsi_writes unbind)" == "USBC000:00" ]] || fail "4.rebind unbind not written: '$(ucsi_writes unbind)'"
[[ "$(ucsi_writes bind)" == "USBC000:00" ]] || fail "4.rebind bind not written: '$(ucsi_writes bind)'"

# 5. same switch, but DP came up on its own: no rebind.
echo connected > "$T/sys/class/drm/card0-DP-1/status"
: > "$T/sys/bus/platform/drivers/ucsi_acpi/unbind"; : > "$T/sys/bus/platform/drivers/ucsi_acpi/bind"
echo Integrated > "$T/live"
timeout 25 "$SCRIPT" >/dev/null 2>&1 || fail "5.lit exits nonzero"
[[ -z "$(ucsi_writes unbind)" && -z "$(ucsi_writes bind)" ]] || fail "5.lit rebound a lit DP"

# 6. booted already Hybrid (no switch this boot): no rebind even if DP dark.
echo disconnected > "$T/sys/class/drm/card0-DP-1/status"
echo Hybrid > "$T/live"
timeout 25 "$SCRIPT" >/dev/null 2>&1 || fail "6.hybrid exits nonzero"
[[ -z "$(ucsi_writes unbind)" && -z "$(ucsi_writes bind)" ]] || fail "6.hybrid rebound without a mode switch"

# 7. partner did enter an alt mode (not stuck): no rebind.
echo 1 > "$T/sys/class/typec/port0-partner/number_of_alternate_modes"
echo Integrated > "$T/live"
timeout 25 "$SCRIPT" >/dev/null 2>&1 || fail "7.altmode exits nonzero"
[[ -z "$(ucsi_writes unbind)" && -z "$(ucsi_writes bind)" ]] || fail "7.altmode rebound a negotiated partner"

echo "PASS: all supergfx-gpu-dockswitch-boot scenarios green"
