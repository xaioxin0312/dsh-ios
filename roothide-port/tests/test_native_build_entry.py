import json
import os
import pathlib
import subprocess
import tempfile
import unittest

ENTRY = pathlib.Path(__file__).resolve().parents[1] / 'build-native.sh'


@unittest.skipIf(os.name == 'nt', 'POSIX shell entry-point checks run on WSL/macOS')
class NativeBuildEntryTests(unittest.TestCase):
    def test_passes_layout_to_both_theos_consumers(self):
        with tempfile.TemporaryDirectory(prefix='dsh-native-entry-') as temp:
            root = pathlib.Path(temp)
            payload, stage = root / 'payload', root / 'stage'
            payload.mkdir()
            output = root / 'arguments.json'
            fake = root / 'record-make'
            fake.write_text('#!/usr/bin/env python3\nimport json,os,pathlib,sys\npathlib.Path(os.environ["DSH_TEST_ARGS"]).write_text(json.dumps(sys.argv[1:]))\n')
            fake.chmod(0o755)
            env = {**os.environ, 'MAKE': str(fake), 'DSH_TEST_ARGS': str(output)}
            subprocess.run(['sh', str(ENTRY), str(payload), str(stage), 'package'], env=env, check=True)
            args = json.loads(output.read_text())
            # common.mk/package metadata reads DIR; stage.mk copies DIR_NAME.
            self.assertIn('THEOS_LAYOUT_DIR=' + str(payload.resolve()), args)
            self.assertIn('THEOS_LAYOUT_DIR_NAME=' + str(payload.resolve()), args)
            self.assertIn('THEOS_STAGING_DIR=' + str(stage.resolve()), args)
            self.assertIn('THEOS_PACKAGE_SCHEME=roothide', args)
            self.assertEqual(args[-1], 'package')

    def test_refuses_to_stage_over_the_input(self):
        with tempfile.TemporaryDirectory(prefix='dsh-native-entry-') as temp:
            result = subprocess.run(['sh', str(ENTRY), temp, temp, 'stage'], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('must be different', result.stderr)


if __name__ == '__main__':
    unittest.main()
