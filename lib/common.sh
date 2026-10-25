# supergfx-gpu-dockswitch shared library: configuration, observation, policy, and
# the pending-mode store. Sourced by supergfx-gpu-dockswitch.sh and
# supergfx-gpu-dockswitch-pre.sh; never executed directly.
#
# Concepts kept distinct:
#   observed_state = AC + connector state read from sysfs
#   desired_mode   = pure policy output (Hybrid|Integrated), no side effects
#   active_mode    = `supergfxctl -g` (may be "unknown")
#   pending_mode   = single authoritative file $STATE_DIR/pending-mode
#                    (Hybrid|Integrated, atomically replaced). The daemon's
#                    own -P value is reported for diagnostics only and is
#                    never a second source of truth.
#
# Hardware assumption: one integrated GPU (iGPU) and one NVIDIA discrete
# GPU (dGPU). Only external connectors routed to the dGPU force Hybrid:
# an HDMI port wired to the iGPU keeps working in Integrated mode, while
# a USB-C/DP port wired to the dGPU goes dark without it. Vendor ids are
# configurable (see config/supergfx-gpu-dockswitch.conf.example).
#
# Opt out: touch /etc/supergfx-gpu-dockswitch/off
# Test hooks (env): SGD_SYSFS SGD_STATEDIR SGD_STAMPDIR SGD_SUPERGFXCTL
#   SGD_NOTIFY_SEND SGD_LOGGER SGD_OPT_OUT SGD_CONFIG SGD_DGPU_VENDOR
#   SGD_IGPU_VENDOR SGD_NOTIFY_USER SGD_LOG_TAG
[[ -n "${SGD_COMMON_LOADED:-}" ]] && return 0
SGD_COMMON_LOADED=1

# User configuration (root-owned) provides defaults; SGD_* environment
# variables (used by tests) override it.
SGD_CONFIG=${SGD_CONFIG:-/etc/supergfx-gpu-dockswitch.conf}
# shellcheck disable=SC1090
[[ -r "$SGD_CONFIG" ]] && . "$SGD_CONFIG"

OPT_OUT=${SGD_OPT_OUT:-/etc/supergfx-gpu-dockswitch/off}
SYSFS=${SGD_SYSFS:-/sys}
STATE_DIR=${SGD_STATEDIR:-/var/lib/supergfx-gpu-dockswitch}
STAMP_DIR=${SGD_STAMPDIR:-/run/supergfx-gpu-dockswitch}
SUPERGFXCTL=${SGD_SUPERGFXCTL:-/usr/bin/supergfxctl}
NOTIFY_SEND=${SGD_NOTIFY_SEND:-/usr/bin/notify-send}
LOGGER=${SGD_LOGGER:-/usr/bin/logger}
LOG_TAG=${SGD_LOG_TAG:-supergfx-gpu-dockswitch}
DGPU_VENDOR=${SGD_DGPU_VENDOR:-${SUPERGFX_GPU_DOCKSWITCH_DGPU_VENDOR:-0x10de}}
IGPU_VENDOR=${SGD_IGPU_VENDOR:-${SUPERGFX_GPU_DOCKSWITCH_IGPU_VENDOR:-0x1002}}

log() { "$LOGGER" -t "$LOG_TAG" "event=$1 ${2:-}" 2>/dev/null || true; }

