#!/usr/bin/env bash
# supergfx-gpu-dockswitch: automatic supergfxctl GPU mode policy for hybrid laptops.
#
# Policy:
#   AC power                       -> Hybrid
#   Battery + dGPU-routed display  -> Hybrid (that display needs the dGPU)
#   Battery + laptop-only / iGPU   -> Integrated (maximum battery life)
#
# Invariant: runtime events NEVER run a mode-changing command, and this
# script never runs `supergfxctl -m` at all. Runtime (udev) invocations
# only record the wanted mode in the pending store and notify. The mode
# is applied at the next boot: supergfx-gpu-dockswitch-pre.sh writes the intent
# into /etc/supergfxd.conf before supergfxd starts, and the daemon boots
# into that mode. --apply-at-boot (run by the post-daemon unit) only
# verifies and reconciles state; it refuses to act while a graphical
# session is up.
#
# Why so strict? Issuing a live mode switch while a Wayland compositor
# holds the dGPU makes supergfxd kill the compositor and can wedge
# shutdown. See README ("Design notes").
#
# Usage: supergfx-gpu-dockswitch.sh [--apply-at-boot|--check]
# Test hooks (env): SGD_GRAPHICAL_CHECK SGD_SET_TIMEOUT_S SGD_GET_TIMEOUT_S
#   SGD_STABLE_S SGD_NOTIFY_MIN_INTERVAL_S SGD_TEST_NO_SUDO, plus the
#   SGD_* hooks documented in lib/common.sh
set -u

# Load the shared library: installed location, or the repo checkout.
SGD_LIB=${SGD_LIB:-/usr/local/lib/supergfx-gpu-dockswitch/common.sh}
if [[ ! -r "$SGD_LIB" ]]; then
    SGD_LIB="$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
fi
# shellcheck disable=SC1090
[[ -r "$SGD_LIB" ]] && . "$SGD_LIB" || { echo "supergfx-gpu-dockswitch: cannot load $SGD_LIB" >&2; exit 1; }

GET_TIMEOUT_S=${SGD_GET_TIMEOUT_S:-${SUPERGFX_GPU_DOCKSWITCH_GET_TIMEOUT_S:-3}}
STABLE_S=${SGD_STABLE_S:-${SUPERGFX_GPU_DOCKSWITCH_STABLE_S:-45}}
NOTIFY_USER=${SGD_NOTIFY_USER:-${SUPERGFX_GPU_DOCKSWITCH_NOTIFY_USER:-}}
NOTIFY_MIN_INTERVAL_S=${SGD_NOTIFY_MIN_INTERVAL_S:-900}
RUN_USER_DIR=${SGD_RUN_USER_DIR:-/run/user}

ctl() { /usr/bin/timeout "$GET_TIMEOUT_S" "$SUPERGFXCTL" "$@" 2>/dev/null; }
active_mode() {
    local v; v=$(ctl -g) || v=""
    case "$v" in Hybrid|Integrated|AsusEgpuMode|Vfio) printf '%s' "$v" ;; *) printf 'unknown' ;; esac
}

graphical_session_active() {
    if [[ -n "${SGD_GRAPHICAL_CHECK:-}" ]]; then "$SGD_GRAPHICAL_CHECK" >/dev/null 2>&1; return $?; fi
    # Any compositor/session process, the greeter, or an active DM blocks.
    local p
    for p in kwin_wayland kwin_x11 gnome-shell plasmashell Xorg sway Hyprland; do
        /usr/bin/pgrep -x "$p" >/dev/null 2>&1 && return 0
    done
    [[ "$(/usr/bin/systemctl is-active display-manager.service 2>/dev/null)" == active ]] && return 0
    return 1
}

