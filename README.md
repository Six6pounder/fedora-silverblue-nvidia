# Sixpounder Atomic Images &nbsp; [![build badge](https://github.com/Six6pounder/fedora-silverblue-nvidia/actions/workflows/build.yml/badge.svg)](https://github.com/Six6pounder/fedora-silverblue-nvidia/actions/workflows/build.yml)

These are my personal Fedora Atomic OS images, with NVIDIA (open kernel modules) drivers baked in. Built using [BlueBuild](https://blue-build.org/). Three desktop variants are published from this repo, sharing the same tooling/config and differing only in base image:

| Variant | Recipe | Base image | Published as |
| --- | --- | --- | --- |
| COSMIC | [`recipes/recipe.yml`](recipes/recipe.yml) | `fedora-cosmic-nvidia-open` | `ghcr.io/six6pounder/sixpounder-cosmic` |
| KDE Plasma (Kinoite) | [`recipes/recipe-kde.yml`](recipes/recipe-kde.yml) | `fedora-kinoite-nvidia-open` | `ghcr.io/six6pounder/sixpounder-kde` |
| GNOME (Silverblue) | [`recipes/recipe-gnome.yml`](recipes/recipe-gnome.yml) | `fedora-silverblue-nvidia-open` | `ghcr.io/six6pounder/sixpounder-gnome` |

That sharing is structural, not a convention to remember: every module lives in [`recipes/common.yml`](recipes/common.yml) and each recipe is just a name, a description, a base image and `from-file: common.yml`. Add a package or a Flatpak once and all three images get it, so switching desktops never means switching to a less-equipped system. Only put something in an individual recipe if it genuinely differs by desktop — today that is just the GNOME variant's Shell extensions (Blur my Shell, AppIndicator, Dash to Dock, Caffeine, PiP on top) and Extension Manager.

## Installation

> [!WARNING]  
> [This is an experimental feature](https://www.fedoraproject.org/wiki/Changes/OstreeNativeContainerStable), try at your own discretion.

To rebase an existing atomic Fedora installation to the latest build, substitute `sixpounder-cosmic` below with `sixpounder-kde` or `sixpounder-gnome` if you want one of the other variants:

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
