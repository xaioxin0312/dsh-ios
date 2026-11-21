import os
import pathlib
import shutil
import subprocess
import tempfile
import unittest

from test_package_audit import audit

WRAPPER = pathlib.Path(__file__).resolve().parents[1] / 'dpkg-root-owner'


@unittest.skipUnless(os.name != 'nt' and shutil.which('dpkg-deb'), 'POSIX host with dpkg-deb required')
class ArchiveOwnershipTests(unittest.TestCase):
    def test_root_archive_owner_preserves_setuid_without_chowning_source(self):
        with tempfile.TemporaryDirectory(prefix='dsh-archive-owner-') as temp:
            root = pathlib.Path(temp)
            source = root / 'stage'
            (source / 'DEBIAN').mkdir(parents=True, mode=0o755)
            (source / 'DEBIAN').chmod(0o755)
            (source / 'DEBIAN/control').write_text('Package: dsh-owner-test\nVersion: 1\nArchitecture: all\nMaintainer: Test <test@example.invalid>\nDescription: Local metadata test\n')
            helper = source / 'usr/bin/helper'
            helper.parent.mkdir(parents=True)
            helper.write_text('#!/bin/sh\nexit 0\n')
            helper.chmod(0o4755)
            before = helper.stat()
            package = root / 'metadata-test.deb'
            subprocess.run(['sh', str(WRAPPER), '-Zgzip', '-z1', '-b', str(source), str(package)], check=True, capture_output=True)
            parts = audit.deb_members(package)
            payload = audit.tar_members(parts['data.tar.gz'])
            member, _ = payload['usr/bin/helper']
            self.assertEqual((member.uid, member.gid), (0, 0))
            self.assertEqual(member.mode & 0o7777, 0o4755)
            self.assertEqual((helper.stat().st_uid, helper.stat().st_gid), (before.st_uid, before.st_gid))
            self.assertTrue(all(m.uid == 0 and m.gid == 0 for m, data in payload.values()))


if __name__ == '__main__':
    unittest.main()
