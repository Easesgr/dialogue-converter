import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import build_app

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('verify_app', ROOT / 'packaging/verify_app.py')
verify_app = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verify_app)


class PackagingTests(unittest.TestCase):
    def test_app_replacement_preserves_previous_install(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source, installed = root / 'source.app', root / 'installed.app'
            source.mkdir(); installed.mkdir()
            (source / 'version').write_text('new')
            (installed / 'version').write_text('old')
            with patch.object(build_app, 'ROOT', root):
                build_app.replace_with_backup(source, installed)
            self.assertEqual((installed / 'version').read_text(), 'new')
            backup, = (root / 'backups').iterdir()
            self.assertEqual((backup / 'version').read_text(), 'old')

    def test_interrupted_install_restores_previous_app(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source, installed = root / 'source.app', root / 'installed.app'
            source.mkdir(); installed.mkdir()
            (installed / 'version').write_text('old')

            def failed_copy(source, destination, **kwargs):
                destination.mkdir()
                (destination / 'partial').write_text('incomplete')
                raise OSError('simulated copy failure')

            with patch.object(build_app, 'ROOT', root), patch.object(build_app.shutil, 'copytree', failed_copy):
                with self.assertRaisesRegex(OSError, 'simulated'):
                    build_app.replace_with_backup(source, installed)
            self.assertEqual((installed / 'version').read_text(), 'old')
            self.assertFalse((installed / 'partial').exists())

    def test_cross_architecture_release_is_rejected(self):
        with patch.object(build_app.platform, 'machine', return_value='arm64'):
            with self.assertRaisesRegex(ValueError, 'matching Mac'):
                build_app.architecture('x86_64')

    def test_external_dependency_and_newer_macos_are_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            binary = root / 'binary'
            binary.write_bytes(b'\xcf\xfa\xed\xfe' + b'fixture')

            def inspect(*args):
                if args[0].endswith('lipo'):
                    return 'arm64\n'
                if args[1] == '-L':
                    return 'binary:\n\t/opt/homebrew/lib/libpython.dylib (compatibility version 1.0.0)\n'
                return 'cmd LC_BUILD_VERSION\ncmdsize 32\nplatform 1\nminos 15.0\n'

            with patch.object(verify_app, 'output', inspect):
                with self.assertRaisesRegex(ValueError, 'External dependency'):
                    verify_app.verify_binaries(root, 'arm64')

            def system_dependencies(*args):
                return 'binary:\n\t/usr/lib/libSystem.B.dylib (compatibility version 1.0.0)\n' if args[1] == '-L' else inspect(*args)

            with patch.object(verify_app, 'output', system_dependencies):
                with self.assertRaisesRegex(ValueError, 'newer macOS'):
                    verify_app.verify_binaries(root, 'arm64')


if __name__ == '__main__':
    unittest.main()
