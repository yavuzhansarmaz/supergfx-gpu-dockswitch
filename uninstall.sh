#!/usr/bin/env bash
# Remove supergfx-gpu-dockswitch. Run with sudo:
#   sudo bash uninstall.sh [backup-dir]
#
# Removes the scripts, units, udev rule, login check, and autostart
# entry, then disables the units. If a backup directory (printed by
# install.sh, e.g. /root/supergfx-gpu-dockswitch.bak.20260101-120000) is given,
# /etc/supergfxd.conf is restored from it. Otherwise supergfxd.conf is
# left as-is (only logout_timeout_s was changed by the installer).
# Your current GPU mode is not changed either way.
set -euo pipefail
[[ "$(id -u)" == 0 ]] || { echo "Run with sudo: sudo bash uninstall.sh"; exit 1; }
TARGET_USER=${SUDO_USER:-}
USER_HOME=""
[[ -n "$TARGET_USER" ]] && USER_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)

/usr/bin/systemctl disable --now supergfx-gpu-dockswitch-pre.service supergfx-gpu-dockswitch-boot.service 2>/dev/null || true
rm -f /usr/local/bin/supergfx-gpu-dockswitch.sh /usr/local/bin/supergfx-gpu-dockswitch-pre.sh \
      /usr/local/bin/supergfx-gpu-dockswitch-boot.sh \
      /usr/local/lib/supergfx-gpu-dockswitch/common.sh \
      /etc/systemd/system/supergfx-gpu-dockswitch-pre.service \
      /etc/systemd/system/supergfx-gpu-dockswitch-boot.service \
      /etc/udev/rules.d/99-supergfx-gpu-dockswitch.rules
rmdir /usr/local/lib/supergfx-gpu-dockswitch 2>/dev/null || true
if [[ -n "$USER_HOME" ]]; then
    rm -f "$USER_HOME/.local/bin/supergfx-gpu-dockswitch-login-check.sh" \
          "$USER_HOME/.config/autostart/supergfx-gpu-dockswitch-check.desktop"
fi
if [[ -n "${1:-}" && -e "$1/supergfxd.conf" ]]; then
    cp -a "$1/supergfxd.conf" /etc/supergfxd.conf
    echo "Restored /etc/supergfxd.conf from $1"
else
    echo "Left /etc/supergfxd.conf unchanged (pass the install backup dir to restore it)."
fi
/usr/bin/udevadm control --reload-rules
/usr/bin/systemctl daemon-reload
echo "Removed. State in /var/lib/supergfx-gpu-dockswitch and /etc/supergfx-gpu-dockswitch.conf were kept; delete them manually if wanted."
echo "The current supergfxctl mode was not changed."