detect_notify_user() {
    # Configured user wins; otherwise the owner of the first user
    # session bus (uid >= 1000). Prints nothing when nobody is logged in.
    if [[ -n "$NOTIFY_USER" ]]; then printf '%s' "$NOTIFY_USER"; return 0; fi
    local bus uid
    for bus in "$RUN_USER_DIR"/*/bus; do
        [[ -S "$bus" ]] || continue
        uid=$(basename "$(dirname "$bus")")
        [[ "$uid" =~ ^[0-9]+$ ]] && (( uid >= 1000 )) || continue
        /usr/bin/id -un "$uid" 2>/dev/null && return 0
    done
    return 1
}
notify_user() { # $1=title $2=body
    local user tuid
    user=$(detect_notify_user) || return 0
    [[ -n "$user" ]] || return 0
    tuid=$(/usr/bin/id -u "$user" 2>/dev/null) || return 0
    if [[ -n "${SGD_TEST_NO_SUDO:-}" ]]; then
        "$NOTIFY_SEND" -a "supergfx-gpu-dockswitch" "$1" "$2" 2>/dev/null || true
        return 0
    fi
    [[ -S "$RUN_USER_DIR/$tuid/bus" ]] || return 0
    /usr/bin/sudo -u "$user" DBUS_SESSION_BUS_ADDRESS="unix:path=$RUN_USER_DIR/$tuid/bus" \
        "$NOTIFY_SEND" -a "supergfx-gpu-dockswitch" "$1" "$2" 2>/dev/null || true
}
notify_ratelimited() { # $1=key $2=title $3=body
    local stamp="$STAMP_DIR/notify-$1" now mtime
    mkdir -p "$STAMP_DIR" 2>/dev/null || return 0
    if [[ -f "$stamp" ]]; then
        now=$(date +%s); mtime=$(stat -c %Y "$stamp" 2>/dev/null || echo 0)
        (( now - mtime < NOTIFY_MIN_INTERVAL_S )) && return 0
    fi
    touch "$stamp"; notify_user "$2" "$3"
}

# Reconcile pending. Completion (pending==active) is reconciled first and
# does not require policy confidence, unless a reliable input contradicts
# it; only NEW policy decisions require policy_ok. Never switches mode.
reconcile_pending() {
    active=$(active_mode); local pend; pend=$(pending_read)
    if [[ "$active" == unknown ]]; then log decision_deferred "reason=active_mode_unknown pending_preserved=$pend"; return 2; fi
    policy_decide "$active"
    log observed "ac=$ac_state ext_dgpu=$ext_dgpu dgpu_availability=$dgpu_availability policy_ok=$policy_ok desired=${desired:-none} active=$active pending=$pend"
    if [[ "$policy_ok" == 1 ]]; then
        if [[ "$desired" == "$active" ]]; then
            pending_clear "desired_equals_active"
            rm -f "$STATE_DIR/intended-mode" "$STAMP_DIR"/notify-* 2>/dev/null
            return 0
        fi
        pending_write "$desired"
        notify_ratelimited "$desired" "GPU mode: $desired requested (current $active)" "Will apply at next reboot. Current session left untouched; not yet applied."
        return 0
    fi
    # No reliable new decision: completion of the already-applied request
    # is still reconcilable, and is not a claim of policy convergence.
    if [[ "$pend" == "$active" ]]; then
        pending_clear "request_completed_confirmed_active"
        rm -f "$STATE_DIR/intended-mode" 2>/dev/null
        log completion_reconciled "mode=$active policy_ok=0 (completion only, not convergence)"
        return 0
    fi
    log decision_deferred "reason=insufficient_policy_inputs active=$active pending_preserved=$pend"
    return 2
}

runtime_coordinator() {
    mkdir -p "$STAMP_DIR" "$STATE_DIR" 2>/dev/null || exit 0
    exec 9>"$STAMP_DIR/.coordinator.lock"
    if ! /usr/bin/flock -n 9; then
        # Coalesce: nanosecond generation makes each bump distinguishable;
        # the running coordinator restarts its wait and rechecks at the end.
        # Then queue (bounded) to become the successor coordinator, so an
        # event landing in the holder's final check-to-exit window is also
        # guaranteed a subsequent reevaluation rather than being lost.
        date +%s%N > "$STAMP_DIR/event-generation" 2>/dev/null || true
        log event_coalesced "coordinator_busy=1"
        /usr/bin/flock -w $(( STABLE_S + 60 )) 9 || exit 0
    fi
    # Debounce + decide, looping until no event arrived at any point up to
    # and including the decision itself. This closes the boundary race: an
    # event landing during reconcile_pending forces a fresh reevaluation
    # instead of leaving a stale pending write with no successor.
    while :; do
        local gen_before gen_mid gen_after
        gen_before=$(cat "$STAMP_DIR/event-generation" 2>/dev/null || echo 0)
        [[ "$STABLE_S" == 0 ]] || sleep "$STABLE_S"
        gen_mid=$(cat "$STAMP_DIR/event-generation" 2>/dev/null || echo 0)
        if [[ "$gen_mid" != "$gen_before" ]]; then
            log debounce_restarted "generation=$gen_before->$gen_mid"
            continue
        fi
        reconcile_pending || true
        gen_after=$(cat "$STAMP_DIR/event-generation" 2>/dev/null || echo 0)
        [[ "$gen_after" == "$gen_mid" ]] && break
        log decision_superseded "generation=$gen_mid->$gen_after reevaluating"
    done
    exit 0
}

apply_at_boot() {
    mkdir -p "$STAMP_DIR" "$STATE_DIR" 2>/dev/null || exit 0
    exec 9>"$STAMP_DIR/.apply.lock"
    /usr/bin/flock -n 9 || { log apply_skipped "reason=another_apply_running"; exit 0; }
    if graphical_session_active; then
        log transition_refused "reason=graphical_session_active pending_preserved=$(pending_read)"
        reconcile_pending || true
        exit 0
    fi
    # Completion FIRST, before any sensor gate: in Integrated mode the
    # dGPU DRM device is gone, so requiring full sensor confidence here
    # would keep a successful transition from ever being reconciled.
    active=$(active_mode)
    [[ "$active" != unknown ]] || { log decision_deferred "reason=active_mode_unknown pending_preserved=$(pending_read)"; exit 0; }
    local intended="" pend; pend=$(pending_read)
    [[ -f "$STATE_DIR/intended-mode" ]] && intended=$(cat "$STATE_DIR/intended-mode" 2>/dev/null)
    case "$intended" in Hybrid|Integrated) ;; *) intended="" ;; esac
    log observed "phase=boot active=$active intended=${intended:-none} pending=$pend"
    if [[ -n "$intended" && "$active" == "$intended" ]]; then
        rm -f "$STATE_DIR/intended-mode"
        if [[ "$pend" == "$intended" ]]; then
            pending_clear "verified_applied"
        else
            # A newer different pending request must survive completion
            # of the older intended mode.
            log completion_reconciled "intended=$intended newer_pending_preserved=$pend"
        fi
        log transition_verified "active=$active intended=$intended (daemon-reported)"
        # Any newer pending stays for the next pre-daemon cycle, which
        # recomputes policy from scratch.
        exit 0
    fi
    if [[ -n "$intended" ]]; then
        log transition_unverified "intended=$intended active=$active daemon_pend=$(ctl -P || echo unknown) pending_preserved=$pend"
        exit 1
    fi
    # No prepared intent (pre deferred): reconcile completion/policy only.
    reconcile_pending || true
    exit 0
}

if [[ -f "$OPT_OUT" ]]; then log disabled "opt_out=$OPT_OUT"; echo "disabled via $OPT_OUT"; exit 0; fi
case "${1:-}" in
    --apply-at-boot) apply_at_boot ;;
    --check)
        active=$(active_mode); policy_decide "$active"
        echo "want=${desired:-unknown} cur=$active pend=$(pending_read) daemon_pend=$(ctl -P || echo unknown) action=$(ctl -p || echo unknown) ac=$ac_state ext_dgpu=$ext_dgpu ext_igpu=$ext_igpu dgpu_availability=$dgpu_availability policy_ok=$policy_ok"
        ;;
    "") runtime_coordinator ;;
    *) echo "usage: $0 [--apply-at-boot|--check]" >&2; exit 2 ;;
esac