# ---- observation (no side effects beyond logging) ----
sensor_ok=1; ac_state=unknown; ext_dgpu=0; ext_igpu=0
dgpu_availability=absent; igpu_present=0; connector_ok=1
read_observed() {
    sensor_ok=1; ext_dgpu=0; ext_igpu=0; ac_state=unknown
    local f v seen_ac="" seen_batt=""
    for f in "$SYSFS"/class/power_supply/A*/online; do
        [[ -r "$f" ]] || continue
        v=$(cat "$f" 2>/dev/null) || v=""
        case "$v" in 1) seen_ac=1 ;; 0) seen_batt=1 ;; *) sensor_ok=0 ;; esac
    done
    if [[ -n "$seen_ac" && -n "$seen_batt" ]]; then
        ac_state=contradictory; sensor_ok=0; log sensor_uncertain "ac=contradictory"
    elif [[ -n "$seen_ac" ]]; then ac_state=ac
    elif [[ -n "$seen_batt" ]]; then ac_state=battery
    else sensor_ok=0; fi
    local dev ven seen_dgpu_dev=0 seen_igpu_dev=0 any_connector=0
    for dev in "$SYSFS"/class/drm/card[0-9]; do
        [[ -e "$dev/device/vendor" ]] || continue
        ven=$(cat "$dev/device/vendor" 2>/dev/null) || ven=""
        case "$ven" in
            "$DGPU_VENDOR") seen_dgpu_dev=1 ;;
            "$IGPU_VENDOR") seen_igpu_dev=1 ;;
        esac
    done
    # Availability is tracked, not gated here: an absent dGPU DRM device
    # is the NORMAL consequence of Integrated mode (the daemon removed
    # the dGPU), not a sensor fault. Policy decides what absence means.
    dgpu_availability=absent; [[ "$seen_dgpu_dev" == 1 ]] && dgpu_availability=available
    igpu_present=$seen_igpu_dev; connector_ok=1
    if [[ "$seen_igpu_dev" != 1 ]]; then
        sensor_ok=0; log sensor_uncertain "gpu_devices igpu=0 (iGPU not enumerated)"
    fi
    local st card vendor status
    for st in "$SYSFS"/class/drm/card*-*/status; do
        [[ -e "$st" ]] || continue
        any_connector=1
        status=$(cat "$st" 2>/dev/null) || status=""
        case "$status" in connected|disconnected) ;; *) connector_ok=0; sensor_ok=0; log sensor_uncertain "connector=$(basename "$(dirname "$st")") status=${status:-unreadable}"; continue ;; esac
        [[ "$status" == connected ]] || continue
        card=$(basename "$(dirname "$st")"); card=${card%%-*}
        vendor=$(cat "$SYSFS/class/drm/$card/device/vendor" 2>/dev/null) || vendor=""
        case "$vendor" in
            "$DGPU_VENDOR") ext_dgpu=1 ;;
            "$IGPU_VENDOR") ext_igpu=1 ;;
            *) connector_ok=0; sensor_ok=0; log sensor_uncertain "connector=$(basename "$(dirname "$st")") vendor=${vendor:-unreadable}" ;;
        esac
    done
    [[ "$any_connector" == 1 ]] || { sensor_ok=0; log sensor_uncertain "no DRM connectors enumerated"; }
}

# policy_decide ACTIVE -> sets desired/policy_ok using individually valid
# inputs. AC-connected alone is sufficient for Hybrid. On battery, an
# absent dGPU device only supports a decision when ACTIVE==Integrated
# (absence is then an expected consequence, and Integrated preserves the
# running mode); absent while Hybrid/unknown is contradictory -> defer.
desired=""; policy_ok=0
policy_decide() {
    read_observed; policy_ok=1; desired=""
    local act=$1
    if [[ "$ac_state" == ac ]]; then
        desired=Hybrid; return 0
    fi
    if [[ "$ac_state" != battery ]]; then policy_ok=0; desired=""; return 0; fi
    # Battery from here.
    if [[ "$dgpu_availability" == available ]]; then
        [[ "$connector_ok" == 1 && "$igpu_present" == 1 ]] || { policy_ok=0; return 0; }
        if [[ "$ext_dgpu" == 1 ]]; then desired=Hybrid; else desired=Integrated; fi
        return 0
    fi
    # dGPU absent.
    if [[ "$act" == Integrated ]]; then desired=Integrated; return 0; fi
    policy_ok=0; desired=""
}

# ---- pending store: single file, atomic, short lock only ----
pending_read() {
    local v=""
    [[ -f "$STATE_DIR/pending-mode" ]] && v=$(cat "$STATE_DIR/pending-mode" 2>/dev/null)
    case "$v" in Hybrid|Integrated) printf '%s' "$v" ;;
        "") printf 'none' ;;
        *) log state_corrupt "pending-mode content='${v}' ignored"; printf 'corrupt' ;;
    esac
}
pending_write() { # $1=Hybrid|Integrated ; lock held only for the write
    mkdir -p "$STATE_DIR" 2>/dev/null || return 1
    exec 8>"$STATE_DIR/.pending.lock"; /usr/bin/flock 8 || { exec 8>&-; return 1; }
    local old; old=$(pending_read)
    printf '%s\n' "$1" > "$STATE_DIR/.pending.tmp.$$" && mv -f "$STATE_DIR/.pending.tmp.$$" "$STATE_DIR/pending-mode"
    /usr/bin/flock -u 8; exec 8>&-
    if [[ "$old" == "$1" ]]; then log pending_kept "pending=$1"
    elif [[ "$old" == none || "$old" == corrupt ]]; then log pending_created "pending=$1"
    else log pending_replaced "pending=$old->$1"; fi
}
pending_clear() { # $1=reason
    mkdir -p "$STATE_DIR" 2>/dev/null || return 0
    exec 8>"$STATE_DIR/.pending.lock"; /usr/bin/flock 8 || { exec 8>&-; return 0; }
    local old; old=$(pending_read)
    rm -f "$STATE_DIR/pending-mode"
    /usr/bin/flock -u 8; exec 8>&-
    [[ "$old" == none ]] || log pending_cancelled "pending=$old reason=$1"
}
