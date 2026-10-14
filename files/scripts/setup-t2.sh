#!/usr/bin/env bash
set -euo pipefail
chmod 755 /usr/bin/sixpounder-t2-firmware
# Override the shared desktop autostart, including an existing /etc copy after
# a rebase; a user can still launch CoolerControl explicitly.
install -d /etc/xdg/autostart
cat > /etc/xdg/autostart/org.coolercontrol.CoolerControl.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=CoolerControl
Hidden=true
EOF
# common.yml enabled this daemon earlier. Remove that symlink before masking.
systemctl disable coolercontrold.service
# t2linux-config's preset refers to a mutable-system firmware installer.
cat > /usr/lib/systemd/system-preset/90-sixpounder-t2.preset <<'EOF'
disable get-apple-firmware.service
disable coolercontrold.service
enable t2fanrd.service
enable sixpounder-t2-firmware.timer
EOF
