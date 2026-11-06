#!/usr/bin/env bash
# t2-power-tweaks.sh - battery-life tweaks for Intel T2 MacBooks running Ubuntu
#
# Tweaks (each one asks first unless --yes is given):
#   1. Thunderbolt sleep    - keeps the Thunderbolt driver unloaded so the
#                             controllers power down. This is the big one: it
#                             lets the CPU package reach deep idle (PC8+),
#                             typically cutting idle package power from ~3 W to <1 W.
#   2. Turbo off on battery - disables turbo boost when unplugged, re-enables on AC.
#   3. Video decode driver  - installs Intel's VA-API driver for GPU video decoding.
#   4. ModemManager off     - T2 MacBooks have no cellular modem.
#   5. Fast wake (EXPERIMENTAL) - sleep hook that removes the Thunderbolt chains
#                             before suspend, cutting ~13 s off every wake.
#                             Never installed by --yes; must be confirmed.
#
# Usage: sudo ./t2-power-tweaks.sh [--yes] [--dry-run] [--uninstall] [--status]

set -euo pipefail

TURBO_RULE=/etc/udev/rules.d/60-turbo-on-ac.rules
TB_RULE=/etc/udev/rules.d/61-thunderbolt-sleep.rules
TB_BLACKLIST=/etc/modprobe.d/no-thunderbolt.conf
WAKE_HOOK=/usr/lib/systemd/system-sleep/t2-fast-wake
WAKE_HOOK_SRC="$(cd "$(dirname "$0")" && pwd)/t2-fast-wake"
STATE_DIR=/var/lib/t2-power-tweaks
MARKER="# Added by t2-power-tweaks"
NO_TURBO=/sys/devices/system/cpu/intel_pstate/no_turbo
# Intel Thunderbolt 3 host controller (NHI) PCI device IDs used in T2 Macs
KNOWN_NHI_IDS="0x1575 0x1577 0x15bf 0x15d2 0x15d9 0x15e8 0x15eb"

ASSUME_YES=0
DRY_RUN=0
MODE=install

# ---------- helpers ----------

bold()  { printf '\033[1m%s\033[0m\n' "$*"; }
info()  { printf '  %s\n' "$*"; }
ok()    { printf '  \033[32m✔\033[0m %s\n' "$*"; }
warn()  { printf '  \033[33m!\033[0m %s\n' "$*"; }

usage() {
    sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'
    cat <<'EOF'

Options:
  --yes, -y     apply every tweak without asking
  --dry-run     show what would be done, change nothing (no root needed)
  --status      show current power state and which tweaks are active
  --uninstall   remove everything this script installed
  --help, -h    show this help
EOF
}

ask() {
    [ "$ASSUME_YES" = 1 ] && return 0
    local reply
    read -r -p "  $1 [y/N] " reply </dev/tty || return 1
    [[ "$reply" =~ ^[Yy] ]]
}

# run a command, or just print it in dry-run mode
run() {
    if [ "$DRY_RUN" = 1 ]; then
        printf '  [dry-run] %s\n' "$*"
    else
        "$@"
    fi
}

# write_file PATH CONTENT
write_file() {
    if [ "$DRY_RUN" = 1 ]; then
        printf '  [dry-run] would write %s:\n' "$1"
        printf '%s\n' "$2" | sed 's/^/      /'
    else
        printf '%s\n' "$2" > "$1"
    fi
}

pci_attr() { cat "/sys/bus/pci/devices/$1/$2" 2>/dev/null || true; }

