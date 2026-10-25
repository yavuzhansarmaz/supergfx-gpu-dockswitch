#!/usr/bin/env bash
# Install supergfx-gpu-dockswitch. Run once with sudo:
#   sudo bash install.sh
#
# What it changes:
#   /usr/local/bin/supergfx-gpu-dockswitch.sh            runtime recorder (never switches)
#   /usr/local/bin/supergfx-gpu-dockswitch-pre.sh        pre-supergfxd intent writer
#   /usr/local/bin/supergfx-gpu-dockswitch-boot.sh       post-daemon verification + UCSI fix
#   /usr/local/lib/supergfx-gpu-dockswitch/common.sh     shared library
#   /etc/systemd/system/supergfx-gpu-dockswitch-pre.service   (Before=supergfxd.service)
#   /etc/systemd/system/supergfx-gpu-dockswitch-boot.service  (After=supergfxd.service)
#   /etc/udev/rules.d/99-supergfx-gpu-dockswitch.rules   detached runtime events
#   /etc/supergfx-gpu-dockswitch.conf                    created from the example if missing
#   ~/.local/bin/supergfx-gpu-dockswitch-login-check.sh  login notification (+ autostart)
#   /etc/supergfxd.conf                        logout_timeout_s set to 30
#                                              (mode and all other fields kept)
#
# Every touched file is backed up first (path printed below). To undo,
# run uninstall.sh with sudo -- it restores the newest backup.
set -euo pipefail
[[ "$(id -u)" == 0 ]] || { echo "Run with sudo: sudo bash install.sh"; exit 1; }
command -v supergfxctl >/dev/null 2>&1 || {
    echo "supergfxctl not found. Install asusctl/supergfxctl first (see README)."
    exit 1
}
SRC="$(cd "$(dirname "$0")" && pwd)"
TARGET_USER=${SUDO_USER:-}
[[ -n "$TARGET_USER" ]] || { echo "SUDO_USER is empty; run via sudo from your user account."; exit 1; }
USER_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)
[[ -n "$USER_HOME" && -d "$USER_HOME" ]] || { echo "Cannot resolve home directory for $TARGET_USER"; exit 1; }

# Syntax-check everything before touching the system.
for s in "$SRC"/bin/*.sh "$SRC"/lib/common.sh "$SRC"/tests/*.sh; do
    bash -n "$s"
done

BACKUP=/root/supergfx-gpu-dockswitch.bak.$(date +%Y%m%d-%H%M%S)
mkdir -p "$BACKUP"
for f in /usr/local/bin/supergfx-gpu-dockswitch.sh /usr/local/bin/supergfx-gpu-dockswitch-pre.sh \
         /usr/local/bin/supergfx-gpu-dockswitch-boot.sh /usr/local/lib/supergfx-gpu-dockswitch/common.sh \
         /etc/systemd/system/supergfx-gpu-dockswitch-pre.service \
         /etc/systemd/system/supergfx-gpu-dockswitch-boot.service \
         /etc/udev/rules.d/99-supergfx-gpu-dockswitch.rules \
         /etc/supergfx-gpu-dockswitch.conf /etc/supergfxd.conf \
         "$USER_HOME/.local/bin/supergfx-gpu-dockswitch-login-check.sh" \
         "$USER_HOME/.config/autostart/supergfx-gpu-dockswitch-check.desktop"; do
    [[ -e "$f" ]] && cp -a "$f" "$BACKUP/"
done
echo "Backup: $BACKUP"

install -d -m 0755 /usr/local/lib/supergfx-gpu-dockswitch /var/lib/supergfx-gpu-dockswitch
install -m 0644 "$SRC/lib/common.sh" /usr/local/lib/supergfx-gpu-dockswitch/common.sh
install -m 0755 "$SRC/bin/supergfx-gpu-dockswitch.sh" /usr/local/bin/supergfx-gpu-dockswitch.sh
install -m 0755 "$SRC/bin/supergfx-gpu-dockswitch-pre.sh" /usr/local/bin/supergfx-gpu-dockswitch-pre.sh
install -m 0755 "$SRC/bin/supergfx-gpu-dockswitch-boot.sh" /usr/local/bin/supergfx-gpu-dockswitch-boot.sh
install -m 0644 "$SRC/systemd/supergfx-gpu-dockswitch-pre.service" /etc/systemd/system/supergfx-gpu-dockswitch-pre.service
install -m 0644 "$SRC/systemd/supergfx-gpu-dockswitch-boot.service" /etc/systemd/system/supergfx-gpu-dockswitch-boot.service
install -m 0644 "$SRC/udev/99-supergfx-gpu-dockswitch.rules" /etc/udev/rules.d/99-supergfx-gpu-dockswitch.rules
if [[ ! -e /etc/supergfx-gpu-dockswitch.conf ]]; then
    install -m 0644 "$SRC/config/supergfx-gpu-dockswitch.conf.example" /etc/supergfx-gpu-dockswitch.conf
    echo "Created /etc/supergfx-gpu-dockswitch.conf from the example (all defaults)."
fi

install -d -m 0755 -o "$TARGET_USER" -g "$TARGET_USER" \
    "$USER_HOME/.local/bin" "$USER_HOME/.config/autostart"
install -m 0755 -o "$TARGET_USER" -g "$TARGET_USER" \
    "$SRC/bin/supergfx-gpu-dockswitch-login-check.sh" "$USER_HOME/.local/bin/supergfx-gpu-dockswitch-login-check.sh"
sed "s|__HOME__|$USER_HOME|g" "$SRC/autostart/supergfx-gpu-dockswitch-check.desktop" \
    > "$USER_HOME/.config/autostart/supergfx-gpu-dockswitch-check.desktop"
chown "$TARGET_USER:$TARGET_USER" "$USER_HOME/.config/autostart/supergfx-gpu-dockswitch-check.desktop"

/usr/bin/python3 - "$BACKUP" <<'EOF'
import json, sys
p = '/etc/supergfxd.conf'
with open(p) as f:
    d = json.load(f)
old = d.get('logout_timeout_s')
d['logout_timeout_s'] = 30
with open(p, 'w') as f:
    json.dump(d, f, indent=2)
    f.write('\n')
print(f"logout_timeout_s: {old} -> 30 (original in {sys.argv[1]}/supergfxd.conf)")
EOF

"$SRC/tests/run-all.sh"
/usr/bin/udevadm control --reload-rules
/usr/bin/systemctl daemon-reload
/usr/bin/systemctl enable supergfx-gpu-dockswitch-pre.service supergfx-gpu-dockswitch-boot.service
/usr/bin/systemctl start supergfx-gpu-dockswitch-boot.service || true
/usr/bin/systemctl status supergfx-gpu-dockswitch-boot.service --no-pager || true
echo "Current: $(/usr/local/bin/supergfx-gpu-dockswitch.sh --check)"
echo "Done. Mode changes take effect at the next reboot."
echo "Opt out any time: sudo mkdir -p /etc/supergfx-gpu-dockswitch && sudo touch /etc/supergfx-gpu-dockswitch/off"
