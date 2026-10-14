"""Run the image verifier against simulated RPM/module/initramfs inventories."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
KV = '7.2.9-310.t2.fc44.x86_64'


class VerificationTests(unittest.TestCase):
    def verify(self, *, missing_driver=False, mismatched_headers=False):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            kernel = root / 'modules' / KV
            kernel.mkdir(parents=True)
            for name in ('initramfs.img', 'vmlinuz'):
                (kernel / name).write_bytes(b'image')
            for name in ('firmware', 'renamer'):
                (root / name).write_text('#!/bin/sh\n')
                (root / name).chmod(0o755)
            script = (ROOT / 'files/scripts/verify-t2.sh').read_text()
            script = script.replace('/usr/lib/modules', str(root / 'modules'))
            script = script.replace('/usr/bin/sixpounder-t2-firmware', str(root / 'firmware'))
            script = script.replace('/usr/libexec/sixpounder-t2/rename-firmware', str(root / 'renamer'))
            listing = '\n'.join(f'kernel/{name}.ko' for name in
                                ('t2bce_dma', 't2bce_core', 't2bce_vhci', 'hid-apple')
                                if not (missing_driver and name == 'hid-apple'))
            (root / 'listing').write_text(listing + '\n')
            preamble = r'''
rpm() {
  if [[ "$*" == *--qf* ]]; then
    if [[ "$*" == *kernel-devel* && "$MISMATCH" == 1 ]]; then
      echo 7.2.8-300.t2.fc44.x86_64
    else
      echo 7.2.9-310.t2.fc44.x86_64
    fi
  fi
}
modinfo() {
  if [[ "$*" == *'filename'* ]]; then
    local name="${!#}"
    [[ "$name" == hid_apple ]] && name=hid-apple
    echo "/lib/modules/test/kernel/${name}.ko.xz"
  fi
}
lsinitrd() { cat "$LISTING"; }
'''
            import os
            env = dict(os.environ, LISTING=str(root / 'listing'), MISMATCH=str(int(mismatched_headers)))
            return subprocess.run(['bash'], input=preamble + script,
                                  capture_output=True, text=True, env=env)

    def test_hyphenated_driver_and_different_archive_compression_pass(self):
        result = self.verify()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('Verified T2 kernel', result.stdout)

    def test_missing_driver_still_fails_with_an_actionable_message(self):
        result = self.verify(missing_driver=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn('Initramfs does not contain hid_apple (hid-apple.ko)', result.stderr)

    def test_header_mismatch_reports_expected_and_installed_versions(self):
        result = self.verify(mismatched_headers=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn('kernel-devel: expected ' + KV, result.stderr)
        self.assertIn('found 7.2.8-300.t2.fc44.x86_64', result.stderr)


if __name__ == '__main__':
    unittest.main()
