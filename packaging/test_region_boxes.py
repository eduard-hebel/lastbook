"""Checks the non-US subdivision box path in build_packs.py. No source layers, no network.

  python3 -B packaging/test_region_boxes.py
"""
import contextlib
import importlib.util
import io
import json
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent


def load_build_packs():
    spec = importlib.util.spec_from_file_location('build_packs_under_test', HERE / 'build_packs.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


BP = load_build_packs()


class RegionBoxes(unittest.TestCase):
    def test_vienna_box_is_the_official_box_with_the_margin(self):
        box = BP.region_box(None, 'AT-9')
        for got, want in zip(box, (16.0318, 47.9679, 16.7275, 48.4727)):
            self.assertAlmostEqual(got, want, places=6)

    def test_country_box_still_comes_from_the_extract(self):
        box = BP.region_box(None, 'eu-at')
        for got, want in zip(box, (9.3768, 46.2198, 17.3141, 49.174)):
            self.assertAlmostEqual(got, want, places=6)

    def test_build_map_dispatches_at9_with_its_box_and_names_the_set(self):
        calls = []
        old_geo, old_state, old_out = BP.geo_source, BP.state_set, BP.OUT
        try:
            with tempfile.TemporaryDirectory() as tmp:
                BP.OUT = Path(tmp)
                BP.geo_source = lambda: Path(tmp) / 'source'
                BP.state_set = lambda src, dest, code, box=None: calls.append((code, box))
                with contextlib.redirect_stdout(io.StringIO()):
                    BP.build_map('AT-9')
                info = json.loads((Path(tmp) / 'maps/AT-9/map-set.json').read_text(encoding='utf-8'))
        finally:
            BP.geo_source, BP.state_set, BP.OUT = old_geo, old_state, old_out
        self.assertEqual([code for code, _ in calls], ['AT-9'])
        for got, want in zip(calls[0][1], (16.0318, 47.9679, 16.7275, 48.4727)):
            self.assertAlmostEqual(got, want, places=6)
        self.assertEqual(info['name'], 'AT-9')
        self.assertEqual(info['files'], {})


if __name__ == '__main__':
    unittest.main()
