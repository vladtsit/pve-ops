# USB NVMe enclosure (Realtek RTL9210) on PVE host

## Hardware
- NUC10i3FNH @ 192.168.3.20
- Enclosure: Realtek RTL9210 USB-NVMe bridge, VID:PID `0bda:9210`
- 1 TB NVMe inside, ext4, mounted at `/mnt/nvme` via fstab by-id
  (`usb-Realtek_RTL9210_NVME_012345678902-0:0-part1`) - survives sdc/sdd renaming.

## Symptom (recurred ~3x in 2026)
- Bridge glitches under sustained writes
- Kernel: `uas_eh_abort_handler`, then `xhci-hcd: Timeout while waiting for setup device command`
- USB device disconnects + re-enumerates (often as a new sdX letter)
- ext4 hits I/O errors -> journal abort -> remount read-only
- smartd loses device, fires Pushover

## Root cause
RTL9210 firmware has buggy UAS (USB Attached SCSI) command-queue / abort handling.
Well documented across kernels and hosts (RPi, x86, etc.).

## Fix applied 2026-05-15
Force the device to use plain `usb-storage` (BOT) instead of `uas`:

See [`etc/modprobe.d/usb-storage-quirks.conf`](../etc/modprobe.d/usb-storage-quirks.conf):

    options usb-storage quirks=0bda:9210:u

Install steps:

    cp etc/modprobe.d/usb-storage-quirks.conf /etc/modprobe.d/
    update-initramfs -u
    reboot

Verify after reboot:

    lsusb -t                              # Driver=usb-storage (not uas)
    lsmod | grep -E "^uas|^usb_storage"   # uas use-count = 0
    dmesg | grep -i "0bda:9210"
    # expect:
    #   "UAS is ignored for this device, using usb-storage instead"
    #   "Quirks match for vid 0bda pid 9210: 800000"  (US_FL_IGNORE_UAS)

## Trade-off
- ~10-20% slower sequential throughput vs UAS - irrelevant here
  (video conversion is bottlenecked by VA-API encode, not disk).
- Dramatically more stable.

## If drops still happen after the quirk
1. Thermal: RTL9210B runs hot. Add a thermal pad between bridge IC and metal shell.
2. Cable: swap to a known-good short USB 3 cable.
3. Bridge firmware: Realtek has a Windows updater; many enclosures ship old fw.
4. ASPM: try `pcie_aspm=off` on kernel cmdline as a test.
5. Long-term: move NVMe to internal M.2 or a Thunderbolt enclosure (JHL7440-based).
   USB-NVMe bridges are a chronic Linux weak point.

## Related ops
- `sbin/smartd-alert.sh` clamped to Pushover priority 1 (High), never 2 (Emergency),
  so bridge glitches firing FailedOpenDevice no longer wake at night.
- USB autosuspend already off for this device (`power/control = on`); not the cause.