is_t2_mac() {
    local d
    for d in /sys/bus/pci/devices/*; do
        [ "$(cat "$d/vendor")" = 0x106b ] && [ "$(cat "$d/device")" = 0x1801 ] && return 0
    done
    return 1
}

# Print PCI addresses of Intel Thunderbolt host controllers
find_nhi_devices() {
    local d id
    for d in /sys/bus/pci/devices/*; do
        [ "$(cat "$d/vendor")" = 0x8086 ] || continue
        id=$(cat "$d/device")
        if [ "$(basename "$(readlink "$d/driver" 2>/dev/null)" 2>/dev/null)" = thunderbolt ] \
           || [[ " $KNOWN_NHI_IDS " == *" $id "* ]]; then
            basename "$d"
        fi
    done
}

# PCIe root port above a device (e.g. 0000:00:1c.4)
root_port_of() {
    readlink -f "/sys/bus/pci/devices/$1" | grep -oE '0000:00:[0-9a-f]{2}\.[0-7]' | head -1
}

find_turbostat() {
    ls /usr/lib/linux-tools*/turbostat /usr/lib/linux-tools/*/turbostat 2>/dev/null | sort -V | tail -1
}

# ---------- status ----------

show_status() {
    bold "Power status"
    local ac=unknown p
    for p in /sys/class/power_supply/*; do
        [ "$(cat "$p/type" 2>/dev/null)" = Mains ] || continue
        [ "$(cat "$p/online")" = 1 ] && ac="plugged in" || ac="on battery"
    done
    info "Power source:      $ac"
    [ -r "$NO_TURBO" ] && info "Turbo boost:       $([ "$(cat $NO_TURBO)" = 1 ] && echo off || echo on)"
    command -v powerprofilesctl >/dev/null && info "Power profile:     $(powerprofilesctl get 2>/dev/null || echo unknown)"

    if lsmod | grep -q '^thunderbolt'; then
        info "Thunderbolt:       driver loaded (controllers awake)"
    else
        info "Thunderbolt:       driver not loaded"
    fi
    local nhi rp
    for nhi in $(find_nhi_devices); do
        rp=$(root_port_of "$nhi")
        info "  controller $nhi: $(pci_attr "$nhi" power/runtime_status), root port $rp: $(pci_attr "$rp" power/runtime_status)"
    done

    if ls /usr/lib/x86_64-linux-gnu/dri/iHD_drv_video.so >/dev/null 2>&1; then
        info "Video decode:      Intel iHD driver installed"
    else
        info "Video decode:      Intel iHD driver NOT installed"
    fi

    bold "Installed tweaks"
    local f
    for f in "$TB_BLACKLIST" "$TB_RULE" "$TURBO_RULE" "$WAKE_HOOK"; do
        [ -e "$f" ] && ok "$f" || info "- $f (not present)"
    done
    [ -e "$STATE_DIR/modemmanager-disabled" ] && ok "ModemManager disabled by this script"

    local ts
    ts=$(find_turbostat)
    echo
    bold "Measure idle power (unplug, leave idle 30 s):"
    if [ -n "$ts" ]; then
        info "sudo $ts --quiet --Summary --interval 30 --num_iterations 1"
    else
        info "Install turbostat first: sudo apt install linux-tools-generic"
    fi
    info "Look at PkgWatt (lower is better) and Pkg%pc8 / Pk%pc10 (above 0 is good)."
}

# ---------- tweaks ----------

tweak_thunderbolt() {
    bold "1. Thunderbolt sleep (biggest saving)"
    local nhis
    nhis=$(find_nhi_devices)
    if [ -z "$nhis" ]; then
        warn "No Intel Thunderbolt controllers found - skipping."
        return
    fi
    info "Found Thunderbolt controller(s): $(echo $nhis)"
    info "While the Thunderbolt driver is loaded these stay awake and block deep CPU idle."
    info "Trade-off: Thunderbolt-only devices (docks, TB displays, eGPUs) won't work"
    info "until you run 'sudo modprobe thunderbolt'. USB-C charging and plain USB-C devices keep working."

    local connected
    connected=$(ls /sys/bus/thunderbolt/devices/ 2>/dev/null | grep -E '^[0-9]+-[1-9]' || true)
    [ -n "$connected" ] && warn "A Thunderbolt device appears to be connected right now: $(echo $connected)"

    ask "Apply Thunderbolt sleep?" || { info "Skipped."; return; }

    local ids rule="" id
    ids=$(for n in $nhis; do pci_attr "$n" device; done | sort -u)
    for id in $ids; do
        rule+="SUBSYSTEM==\"pci\", ATTR{vendor}==\"0x8086\", ATTR{device}==\"$id\", ACTION==\"add|unbind\", ATTR{power/control}=\"auto\""$'\n'
    done

    write_file "$TB_BLACKLIST" "$MARKER
# Keep the Thunderbolt driver unloaded so the controllers can power down.
# Use Thunderbolt devices on demand with: sudo modprobe thunderbolt
blacklist thunderbolt"
    write_file "$TB_RULE" "$MARKER
# Let the Thunderbolt controllers power down when no driver is bound
${rule%$'\n'}"

    run udevadm control --reload

    if lsinitramfs "/boot/initrd.img-$(uname -r)" 2>/dev/null | grep -q 'thunderbolt\.ko'; then
        info "Thunderbolt driver is in the initramfs - rebuilding it."
        run update-initramfs -u
    fi

    if lsmod | grep -q '^thunderbolt'; then
        if run modprobe -r thunderbolt; then
            ok "Thunderbolt driver unloaded."
        else
            warn "Couldn't unload the driver now (in use?). It will stay off after a reboot."
        fi
    fi
    for n in $nhis; do
        if [ "$DRY_RUN" = 1 ]; then
            printf '  [dry-run] echo auto > /sys/bus/pci/devices/%s/power/control\n' "$n"
        else
            echo auto > "/sys/bus/pci/devices/$n/power/control" || true
        fi
    done
    ok "Done. Check with: $0 --status"
}

tweak_turbo() {
    bold "2. Turbo boost off on battery"
    if [ ! -e "$NO_TURBO" ]; then
        warn "intel_pstate turbo control not found - skipping."
        return
    fi
    info "Caps the CPU at base clock on battery (cooler, quieter, longer battery);"
    info "full speed returns when plugged in."
    ask "Apply turbo-off-on-battery?" || { info "Skipped."; return; }

    write_file "$TURBO_RULE" "$MARKER
# Turbo boost off on battery, on when a charger is connected (runs at boot and on plug/unplug)
SUBSYSTEM==\"power_supply\", ATTR{type}==\"Mains\", ATTR{online}==\"0\", RUN+=\"/bin/sh -c 'echo 1 > $NO_TURBO'\"
SUBSYSTEM==\"power_supply\", ATTR{type}==\"Mains\", ATTR{online}==\"1\", RUN+=\"/bin/sh -c 'echo 0 > $NO_TURBO'\""
    run udevadm control --reload
    run udevadm trigger --subsystem-match=power_supply
    [ "$DRY_RUN" = 0 ] && sleep 1
    ok "Done. Turbo is currently $([ "$(cat $NO_TURBO)" = 1 ] && echo off || echo on)."
}

tweak_vaapi() {
    bold "3. Hardware video decoding"
    if ls /usr/lib/x86_64-linux-gnu/dri/iHD_drv_video.so >/dev/null 2>&1; then
        ok "Intel iHD video driver already installed."
    else
        info "Lets the GPU decode H.264/HEVC/VP9 video instead of the CPU."
        ask "Install intel-media-va-driver-non-free?" || { info "Skipped."; return; }
        if ! run apt-get install -y intel-media-va-driver-non-free vainfo; then
            warn "non-free driver unavailable (multiverse disabled?) - trying the free one."
            run apt-get install -y intel-media-va-driver vainfo || warn "Install failed."
        fi
    fi
    info "Firefox: check about:support -> Codec Support says 'Hardware Decoding: Supported'."
    info "YouTube: the 'enhanced-h264ify' extension with only AV1 (and VP8) blocked avoids"
    info "AV1, which these GPUs can't decode in hardware."
}

tweak_modemmanager() {
    bold "4. ModemManager"
    if ! systemctl is-enabled --quiet ModemManager 2>/dev/null; then
        ok "ModemManager is already disabled or not installed."
        return
    fi
    info "T2 MacBooks have no cellular modem, so this service isn't needed."
    ask "Disable ModemManager?" || { info "Skipped."; return; }
    run systemctl disable --now ModemManager
    run mkdir -p "$STATE_DIR"
    run touch "$STATE_DIR/modemmanager-disabled"
    ok "Disabled."
}

tweak_fast_wake() {
    bold "5. Fast wake from sleep (EXPERIMENTAL)"
    if [ -z "$(find_nhi_devices)" ]; then
        warn "No Intel Thunderbolt controllers found - skipping."
        return
    fi
    if [ ! -r "$WAKE_HOOK_SRC" ]; then
        warn "t2-fast-wake not found next to this script - skipping."
        return
    fi
    info "In deep sleep the Mac cuts power to the Thunderbolt controllers, and on wake"
    info "the kernel waits ~6.5 s for each one - roughly 13-15 s of black screen."
    info "This sleep hook removes the Thunderbolt chains before suspend and rescans"
    info "them a few seconds after wake."
    warn "Experimental: removing PCI devices can hit a kernel deadlock in ACPI hotplug."
    warn "The hook guards against it, but if a wake ever hangs, hold the power button,"
    warn "then remove it with: sudo rm $WAKE_HOOK"
    if [ "$ASSUME_YES" = 1 ]; then
        info "Not installed with --yes. Run without --yes to choose it."
        return
    fi
    ask "Install the experimental fast-wake hook?" || { info "Skipped."; return; }
    run install -m 755 "$WAKE_HOOK_SRC" "$WAKE_HOOK"
    ok "Installed. Takes effect on the next suspend."
}

# ---------- uninstall ----------

uninstall() {
    bold "Removing t2-power-tweaks"
    local f
    for f in "$TB_BLACKLIST" "$TB_RULE" "$TURBO_RULE" "$WAKE_HOOK"; do
        if [ -e "$f" ]; then run rm -f "$f"; [ "$DRY_RUN" = 1 ] || ok "Removed $f"; fi
    done
    run udevadm control --reload
    [ -r "$NO_TURBO" ] && { [ "$DRY_RUN" = 1 ] && echo "  [dry-run] echo 0 > $NO_TURBO" || echo 0 > "$NO_TURBO"; }
    lsmod | grep -q '^thunderbolt' || run modprobe thunderbolt || true

    if [ -e "$STATE_DIR/modemmanager-disabled" ]; then
        run systemctl enable --now ModemManager && ok "Re-enabled ModemManager."
    fi
    run rm -rf "$STATE_DIR"
    info "The Intel video driver package is left installed (remove with apt if wanted)."
    ok "Done. Reboot to make sure everything is back to default."
}

# ---------- main ----------

for arg in "$@"; do
    case "$arg" in
        -y|--yes)    ASSUME_YES=1 ;;
        --dry-run)   DRY_RUN=1 ;;
        --uninstall) MODE=uninstall ;;
        --status)    MODE=status ;;
        -h|--help)   usage; exit 0 ;;
        *) echo "Unknown option: $arg" >&2; usage; exit 1 ;;
    esac
done

if [ "$MODE" = status ]; then
    show_status
    exit 0
fi

if [ "$DRY_RUN" = 0 ] && [ "$(id -u)" != 0 ]; then
    echo "Please run with sudo:  sudo $0 $*" >&2
    exit 1
fi

if ! is_t2_mac; then
    warn "This doesn't look like a T2 Mac (no Apple T2 bridge found)."
    ask "Continue anyway?" || exit 1
fi
grep -qi ubuntu /etc/os-release 2>/dev/null || warn "Not Ubuntu - package installs may fail."

if [ "$MODE" = uninstall ]; then
    uninstall
    exit 0
fi

[ "$DRY_RUN" = 1 ] && bold "DRY RUN - nothing will be changed"
tweak_thunderbolt; echo
tweak_turbo;       echo
tweak_vaapi;       echo
tweak_modemmanager; echo
tweak_fast_wake;    echo
bold "All done."
info "Run '$0 --status' to check, and reboot once to confirm everything sticks."
