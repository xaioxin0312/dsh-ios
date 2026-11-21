import importlib.util
import io
import pathlib
import struct
import tarfile
import tempfile
import unittest

MODULE_PATH = pathlib.Path(__file__).resolve().parents[1] / 'verify_package.py'
SPEC = importlib.util.spec_from_file_location('dsh_roothide_audit', MODULE_PATH)
audit = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(audit)


def thin(minimum, subtype=0):
    command = struct.pack('<IIIIII', 0x32, 24, 2, minimum, 0x100500, 0)
    return struct.pack('<IIIIIIII', 0xfeedfacf, 0x100000c, subtype, 2, 1, len(command), 0, 0) + command


class PackageAuditTests(unittest.TestCase):
    def test_reads_real_macho_minimum_separately_from_plist(self):
        self.assertEqual(audit.macho(thin(0x110000))[0]['minimum_os'], (17, 0, 0))
        self.assertEqual(audit.macho(thin(0x100200))[0]['minimum_os'], (16, 2, 0))

    def test_distinguishes_arm64e_from_arm64(self):
        plain, authenticated = thin(0xf0000), thin(0xf0000, 2)
        header = struct.pack('>II', 0xcafebabe, 2)
        offset = 8 + 2 * 20
        entries = struct.pack('>IIIII', 0x100000c, 0, offset, len(plain), 0)
        entries += struct.pack('>IIIII', 0x100000c, 2, offset + len(plain), len(authenticated), 0)
        self.assertEqual([s['subtype'] for s in audit.macho(header + entries + plain + authenticated)], [0, 2])

    def test_rejects_truncated_fat_slice(self):
        data = struct.pack('>II', 0xcafebabe, 1) + struct.pack('>IIIII', 0x100000c, 0, 9999, 10, 0)
        with self.assertRaises(ValueError):
            audit.macho(data)

    def test_rejects_archive_path_traversal(self):
        stream = io.BytesIO()
        with tarfile.open(fileobj=stream, mode='w:gz') as archive:
            item = tarfile.TarInfo('../outside')
            item.size = 1
            archive.addfile(item, io.BytesIO(b'x'))
        with self.assertRaises(ValueError):
            audit.tar_members(stream.getvalue())

    def test_rejects_duplicate_archive_paths(self):
        stream = io.BytesIO()
        with tarfile.open(fileobj=stream, mode='w:gz') as archive:
            for _ in range(2):
                item = tarfile.TarInfo('./usr/bin/same')
                item.size = 1
                archive.addfile(item, io.BytesIO(b'x'))
        with self.assertRaises(ValueError):
            audit.tar_members(stream.getvalue())


if __name__ == '__main__':
    unittest.main()
