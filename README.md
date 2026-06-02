# Sixpounder COSMIC &nbsp; [![build badge](https://github.com/Six6pounder/fedora-silverblue-nvidia/actions/workflows/build.yml/badge.svg)](https://github.com/Six6pounder/fedora-silverblue-nvidia/actions/workflows/build.yml)

This is my personal OS image based on `fedora-cosmic-nvidia-open`. Built using [BlueBuild](https://blue-build.org/).

## Installation

> [!WARNING]  
> [This is an experimental feature](https://www.fedoraproject.org/wiki/Changes/OstreeNativeContainerStable), try at your own discretion.

To rebase an existing atomic Fedora installation to the latest build:

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

The `latest` tag will automatically point to the latest build. That build will still always use the Fedora version specified in `recipe.yml`, so you won't get accidentally updated to the next major version.

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

## ISO

If build on Fedora Atomic, you can generate an offline ISO with the instructions available [here](https://blue-build.org/learn/universal-blue/#fresh-install-from-an-iso). These ISOs cannot unfortunately be distributed on GitHub for free due to large sizes, so for public projects something else has to be used for hosting.

## Verification

These images are signed with [Sigstore](https://www.sigstore.dev/)'s [cosign](https://github.com/sigstore/cosign). You can verify the signature by downloading the `cosign.pub` file from this repo and running the following command:

```bash
cosign verify --key cosign.pub ghcr.io/six6pounder/sixpounder-cosmic
```
