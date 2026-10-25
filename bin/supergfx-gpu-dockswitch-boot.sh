#!/usr/bin/env bash
# Boot-time driver for supergfx-gpu-dockswitch.sh: wait for supergfxd readiness,
# then run the verification pass once. Quiet when the daemon never
# appears (ordered after supergfxd.service, but never pulls it in if
# deliberately disabled). This script makes no mode changes.
#
# Every daemon call is capped with timeout. Worst-case budget against
# TimeoutStartSec=120 (all calls timing out, which never happens with a
# live daemon since each returns in milliseconds):
#   readiness  6 * (3s timeout + 1s)   = 24s
#   policy     verification pass      <= 58s
#   converge   5 * (3s + 1s)           = 20s
#   UCSI settle                        =  2s
#   total                              = 104s < 120s
#
# After an Integrated -> Hybrid boot switch, an already-plugged USB-C
# display can stay dark: supergfxd removed the dGPU (including its
# Type-C path) for Integrated, the partner's DP alt-mode attempt fell
# back to USB Billboard, and switching back never generates a new
# attach event, so the DP connector reads disconnected until a physical
# replug. Cure: once Hybrid has converged, if a DP connector is still
# disconnected while a Type-C partner is present with 0 alternate
# modes, rebind the UCSI driver once. The PPM reset re-runs partner
# negotiation exactly like a replug, without touching the cable.
# Guarded to this boot-switch case only; a display that lit on its own
# is never disturbed.
#
# Test hooks (env): SGD_SUPERGFXCTL SGD_GFX_AUTO SGD_GET_TIMEOUT_S
#   SGD_BOOT_WAIT_ATTEMPTS SGD_BOOT_WAIT_DELAY_S SGD_SYSFS SGD_LOGGER
#   SGD_CONVERGE_ATTEMPTS SGD_CONVERGE_DELAY_S SGD_UCSI_SETTLE_S
set -u
SUPERGFXCTL=${SGD_SUPERGFXCTL:-/usr/bin/supergfxctl}
GFX_AUTO=${SGD_GFX_AUTO:-/usr/local/bin/supergfx-gpu-dockswitch.sh}
GET_TIMEOUT_S=${SGD_GET_TIMEOUT_S:-3}
ATTEMPTS=${SGD_BOOT_WAIT_ATTEMPTS:-6}
DELAY_S=${SGD_BOOT_WAIT_DELAY_S:-1}
SYSFS=${SGD_SYSFS:-/sys}
LOGGER=${SGD_LOGGER:-/usr/bin/logger}
CONVERGE_ATTEMPTS=${SGD_CONVERGE_ATTEMPTS:-5}
CONVERGE_DELAY_S=${SGD_CONVERGE_DELAY_S:-1}
UCSI_SETTLE_S=${SGD_UCSI_SETTLE_S:-2}

log() { "$LOGGER" -t supergfx-gpu-dockswitch-boot "$*" 2>/dev/null || true; }
live_mode() { /usr/bin/timeout "$GET_TIMEOUT_S" "$SUPERGFXCTL" -g 2>/dev/null || echo unknown; }

ready=0; cur=""
for _ in $(seq 1 "$ATTEMPTS"); do
    cur=$(live_mode)
    if [[ -n "$cur" && "$cur" != "unknown" ]]; then
        ready=1
        break
    fi
    sleep "$DELAY_S"
done
[[ "$ready" == 1 ]] || exit 0
boot_mode=$cur

# --apply-at-boot is the verification pass; it still refuses to act if
# a compositor is already up (e.g. this unit started by hand mid-session).
"$GFX_AUTO" --apply-at-boot; gfx_rc=$?
[[ "$gfx_rc" == 0 ]] || log "policy verify failed rc=$gfx_rc; pending preserved for next safe boot"

# Type-C DP re-negotiation: only after this boot actually switched
# Integrated -> Hybrid (a plain Hybrid boot negotiated at plug time).
[[ "$boot_mode" == Integrated ]] || exit 0
converged=""
for _ in $(seq 1 "$CONVERGE_ATTEMPTS"); do
    if [[ "$(live_mode)" == Hybrid ]]; then converged=1; break; fi
    sleep "$CONVERGE_DELAY_S"
done
[[ -n "$converged" ]] || { log "no Hybrid convergence, skipping Type-C re-negotiation"; exit 0; }

dp_disconnected=0
for st in "$SYSFS"/class/drm/card*-DP-*/status; do
    [[ -r "$st" ]] || continue
    [[ "$(cat "$st" 2>/dev/null)" == disconnected ]] && dp_disconnected=1
done
partner_stuck=0
for modes in "$SYSFS"/class/typec/port*-partner/number_of_alternate_modes; do
    [[ -r "$modes" ]] || continue
    [[ "$(cat "$modes" 2>/dev/null)" == 0 ]] && partner_stuck=1
done
[[ "$dp_disconnected" == 1 && "$partner_stuck" == 1 ]] || exit 0

ucsi_driver="$SYSFS/bus/platform/drivers/ucsi_acpi"
[[ -w "$ucsi_driver/unbind" && -w "$ucsi_driver/bind" ]] || { log "UCSI driver not writable, skipping re-negotiation"; exit 0; }
dev=""
for d in "$ucsi_driver"/USBC*; do
    [[ -e "$d" ]] && { dev=$(basename "$d"); break; }
done
[[ -n "$dev" ]] || exit 0

log "Type-C partner stuck without alt mode after Integrated->Hybrid switch; rebinding UCSI ($dev) to re-negotiate DP"
echo "$dev" > "$ucsi_driver/unbind" 2>/dev/null || exit 0
sleep "$UCSI_SETTLE_S"
echo "$dev" > "$ucsi_driver/bind" 2>/dev/null || true
exit 0
