#!/usr/bin/env bash
# Login-time check: notify if the live GPU mode differs from what the
# dock/power policy wants. Runtime never switches a live session; the
# wanted mode is applied at the next reboot.
# Installed alongside /usr/local/bin/supergfx-gpu-dockswitch.sh (udev-driven recorder).
AUTO=${SGD_GFX_AUTO:-/usr/local/bin/supergfx-gpu-dockswitch.sh}
out=$("$AUTO" --check 2>/dev/null) || exit 0
want=$(echo "$out" | grep -oE 'want=[A-Za-z]+' | cut -d= -f2)
cur=$(echo "$out" | grep -oE 'cur=[A-Za-z]+' | cut -d= -f2)
[[ -n "$want" && -n "$cur" && "$want" != "$cur" && "$cur" != unknown ]] || exit 0
/usr/bin/notify-send -a "supergfx-gpu-dockswitch" \
    "GPU mode: $want pending (current $cur)" \
    "Will apply at next reboot. Current session left untouched." 2>/dev/null || true
