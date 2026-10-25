# supergfx-gpu-dockswitch

**Docked → Hybrid. On battery → Integrated.**
Automatic GPU mode switching for ASUS hybrid laptops using
[supergfxctl](https://gitlab.com/asus-linux/supergfxctl) (iGPU + NVIDIA dGPU).

| Situation                               | Mode       |
|-----------------------------------------|------------|
| AC power                                | Hybrid     |
| Battery + display wired to the dGPU     | Hybrid     |
| Battery, internal / iGPU displays only  | Integrated |

Changes apply at the **next reboot** — your running session is never
touched. You get a notification when a change is pending.

## Why not just call `supergfxctl -m` from udev?

Because that breaks real systems (all three happened during development):

- A live switch while your compositor holds the dGPU gets the
  compositor killed by the daemon — and can wedge shutdown.
- A switch call at boot blocks minutes on the daemon's logout wait
  inside the udev worker; the dGPU display stays dark.
- One uncapped daemon query can hang a boot unit indefinitely.

## How it works

- **Runtime (udev):** only *records* the wanted mode (45 s debounce).
  Never runs a mode-changing command.
- **Before supergfxd (boot):** writes the intent into
  `/etc/supergfxd.conf`, the field the daemon itself reads at startup.
  Uncertain sensors → config untouched.
- **After supergfxd (boot):** verifies the daemon booted into the
  intended mode; re-negotiates a stuck USB-C display (UCSI rebind)
  after an Integrated → Hybrid switch.

Every daemon query is time-capped; every decision is in the journal.

## Install

```bash
git clone https://github.com/yavuzhansarmaz/supergfx-gpu-dockswitch.git
cd supergfx-gpu-dockswitch
./tests/run-all.sh     # optional, no root needed
sudo bash install.sh   # backs up everything it touches first
```

Verify:

```bash
/usr/local/bin/supergfx-gpu-dockswitch.sh --check
journalctl -b -t supergfx-gpu-dockswitch-pre -t supergfx-gpu-dockswitch-boot
```

## Requirements

- Working `supergfxctl`/`supergfxd` (developed against 5.2.7) — check
  `supergfxctl -g` first.
- systemd + udev, bash, python3. Optional: `notify-send`.
- Tested daily on ROG Zephyrus G14 GA401IV (AMD iGPU + RTX 2060,
  USB-C DP on dGPU, HDMI on iGPU). GPU vendor ids are configurable
  (Intel iGPU untested — reports welcome).

## Configure / opt out / uninstall

- Config: `/etc/supergfx-gpu-dockswitch.conf` (see
  [`config/`](config/supergfx-gpu-dockswitch.conf.example)) — all
  settings optional.
- Opt out: `sudo mkdir -p /etc/supergfx-gpu-dockswitch && sudo touch /etc/supergfx-gpu-dockswitch/off`
- Uninstall: `sudo bash uninstall.sh /root/supergfx-gpu-dockswitch.bak.<timestamp>`
  (restores your original daemon config; current GPU mode unchanged).

## Limitations

- Modes change at reboot by design. Need one now? Switch manually;
  dockswitch re-evaluates at the next event/boot.
- Only Hybrid/Integrated are managed; Vfio/eGPU configs are left alone.
- DisplayLink docks don't surface as dGPU connectors, so they won't
  force Hybrid.

## Tests

`./tests/run-all.sh` — 29 mocked scenarios (fake sysfs/daemon), no
root, no GPU. The runtime suite asserts on every path that the
mode-changing `supergfxctl -m` is never invoked.

## License

[MIT](LICENSE). Unofficial; not affiliated with ASUS or asus-linux.
Read `install.sh` before running it, and keep a TTY/SSH fallback for
the first reboot.
