import contextlib
import importlib.util
import io
from pathlib import Path
import struct
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('jnilibs', Path(__file__).parents[1] / 'check-jnilibs.py')
jnilibs = importlib.util.module_from_spec(spec)
spec.loader.exec_module(jnilibs)


class NativeLibraryTest(unittest.TestCase):
    def test_packaged_server_requires_correct_abi_and_16k_load_alignment(self):
        with tempfile.TemporaryDirectory() as root, contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            directory = Path(root) / 'x86_64'
            directory.mkdir()
            library = directory / 'libaw_server.so'
            self.assertFalse(jnilibs.check_abi('x86_64', root))
            elf = bytearray(120)
            elf[:6] = b'\x7fELF\x02\x01'
            struct.pack_into('<HH', elf, 16, 3, 62)
            struct.pack_into('<Q', elf, 32, 64)
            struct.pack_into('<HH', elf, 54, 56, 1)
            struct.pack_into('<I', elf, 64, 1)
            struct.pack_into('<Q', elf, 112, 0x4000)
            library.write_bytes(elf)
            self.assertTrue(jnilibs.check_abi('x86_64', root))
            self.assertFalse(jnilibs.check_lib('arm64-v8a', library))
            struct.pack_into('<Q', elf, 112, 0x1000)
            library.write_bytes(elf)
            self.assertFalse(jnilibs.check_abi('x86_64', root))
            library.write_bytes(elf[:80])
            self.assertFalse(jnilibs.check_abi('x86_64', root))


if __name__ == '__main__':
    unittest.main()
