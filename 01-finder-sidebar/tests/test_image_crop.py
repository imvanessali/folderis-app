import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from PIL import Image


ROOT = Path(__file__).resolve().parents[1]
SKILLS = ROOT / "skills" / "skills.py"
RESULT_MARKER = "__FOLDERIS_LOCAL_RESULT__"


class ImageCropTests(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.folder = Path(self.temp_dir.name)
        self.source = self.folder / "asymmetric.png"
        image = Image.new("RGB", (12, 10))
        pixels = image.load()
        for y in range(image.height):
            for x in range(image.width):
                pixels[x, y] = (x * 17, y * 23, (x * 11 + y * 7) % 256)
        image.save(self.source)

    def tearDown(self):
        self.temp_dir.cleanup()

    def run_skill(self, *arguments, check=True):
        return subprocess.run(
            [sys.executable, str(SKILLS), *map(str, arguments)],
            cwd=self.folder,
            text=True,
            capture_output=True,
            check=check,
        )

    def assert_crop_pixels(self, output, box):
        with Image.open(self.source) as source, Image.open(output) as cropped:
            self.assertEqual(cropped.tobytes(), source.crop(box).tobytes())

    def test_explicit_zero_origin_routes_to_exact_top_left_crop(self):
        result = self.run_skill(
            "local-dispatch",
            "--request", "从（0，0）开始裁成6*5px",
            "--files", self.source,
        )
        payload = json.loads(result.stdout.split(RESULT_MARKER, 1)[1])
        output = self.folder / "asymmetric_cropped.png"

        self.assertTrue(payload["matched"])
        self.assertTrue(payload["success"])
        self.assertEqual(payload["skill"], "img-resize")
        self.assert_crop_pixels(output, (0, 0, 6, 5))
        with Image.open(self.source) as source, Image.open(output) as cropped:
            self.assertNotEqual(
                cropped.tobytes(),
                source.crop((3, 2, 9, 7)).tobytes(),
                "Top-left crop must not silently become a centered crop",
            )

    def test_nonzero_origin_is_exact(self):
        self.run_skill("img-resize", self.source, "--crop", "5,4,2,3")
        self.assert_crop_pixels(self.folder / "asymmetric_cropped.png", (2, 3, 7, 7))

    def test_out_of_bounds_crop_fails_without_output(self):
        before = self.source.read_bytes()
        result = self.run_skill(
            "img-resize", self.source, "--crop", "10,10,3,2", check=False)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("超出原图", result.stderr)
        self.assertEqual(self.source.read_bytes(), before)
        self.assertFalse((self.folder / "asymmetric_cropped.png").exists())


if __name__ == "__main__":
    unittest.main()
