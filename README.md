# Sixpounder Atomic Images &nbsp; [![build badge](https://github.com/Six6pounder/fedora-silverblue-nvidia/actions/workflows/build.yml/badge.svg)](https://github.com/Six6pounder/fedora-silverblue-nvidia/actions/workflows/build.yml)

These are my personal Fedora Atomic OS images, built using [BlueBuild](https://blue-build.org/). COSMIC, KDE and GNOME each have an NVIDIA variant (open kernel modules) and an Intel Mac/T2 variant, sharing the same applications and tooling:

| Variant | Recipe | Base image | Published as |
| --- | --- | --- | --- |
| COSMIC | [`recipes/recipe.yml`](recipes/recipe.yml) | `fedora-cosmic-nvidia-open` | `ghcr.io/six6pounder/sixpounder-cosmic` |
| KDE Plasma (Kinoite) | [`recipes/recipe-kde.yml`](recipes/recipe-kde.yml) | `fedora-kinoite-nvidia-open` | `ghcr.io/six6pounder/sixpounder-kde` |
| GNOME (Silverblue) | [`recipes/recipe-gnome.yml`](recipes/recipe-gnome.yml) | `fedora-silverblue-nvidia-open` | `ghcr.io/six6pounder/sixpounder-gnome` |
| COSMIC T2 | [`recipes/recipe-cosmic-t2.yml`](recipes/recipe-cosmic-t2.yml) | `fedora-cosmic:44` | `ghcr.io/six6pounder/sixpounder-cosmic-t2` |
| KDE T2 | [`recipes/recipe-kde-t2.yml`](recipes/recipe-kde-t2.yml) | `fedora-kinoite:44` | `ghcr.io/six6pounder/sixpounder-kde-t2` |
| GNOME T2 | [`recipes/recipe-gnome-t2.yml`](recipes/recipe-gnome-t2.yml) | `fedora-silverblue:44` | `ghcr.io/six6pounder/sixpounder-gnome-t2` |

Applications and tooling live in [`recipes/common.yml`](recipes/common.yml), used by all six images. GNOME extensions and Extension Manager live in `recipes/gnome-common.yml`, shared by both GNOME variants. T2 images include `t2-pre.yml` **before** common modules to replace the kernel before compiling VirtualBox/xone, then `t2-post.yml` to configure services and regenerate/verify the initramfs. Hardware configuration is isolated in `files/t2`; NVIDIA images keep their existing kernel and hardware settings.

## Installation

> [!WARNING]  
> [This is an experimental feature](https://www.fedoraproject.org/wiki/Changes/OstreeNativeContainerStable), try at your own discretion.

For Intel Macs with a T2 chip, use the [T2 instructions below](#intel-macs-with-t2) instead. For the NVIDIA variants, to rebase an existing atomic Fedora installation to the latest build, substitute `sixpounder-cosmic` below with `sixpounder-kde` or `sixpounder-gnome` if you want one of the other variants:

- First rebase to the unsigned image, to get the proper signing keys and policies installed:
  ```
  rpm-ostree rebase ostree-unverified-registry:ghcr.io/six6pounder/sixpounder-cosmic:latest
  ```
- Reboot to complete the rebase:
  ```
  systemctl reboot
  ```
- Then rebase to the signed image, like so:
  ```
  rpm-ostree rebase ostree-image-signed:docker://ghcr.io/six6pounder/sixpounder-cosmic:latest
  ```
- Reboot again to complete the installation
  ```
  systemctl reboot
  ```

The `latest` tag will automatically point to the latest build. That build will still always use the Fedora version specified in the recipe, so you won't get accidentally updated to the next major version.

> [!NOTE]
> `rpm-ostree rebase` only replaces `/usr`; `/etc` and `/var` (including `/home`) persist across the rebase. If you rebase between variants under the same user account, a handful of files are genuinely shared between desktops and can behave oddly when switched: `~/.config/mimeapps.list`, GTK theme settings, `~/.config/autostart/`, and xdg-desktop-portal permissions. The secret store is the one to be careful with — COSMIC and GNOME both use gnome-keyring (`~/.local/share/keyrings/`), so they share one store, while KDE Plasma defaults to KWallet (`~/.local/share/kwalletd/`); the two don't collide, but secrets saved under KDE won't be visible from the other two. Back up `~/.local/share/keyrings/` before experimenting if it holds anything you care about. Using a separate Linux user account per desktop avoids all of this entirely.

## Intel Macs with T2

The T2 variants target **x86_64 Intel Macs with an Apple T2 chip**, initially the 2019 15-inch MacBook Pro (`MacBookPro15,1` / `MacBookPro15,3`). They use Fedora 44 and the signed packages from [sharpenedblade/t2linux COPR](https://copr.fedorainfracloud.org/coprs/sharpenedblade/t2linux/), following the [Fedora T2 guide](https://wiki.t2linux.org/distributions/fedora/installation/). They include the patched kernel, T2 keyboard/trackpad drivers, audio configuration, kernel Touch Bar support and `t2fanrd` fan control. Intel/AMD graphics use the base image's Mesa drivers.

This is an Atomic **rebase**, not a live ISO installer. Start from a working Fedora Atomic installation. Fedora installed from the T2 project's conventional live ISO is not automatically an Atomic installation. Keep the previous deployment available for rollback. For a fresh install, follow the [T2 pre-install guide](https://wiki.t2linux.org/guides/preinstall/) for Apple's boot settings and prepare Atomic with external keyboard/mouse and Ethernet/tethering as needed; this repository does not yet provide a T2-enabled installer.

### Rebase

Wait for a successful CI build publishing the selected image before running these commands. Replace `sixpounder-cosmic-t2` with `sixpounder-kde-t2` or `sixpounder-gnome-t2` as desired:

```bash
sudo rpm-ostree rebase ostree-unverified-registry:ghcr.io/six6pounder/sixpounder-cosmic-t2:latest
# Apply to the pending deployment BEFORE its first boot.
sudo rpm-ostree kargs \
  --append-if-missing=intel_iommu=on \
  --append-if-missing=iommu=pt \
  --append-if-missing=pm_async=off \
  --append-if-missing=mem_sleep_default=deep \
  --append-if-missing=firmware_class.path=/var/lib/firmware
systemctl reboot
```

Then switch to the signed image and reboot again:

```bash
sudo rpm-ostree rebase ostree-image-signed:docker://ghcr.io/six6pounder/sixpounder-cosmic-t2:latest
systemctl reboot
```

The T2 boot parameters match [Omarchy's T2 setup](https://github.com/basecamp/omarchy/blob/master/install/hardware/apple/fix-t2.sh). The image also ships bootc kernel-argument configuration, but **`rpm-ostree rebase` does not apply that configuration automatically**: the explicit `kargs` command above is required. Check existing arguments with `rpm-ostree kargs` and remove conflicting values from previous customizations before applying these defaults.

### Automatic Wi-Fi and Bluetooth firmware

Around 90 seconds after boot, a timer detects T2 hardware and the Broadcom chip. It reuses complete firmware already in `/var/lib/firmware/brcm`, or copies existing Apple firmware from `/usr/lib/firmware/brcm` into that persistent directory. If firmware is missing, it downloads an Apple macOS Recovery image using the pinned upstream downloader, verifies Apple's signed chunklist and image, mounts the converted image **read-only**, and converts the firmware using the pinned T2 Linux renamer. No macOS installation is required and no Apple firmware is redistributed in these images.

For the first download, connect **Ethernet or USB tethering** if internal Wi-Fi is unavailable. Allow several GB of free disk space and time for the recovery image download/conversion. Recovery runs in the background and does not delay login. Failures are logged and retried 15 minutes after the previous attempt finishes; incomplete downloads leave no completion marker. Successfully imported firmware lives under `/var`, so upgrades/rebases do not require downloading it again. Reboot if devices remain unavailable after import; a working Wi-Fi interface is never unloaded automatically.

```bash
sixpounder-t2-firmware status
sudo sixpounder-t2-firmware retry
journalctl -u sixpounder-t2-firmware.service -b
```

`retry` rechecks missing firmware; it does not redownload a complete installation. To import the **renamed** `firmware.tar` produced by the [T2 firmware guide](https://wiki.t2linux.org/guides/wifi-bluetooth/) instead:

```bash
sudo sixpounder-t2-firmware import /path/to/firmware.tar
```

The upstream mutable-system `get-apple-firmware.service` is masked. Firmware retrieval never installs packages at runtime or writes to `/usr`. Touch ID is not included. The Touch Bar uses the kernel's standard function/media keys; `tiny-dfr` customization is not enabled.

### Fans, validation and rollback

`t2fanrd` controls both fans with Omarchy's linear 55–75 °C curve. CoolerControl stays installed, but its daemon is masked and its system login autostart is hidden on T2 images so it does not compete with `t2fanrd`. Do not enable both fan managers at once.

Build-time verification requires exactly one T2 kernel with matching headers and module packages, working T2/VirtualBox/xone module metadata, and an initramfs containing the T2 and keyboard drivers. The recovery unit tests cover firmware reuse, failed/interrupted downloads, successful retries, incomplete imports, and archive handling. Run them locally with:

```bash
python3 -m unittest discover -s tests -v
./build-local.sh -r recipes/recipe-cosmic-t2.yml
# Repeat with recipe-kde-t2.yml and recipe-gnome-t2.yml.
```

**Hardware validation is still pending.** A successful image build does not prove the Mac's peripherals work. On `MacBookPro15,1`/`15,3`, check boot, keyboard/trackpad, Touch Bar, camera, speaker/headphone/microphone audio, both fans, Wi-Fi/Bluetooth, Intel/AMD graphics, and suspend/resume. Suspend and AMD graphics have [model-dependent upstream limitations](https://wiki.t2linux.org/state/); apply GPU-specific workarounds only if the actual device needs them.

Useful diagnostics:

```bash
uname -r
rpm-ostree kargs
systemctl status t2fanrd sixpounder-t2-firmware.timer
journalctl -k -b --grep='t2bce|brcmfmac|hci_bcm|amdgpu'
```

To roll back, select the previous deployment in the boot menu, or run `sudo rpm-ostree rollback` and reboot. Persistent firmware remains in `/var`. Returning to an NVIDIA image may also require restoring any locally changed `/etc` fan/autostart settings, because Atomic preserves administrator changes across rebases.

## Post-install notes

These are one-time manual steps needed after a **fresh install** (they persist across normal `rpm-ostree upgrade`/rebases, so you only redo them if you reinstall or set up a new machine).

### VirtualBox

1. Add your user to the `vboxusers` group (needed for USB/networking), then log out and back in:
   ```bash
   sudo usermod -aG vboxusers $USER
   ```

2. **SELinux fix for starting VMs.** VirtualBox's hardened build needs to make code memory writable to hook `dlopen`, which SELinux (Enforcing) blocks. Without this, starting a VM fails with:
   > VirtualBox - Error In supR3HardenedPosixInit
   > Failed to hook the dlopen interface (rc=-3776) ... VERR_SUPLIB_TEXT_NOT_WRITEABLE

   Fix it once by generating a minimal local SELinux policy (the image ships `audit2allow`/`semodule` via `policycoreutils-python-utils`):
   ```bash
   sudo setenforce 0                                              # permissive (temporary)
   # start a VM once so the denial gets logged, then:
   sudo ausearch -m AVC -ts recent | audit2allow -M vbox_local
   sudo semodule -i vbox_local.pp
   sudo setenforce 1                                              # back to enforcing
   ```
   The generated module just grants `allow kernel_t self:process execmem;`. This installs into `/etc/selinux` + `/var/lib/selinux`, so it survives rebases.

### Xbox controllers (xone)

The [xone](https://github.com/dlundqvist/xone) kernel modules (the maintained
`dlundqvist` fork, which builds against current kernels) are compiled against the
image's kernel and baked in, so **wired** Xbox One/Series controllers work out of
the box after a reboot — nothing to do.

The **wireless dongle** additionally needs firmware extracted from a Microsoft driver, which is non-redistributable and so can't ship in the image. Fetch it once (the image bundles `bsdtar` for this):
```bash
sudo xone-get-firmware.sh
```
The firmware is written to `/var/lib/firmware` (writable, unlike the read-only `/lib/firmware`), which the kernel searches via the `firmware_class.path` karg baked into the image. It lives under `/var`, so it persists across rebases — you only redo it on a fresh install.

### CoolerControl

Fan control works automatically at boot: the `coolercontrold` daemon is enabled as a system service, so your fan profiles are applied without anyone logging in.

The **GUI** also autostarts at login (via `/etc/xdg/autostart`). To have it come up **minimized to the system tray** instead of opening a window, enable it once per user:

1. Open CoolerControl → **Settings**, and turn on **Start in Tray** (and optionally **Close to Tray**).

On COSMIC, make sure a tray/status-area applet is present on the panel, otherwise the tray icon has nowhere to show. KDE Plasma has a system tray in the panel by default, so no extra setup is needed there. GNOME has no notification area of its own — the GNOME image ships the AppIndicator extension for it; if tray icons don't appear, enable **AppIndicator and KStatusNotifierItem Support** in the Extensions app (also installed there).

### OpenRGB

RGB lighting control for everything `coolercontrold`/`liquidctl` don't cover — motherboard and DRAM headers, GPU, keyboards, mice and so on. Installed from the Fedora repo rather than the Flatpak, because the RPM brings the pieces the sandboxed build can't: `openrgb` hard-Requires `openrgb-udev-rules`, so **the full upstream rule set from [openrgb.org/udev.html](https://openrgb.org/udev.html) is already in the image** — nothing to download or copy into `/etc/udev/rules.d` by hand. The rules use `TAG+="uaccess"` (no `plugdev` group, no `usermod`), so the logged-in user gets access to `/dev/i2c-*`, the Super I/O `port` device and every supported USB device automatically. `i2c-dev` is loaded at boot by the base image's `fwupd-i2c.conf`, so that's covered too.

Just launch **OpenRGB** from the app menu — no `sudo`, no post-install step.

The package also ships an `openrgb.service` SDK server (`openrgb --server`), left **disabled** on purpose: it runs as root for the whole boot, and you only need it if something else talks to OpenRGB's SDK, or you want a saved profile re-applied at startup. Enable it per machine if you do:

```bash
sudo systemctl enable --now openrgb
```

**If motherboard or DRAM devices don't show up** (USB peripherals are unaffected), the SMBus adapter probably never registered. Check with:

```bash
cat /sys/bus/i2c/devices/*/name | grep -i smbus
```

No `SMBus PIIX4` line means the board's ACPI firmware claims the SMBus I/O range and `i2c-piix4` backed off — the usual situation on AMD boards, and the case on this machine as shipped. The fix is a kernel argument, deliberately **not** baked into the image because it lets the driver poke a region ACPI has reserved (rare but real risk of fighting the firmware/EC):

```bash
rpm-ostree kargs --append=acpi_enforce_resources=lax
systemctl reboot
```

It persists across upgrades and rebases, and `rpm-ostree kargs --delete=acpi_enforce_resources=lax` reverts it.

### Claude Desktop

Anthropic ships the Linux desktop app only as a `.deb` from their own apt repo — there is no RPM or Flatpak, and [their docs](https://code.claude.com/docs/en/desktop-linux) list Fedora as unsupported — so the image unpacks the `.deb` at build time (`install-claude-desktop.sh`, which verifies the repo signature and checksums the way apt does). Launch **Claude** from the app menu and sign in; nothing else to do.

Because the app can't self-update on Linux, **new versions arrive with the image**: each rebuild picks up whatever is current in Anthropic's stable repo, so `rpm-ostree upgrade` is what updates it.

Two caveats from the Linux beta: Computer Use and dictation aren't available, and the Quick Entry global hotkey needs the desktop's GlobalShortcuts portal under Wayland.

### ChatGPT (with Codex)

OpenAI's [Linux desktop app](https://openai.com/codex/) — ChatGPT, ChatGPT Work and the Codex coding agent in one Electron app — is baked in from OpenAI's own RPM repo (`chatgpt.repo`), so it needs no unpacking script: Fedora is a supported distro upstream. Launch **ChatGPT** from the app menu and sign in.

The repo's signing key isn't published at any URL — upstream embeds it in the package's `%post` scriptlet — so the image ships it at `/etc/pki/rpm-gpg/RPM-GPG-KEY-chatgpt` ("Codex Linux Repository", `3BFA0E4AE8B8CC16A2D9BA684A3B4A566C4660E4`) and the repo verifies both metadata and package against it.

Like Claude Desktop, it doesn't self-update here: each rebuild picks up the current version, so `rpm-ostree upgrade` is what updates it. It is by far the largest single thing in the image (~1.3 GB installed) — drop `chatgpt` from the package list in `common.yml` if you'd rather layer it per-machine with `rpm-ostree install chatgpt`; the repo stays configured either way.

Computer Use is not available in the Linux preview.

## ISO

If build on Fedora Atomic, you can generate an offline ISO with the instructions available [here](https://blue-build.org/learn/universal-blue/#fresh-install-from-an-iso). These ISOs cannot unfortunately be distributed on GitHub for free due to large sizes, so for public projects something else has to be used for hosting.

## Verification

These images are signed with [Sigstore](https://www.sigstore.dev/)'s [cosign](https://github.com/sigstore/cosign). You can verify the signature by downloading the `cosign.pub` file from this repo and running the following command (substitute `sixpounder-kde` or `sixpounder-gnome` for the other variants):

```bash
cosign verify --key cosign.pub ghcr.io/six6pounder/sixpounder-cosmic
```
