import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


@unittest.skipUnless(shutil.which('make'), 'Make is required')
class MetadataPrerequisiteTest(unittest.TestCase):
    def test_metadata_uses_peakactivity_svg_without_upstream_media(self):
        makefile = Path(__file__).resolve().parents[2] / 'Makefile'
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            svg = root / 'aw-server-rust/aw-webui/static/peakactivity.svg'
            svg.parent.mkdir(parents=True)
            svg.write_text('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512"/>')
            result = subprocess.run(['make', '-f', str(makefile), '-n', 'metadata'],
                                    cwd=root, capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('magick aw-server-rust/aw-webui/static/peakactivity.svg '
                          '-resize 75% -gravity center -background white -extent 512x512',
                          result.stdout)


if __name__ == '__main__':
    unittest.main()
