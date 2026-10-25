#!/usr/bin/env bash
# Pre-supergfxd mode preparation (source-verified for supergfxctl 5.2.7):
# supergfxd loads /etc/supergfxd.conf once at startup
# (src/daemon.rs:53 GfxConfig::load), GfxConfig.mode is documented
# "The current mode set, also applies on boot" (src/config.rs:46-47), and
# CtrlGraphics::reload performs boot tasks for exactly that mode
# (src/controller.rs:41-65). Therefore setting the JSON mode field before
# the daemon starts is the daemon's own supported startup-selection
# mechanism -- the same field SetMode persists after a successful switch
# (src/controller.rs:238-240). This script is the ONLY component that
# writes persistent mode intent; it never calls supergfxctl at all.
# Fallback: uncertain sensors -> config left untouched (last daemon mode
# stands), pending preserved, nothing claimed.
#
# Test hooks (env): SGD_SUPERGFXD_CONF SGD_PYTHON SGD_PRE_STABLE_ATTEMPTS
#   SGD_PRE_STABLE_DELAY_S, plus the SGD_* hooks in lib/common.sh
set -u
export SGD_LOG_TAG=${SGD_LOG_TAG:-supergfx-gpu-dockswitch-pre}

# Load the shared library: installed location, or the repo checkout.
SGD_LIB=${SGD_LIB:-/usr/local/lib/supergfx-gpu-dockswitch/common.sh}
if [[ ! -r "$SGD_LIB" ]]; then
    SGD_LIB="$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
fi
# shellcheck disable=SC1090
[[ -r "$SGD_LIB" ]] && . "$SGD_LIB" || { echo "supergfx-gpu-dockswitch-pre: cannot load $SGD_LIB" >&2; exit 1; }

DAEMON_CONF=${SGD_SUPERGFXD_CONF:-/etc/supergfxd.conf}
PYTHON=${SGD_PYTHON:-/usr/bin/python3}
PRE_STABLE_ATTEMPTS=${SGD_PRE_STABLE_ATTEMPTS:-10}
PRE_STABLE_DELAY_S=${SGD_PRE_STABLE_DELAY_S:-1}

daemon_conf_mode() {
    "$PYTHON" - "$DAEMON_CONF" <<'PYEOF' 2>/dev/null
import json,sys
try:
    with open(sys.argv[1]) as f: c=json.load(f)
    m=c.get("mode")
    print(m if m in ("Hybrid","Integrated") else "invalid")
except Exception:
    print("invalid")
PYEOF
}
daemon_conf_set() { # $1=mode; atomic, preserves all other fields
    "$PYTHON" - "$DAEMON_CONF" "$1" <<'PYEOF'
import json,os,sys
path,target=sys.argv[1],sys.argv[2]
with open(path) as f: c=json.load(f)
if not isinstance(c,dict) or c.get("mode") not in ("Hybrid","Integrated"):
    sys.exit(2)
c["mode"]=target
d=os.path.dirname(path); tmp=os.path.join(d,".supergfxd.conf.tmp.%d"%os.getpid())
with open(tmp,"w") as f:
    json.dump(c,f,indent=2); f.write("\n"); f.flush(); os.fsync(f.fileno())
os.chmod(tmp,0o644); os.replace(tmp,path)
PYEOF
}

[[ -f "$OPT_OUT" ]] && { log disabled "opt_out=$OPT_OUT"; exit 0; }
mkdir -p "$STATE_DIR" 2>/dev/null || exit 0
# Bounded stabilization: two identical fresh readings.
prev=""; stable=0
for (( i=0; i<PRE_STABLE_ATTEMPTS; i++ )); do
    policy_decide "$(daemon_conf_mode)"
    snap="$ac_state/$ext_dgpu/$dgpu_availability/$policy_ok/$desired"
    if [[ "$snap" == "$prev" && "$policy_ok" == 1 ]]; then stable=1; break; fi
    prev=$snap; sleep "$PRE_STABLE_DELAY_S"
done
if [[ "$stable" != 1 ]]; then
    log decision_deferred "reason=sensors_unstable_or_uncertain config_untouched=$(daemon_conf_mode) pending_preserved=$(pending_read)"
    rm -f "$STATE_DIR/intended-mode"
    exit 0
fi
cur_conf=$(daemon_conf_mode)
log observed "ac=$ac_state ext_dgpu=$ext_dgpu dgpu_availability=$dgpu_availability desired=$desired daemon_conf_mode=$cur_conf pending=$(pending_read)"
[[ "$cur_conf" != invalid ]] || { log decision_deferred "reason=daemon_config_invalid pending_preserved=$(pending_read)"; exit 0; }
printf '%s\n' "$desired" > "$STATE_DIR/.intended.tmp.$$" && mv -f "$STATE_DIR/.intended.tmp.$$" "$STATE_DIR/intended-mode"
if [[ "$desired" == "$cur_conf" ]]; then
    log intent_already_set "mode=$desired"; exit 0
fi
if daemon_conf_set "$desired"; then
    [[ "$(daemon_conf_mode)" == "$desired" ]] || { log intent_write_unverified "mode=$desired"; exit 1; }
    log intent_prepared "daemon_conf_mode=$cur_conf->$desired applies_at_daemon_start"
else
    log intent_write_failed "mode=$desired pending_preserved=$(pending_read)"; exit 1
fi
