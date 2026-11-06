# t2-power-tweaks

Battery-life tweaks for Intel T2 MacBooks (2018–2020) running Ubuntu with a T2 kernel.

The main fix: on T2 Macs the Thunderbolt driver keeps both Thunderbolt controllers awake, which stops the CPU package from going below the PC3 idle state. With the driver unloaded and the controllers allowed to sleep, the package reaches PC7/PC8. On a 2018 13" MacBook Pro (i5-8259U), idle package power dropped from **3.3 W to 0.7 W**.

## What it does

Each tweak asks before changing anything.

| Tweak | What changes | Trade-off |
|---|---|---|
| Thunderbolt sleep | Blacklists the `thunderbolt` module; udev rule lets the controllers power down | Thunderbolt-only devices (docks, TB displays, eGPUs) need `sudo modprobe thunderbolt` first. USB-C charging and plain USB-C devices keep working. |
| Turbo off on battery | udev rule sets `intel_pstate/no_turbo` on plug/unplug and at boot | Heavy tasks are slower on battery |
| Video decode driver | Installs `intel-media-va-driver-non-free` | None |
| ModemManager off | Disables the service (no modem in these Macs) | None |
| Fast wake (**experimental**) | Installs the `t2-fast-wake` sleep hook | See below. Never installed by `--yes`. |
| Keyboard backlight after wake | udev rule restarts UPower when the keyboard backlight device is re-created | The battery icon may blink briefly on wake |

On wake, the T2 disconnects and reconnects the internal keyboard, and Linux creates a new keyboard backlight device. UPower, which GNOME uses for the backlight keys, keeps using the old device, so the keys stop working (`writing '…' to device failed` in the journal). The rule restarts UPower when a new backlight device appears.

### Fast wake (experimental)

In deep sleep (S3) the Mac cuts power to the Thunderbolt controllers. On wake, the kernel waits about 6.5 s for each one to boot, one after another, so you get roughly 13–15 s of black screen. The [`t2-fast-wake`](t2-fast-wake) hook removes the Thunderbolt PCIe chains before suspend and rescans them a few seconds after wake. On a 2018 MacBook Pro 13", that cut the Linux side of resume to about 2 s.

**Known risk:** removing the chains while the kernel is handling an ACPI hotplug event can deadlock (`acpiphp_hotplug_notify` → `free_bridge` → `acpi_lock_hp_context`). The machine then hangs before sleeping, with the screen off and the Touch Bar on. The hook guards against this. It powers the controllers up first, waits for the `kacpi_hotplug` worker to be idle, and skips the removal if the worker stays busy. That narrows the race but can't fully close it, so treat this as experimental. If a wake ever hangs, hold the power button, then run `sudo rm /usr/lib/systemd/system-sleep/t2-fast-wake`.

The hook writes each step to the kernel log: `journalctl -k | grep t2-fast-wake`.

## Usage

```bash
chmod +x t2-power-tweaks.sh
./t2-power-tweaks.sh --dry-run      # preview, changes nothing
sudo ./t2-power-tweaks.sh           # apply, asking for each tweak
./t2-power-tweaks.sh --status       # check what's active
sudo ./t2-power-tweaks.sh --uninstall
```

Reboot once after installing to check everything persists.

## Checking it worked

Unplug the charger, leave the laptop idle, and run the `turbostat` command that `--status` prints. Look at:

- **PkgWatt**: idle package power. Under ~1.5 W is good.
- **Pkg%pc8 / Pk%pc10**: above 0 means the package reaches deep idle. If these are 0 and `Pkg%pc3` is high, something is still blocking it.

On T2 kernels, Ubuntu's `turbostat` wrapper often says "turbostat not found for kernel". Run the binary directly from `/usr/lib/linux-tools-*/turbostat` (`--status` shows the path).

## Also worth doing by hand

- **Firefox**: check `about:support` → Codec Support says H.264/VP9 "Hardware Decoding: Supported". Install the **enhanced-h264ify** extension and block only AV1 (and VP8), because these GPUs can't decode AV1 in hardware.
- **Display scaling**: 200% uses less GPU power than fractional scales like 150% or 175%.
- **Keyboard backlight**: keep it low or off.

## Notes

- Tested on a 2018 MacBook Pro 13" (Touch Bar) on Ubuntu 26.04 with a `t2-resolute` kernel. Other T2 models should work. The script finds Thunderbolt controllers and the charger automatically rather than assuming device names.
- These MacBook panels don't support Panel Self Refresh, so there's nothing to enable there.
- Changes are limited to `/etc/modprobe.d/no-thunderbolt.conf`, `/etc/udev/rules.d/60-turbo-on-ac.rules`, `/etc/udev/rules.d/61-thunderbolt-sleep.rules`, `/etc/udev/rules.d/62-kbd-backlight-upower.rules`, and (if chosen) `/usr/lib/systemd/system-sleep/t2-fast-wake`. `--uninstall` removes them.

## License

MIT. See [LICENSE](LICENSE). Use at your own risk; `--uninstall` reverts everything.
