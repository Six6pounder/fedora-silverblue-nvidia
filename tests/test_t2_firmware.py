"""Exercise recovery lifecycle without network, mounts or changing host firmware."""
import contextlib
import importlib.machinery
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tarfile
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
loader = importlib.machinery.SourceFileLoader('firmware', str(ROOT / 'files/t2/usr/bin/sixpounder-t2-firmware'))
spec = importlib.util.spec_from_loader(loader.name, loader)
fw = importlib.util.module_from_spec(spec)
loader.exec_module(fw)


class FirmwareTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        for constant in ('FIRMWARE', 'STOCK_FIRMWARE', 'STATE', 'SYSFS'):
            directory = self.root / constant.lower()
            directory.mkdir()
            self.enterContext(patch.object(fw, constant, directory))
        self.run = self.enterContext(patch.object(fw, 'run'))
        self.reload = self.enterContext(patch.object(fw, 'reload_missing_devices'))

    def files(self, directory, chip='4364'):
        for extension in ('bin', 'txt', 'clm_blob'):
            (directory / f'brcmfmac{chip}b3-pcie.apple,test.{extension}').write_bytes(b'firmware')

    def archive(self, name='firmware.tar', unsafe=None):
        path = self.root / name
        with tarfile.open(path, 'w') as bundle:
            names = [unsafe] if unsafe else [f'brcmfmac4364b3-pcie.apple,test.{ext}'
                                          for ext in ('bin', 'txt', 'clm_blob')]
            for name in names:
                entry = tarfile.TarInfo(name)
                entry.size = len(b'firmware')
                bundle.addfile(entry, io.BytesIO(b'firmware'))
        return path

    def test_pci_detection_handles_t2_and_unrelated_devices(self):
        for name, vendor, identifier in [('t2', '0x106b', '0x1802'), ('wifi', '0x14e4', '0x4464'),
                                         ('other', '0x106b', '0x1234')]:
            device = fw.SYSFS / name
            device.mkdir()
            (device / 'vendor').write_text(vendor)
            (device / 'device').write_text(identifier)
        self.assertEqual(fw.hardware(), (True, {'4364'}))
        (fw.SYSFS / 't2/device').write_text('0x1234')
        self.assertEqual(fw.hardware(), (False, {'4364'}))

    def test_generic_firmware_is_not_a_complete_apple_install(self):
        (fw.FIRMWARE / 'brcmfmac4364b3-pcie.bin').write_bytes(b'generic')
        self.assertFalse(fw.complete(fw.FIRMWARE, {'4364'}))
        self.files(fw.FIRMWARE)
        self.assertTrue(fw.complete(fw.FIRMWARE, {'4364'}))
        self.assertFalse(fw.complete(fw.FIRMWARE, {'4377'}))

    def test_4377_requires_bluetooth_firmware_too(self):
        self.files(fw.FIRMWARE, '4377')
        self.assertFalse(fw.complete(fw.FIRMWARE, {'4377'}))
        for ext in ('bin', 'ptb'):
            (fw.FIRMWARE / f'brcmbt4377b3-apple,test.{ext}').write_bytes(b'bluetooth')
        self.assertTrue(fw.complete(fw.FIRMWARE, {'4377'}))

    def test_existing_compressed_firmware_is_reused(self):
        self.files(fw.STOCK_FIRMWARE)
        for firmware in fw.STOCK_FIRMWARE.iterdir():
            firmware.rename(firmware.with_name(firmware.name + '.zst'))
        with patch.object(fw, 'recover') as recover:
            fw.ensure_firmware({'4364'})
        recover.assert_not_called()
        self.assertTrue(fw.complete(fw.FIRMWARE, {'4364'}))

    def test_existing_persistent_firmware_never_downloads_again(self):
        self.files(fw.FIRMWARE)
        with patch.object(fw, 'recover') as recover:
            fw.ensure_firmware({'4364'})
        recover.assert_not_called()
        self.reload.assert_called_once()

    def test_stock_firmware_is_persisted_without_network(self):
        self.files(fw.STOCK_FIRMWARE)
        (fw.STOCK_FIRMWARE / 'brcmfmac9999-pcie.bin').write_bytes(b'unrelated')
        with patch.object(fw, 'recover') as recover:
            fw.ensure_firmware({'4364'})
        recover.assert_not_called()
        self.assertTrue(fw.complete(fw.FIRMWARE, {'4364'}))
        self.assertFalse((fw.FIRMWARE / 'brcmfmac9999-pcie.bin').exists())
        marker = json.loads((fw.STATE / 'complete.json').read_text())
        self.assertEqual(marker['source'], 'existing firmware')

    def test_download_failure_keeps_recovery_retryable(self):
        (fw.STATE / 'complete.json').write_text('stale')
        for error in [subprocess.CalledProcessError(1, 'download'),
                      subprocess.TimeoutExpired('download', 1200), KeyboardInterrupt()]:
            with patch.object(fw, 'recover', side_effect=error):
                with self.assertRaises(type(error)):
                    fw.ensure_firmware({'4364'})
            self.assertFalse((fw.STATE / 'complete.json').exists())
            self.assertEqual(list(fw.STATE.glob('recovery-*')), [])
        self.reload.assert_not_called()
        fw.ensure_firmware({'4364'}, self.archive())
        self.assertTrue((fw.STATE / 'complete.json').is_file())

    def test_successful_recovery_records_completion_and_is_idempotent(self):
        def recovered(work, chips):
            staging = work / 'staging'
            staging.mkdir()
            self.files(staging)
            return fw.install_firmware(staging, chips)
        with patch.object(fw, 'recover', side_effect=recovered) as recover:
            fw.ensure_firmware({'4364'})
            fw.ensure_firmware({'4364'})
            recover.assert_called_once()
        self.assertEqual(json.loads((fw.STATE / 'complete.json').read_text())['source'], 'Apple recovery')
        self.assertEqual(self.reload.call_count, 2)

    def test_incomplete_archive_does_not_claim_success(self):
        with self.assertRaises(RuntimeError):
            fw.ensure_firmware({'4377'}, self.archive())
        self.assertFalse((fw.STATE / 'complete.json').exists())
        self.assertEqual(list(fw.FIRMWARE.iterdir()), [])

    def test_tar_traversal_and_symlinks_are_rejected(self):
        staging = self.root / 'staging'
        staging.mkdir()
        for name in ('../outside', '/etc/firmware', 'nested/file'):
            with self.assertRaises(ValueError):
                fw.unpack(self.archive(unsafe=name), staging)
        archive = self.root / 'symlink.tar'
        with tarfile.open(archive, 'w') as bundle:
            entry = tarfile.TarInfo('link')
            entry.type = tarfile.SYMTYPE
            entry.linkname = '/etc/shadow'
            bundle.addfile(entry)
        with self.assertRaises(ValueError):
            fw.unpack(archive, staging)

    def test_upstream_deduplicated_hardlinks_are_supported(self):
        archive = self.archive()
        with tarfile.open(archive, 'a') as bundle:
            entry = tarfile.TarInfo('brcmfmac4364b3-pcie.apple,second.bin')
            entry.type = tarfile.LNKTYPE
            entry.linkname = 'brcmfmac4364b3-pcie.apple,test.bin'
            bundle.addfile(entry)
        fw.ensure_firmware({'4364'}, archive)
        self.assertEqual((fw.FIRMWARE / entry.name).read_bytes(), b'firmware')

    def test_recovery_uses_noninteractive_verified_download_and_readonly_mount(self):
        work = self.root / 'work'
        work.mkdir()
        volume = self.root / 'mounted'
        volume.mkdir()
        archive = self.archive()
        def command(*args, **kwargs):
            if args[0].endswith('rename-firmware'):
                (work / 'firmware.tar').write_bytes(archive.read_bytes())
        self.run.side_effect = command
        @contextlib.contextmanager
        def mounted(image):
            self.assertEqual(image, work / 'recovery.img')
            yield volume
        with patch.object(fw, 'mounted_image', side_effect=mounted):
            fw.recover(work, {'4364'})
        download = self.run.call_args_list[0].args
        self.assertIn('--action', download)
        self.assertIn('download', download)
        self.assertNotIn('-s', download)
        self.assertTrue(fw.complete(fw.FIRMWARE, {'4364'}))

    def test_mount_is_readonly_and_cleanup_runs_on_extraction_error(self):
        mountpoint = self.root / 'mountpoint'
        mountpoint.mkdir()
        def command(*args, **kwargs):
            if args[0] == 'losetup' and '--show' in args:
                return SimpleNamespace(stdout='/dev/loop123\n')
            if args[0] == 'lsblk':
                return SimpleNamespace(stdout=json.dumps({'blockdevices': [
                    {'children': [{'name': '/dev/loop123p1', 'fstype': 'hfsplus'}]}]}))
        self.run.side_effect = command
        with patch.object(fw.tempfile, 'mkdtemp', return_value=str(mountpoint)):
            with self.assertRaises(RuntimeError):
                with fw.mounted_image(self.root / 'image') as volume:
                    self.assertEqual(volume, mountpoint)
                    raise RuntimeError('conversion failed')
        commands = [call.args for call in self.run.call_args_list]
        self.assertIn('--read-only', commands[0])
        self.assertIn(('mount', '-t', 'hfsplus', '-o', 'ro', '/dev/loop123p1', str(mountpoint)), commands)
        self.assertEqual(commands[-2:], [('umount', str(mountpoint)), ('losetup', '--detach', '/dev/loop123')])
        self.assertFalse(mountpoint.exists())

    def test_concurrent_recovery_does_not_start_a_second_download(self):
        import fcntl
        with (fw.STATE / 'lock').open('w') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            with patch.object(fw, 'recover') as recover:
                fw.ensure_firmware({'4364'})
            recover.assert_not_called()


class HeaderTests(unittest.TestCase):
    def test_missing_t2_headers_do_not_fall_back_to_unsigned_koji(self):
        script = ROOT / 'files/scripts/lib-kernel-devel.sh'
        result = subprocess.run(['bash', '-c', '''
source "$1"
dnf5() { return 1; }
curl() { echo UNEXPECTED_KOJI; return 99; }
install_kernel_devel 7.2.9-310.t2.fc44.x86_64
''', '_', str(script)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertNotIn('UNEXPECTED_KOJI', result.stdout)
        self.assertIn('matching T2 headers', result.stderr)


if __name__ == '__main__':
    unittest.main()
