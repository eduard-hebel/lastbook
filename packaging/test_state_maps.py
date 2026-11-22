"""Checks the country-publishing guard in state_maps.py without the source layers or the bucket.

  python3 -B packaging/test_state_maps.py

The build side is exercised with small SQLite files: one base-only set (what a US-only source snapshot yields for a
European country) and one with a row in every detailed layer, placed inside the country's box. No network, no derived
source, nothing written outside the temporary folder.
"""
import importlib.util
import sqlite3
import sys
import tempfile
import types
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
CODE = 'eu-at'
INSIDE = (16.37, 48.21)          # Vienna, inside Austria's box
OUTSIDE = (13.40, 52.50)         # Berlin, outside Austria's box


def load_state_maps():
    """state_maps.py imports r2_publish from the release folder, which is not part of this repository."""
    real = sys.modules.get('r2_publish')
    fake = types.ModuleType('r2_publish')
    fake.MULTIPART_OVER = fake.PART = 1
    fake.Context = object
    sys.modules['r2_publish'] = fake
    try:
        spec = importlib.util.spec_from_file_location('state_maps_under_test', HERE / 'state_maps.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module
    finally:
        if real is None:
            del sys.modules['r2_publish']
        else:
            sys.modules['r2_publish'] = real


SM = load_state_maps()
FEAT = 'CREATE TABLE IF NOT EXISTS feat(id INTEGER PRIMARY KEY, layer TEXT, cls TEXT, name TEXT, minz INTEGER, geom BLOB)'
FEAT_IDX = 'CREATE VIRTUAL TABLE IF NOT EXISTS feat_idx USING rtree(id, minx, maxx, miny, maxy, minz, maxz)'


def tile_at(zoom, box_code=CODE):
    """The top-left tile of the country's box at this zoom, a legitimate row inside the box."""
    x0, _x1, y0, _y1 = SM._tile_ranges(box_code, [zoom])[zoom]
    return x0, y0


def make_set(root, detailed):
    geo = Path(root) / 'derived/geo'
    geo.mkdir(parents=True)

    def make(name, schema, rows=()):
        db = sqlite3.connect(geo / name)
        try:
            for sql in schema:
                db.execute(sql)
            for sql, values in rows:
                db.execute(sql, values)
            db.commit()
        finally:
            db.close()

    make('national.sqlite', [FEAT, FEAT_IDX, 'CREATE TABLE IF NOT EXISTS poi(id INTEGER PRIMARY KEY, cls TEXT, name TEXT, lon REAL, lat REAL)'],
         [('INSERT INTO feat VALUES(?, ?, ?, ?, ?, NULL)', (1, 'place', 'city', 'Base place', 8))])
    make('water.sqlite', ['CREATE TABLE IF NOT EXISTS resource(id INTEGER PRIMARY KEY, lon REAL, lat REAL)'])
    make('terrain.sqlite', ['CREATE TABLE IF NOT EXISTS tile(z INTEGER, x INTEGER, y INTEGER, PRIMARY KEY(z, x, y))'])
    make('buildings.sqlite', ['CREATE TABLE IF NOT EXISTS bldg(x INTEGER, y INTEGER)', 'CREATE TABLE IF NOT EXISTS bldg_socal(x INTEGER, y INTEGER)', 'CREATE TABLE IF NOT EXISTS bldg_osm(x INTEGER, y INTEGER)'])
    make('crops.sqlite', ['CREATE TABLE IF NOT EXISTS resource(id INTEGER PRIMARY KEY, lon REAL, lat REAL)'])
    make('places.sqlite', ['CREATE TABLE IF NOT EXISTS place(id INTEGER PRIMARY KEY, source TEXT, lon REAL, lat REAL)'])
    if detailed:
        lon, lat = INSIDE
        tx, ty = tile_at(8)
        bx, by = tile_at(14)
        make('national.sqlite', [FEAT, FEAT_IDX, 'CREATE TABLE IF NOT EXISTS poi(id INTEGER PRIMARY KEY, cls TEXT, name TEXT, lon REAL, lat REAL)'],
             [('INSERT INTO feat VALUES(?, ?, ?, ?, ?, NULL)', (2, 'road', 'residential', 'Test street', 12)),
              ('INSERT INTO feat_idx VALUES(?, ?, ?, ?, ?, ?, ?)', (2, lon, lon, lat, lat, 12, 30)),
              ('INSERT INTO poi(id, cls, name, lon, lat) VALUES(?, ?, ?, ?, ?)', (3, 'pharmacy', 'Test', lon, lat))])
        make('water.sqlite', ['CREATE TABLE IF NOT EXISTS resource(id INTEGER PRIMARY KEY, lon REAL, lat REAL)'],
             [('INSERT INTO resource VALUES(?, ?, ?)', (4, lon, lat))])
        make('terrain.sqlite', ['CREATE TABLE IF NOT EXISTS tile(z INTEGER, x INTEGER, y INTEGER, PRIMARY KEY(z, x, y))'],
             [('INSERT INTO tile VALUES(?, ?, ?)', (8, tx, ty))])
        make('buildings.sqlite', ['CREATE TABLE IF NOT EXISTS bldg(x INTEGER, y INTEGER)', 'CREATE TABLE IF NOT EXISTS bldg_socal(x INTEGER, y INTEGER)', 'CREATE TABLE IF NOT EXISTS bldg_osm(x INTEGER, y INTEGER)'],
             [('INSERT INTO bldg VALUES(?, ?)', (bx, by))])
        make('crops.sqlite', ['CREATE TABLE IF NOT EXISTS resource(id INTEGER PRIMARY KEY, lon REAL, lat REAL)'],
             [('INSERT INTO resource VALUES(?, ?, ?)', (5, lon, lat))])
        make('places.sqlite', ['CREATE TABLE IF NOT EXISTS place(id INTEGER PRIMARY KEY, source TEXT, lon REAL, lat REAL)'],
             [('INSERT INTO place VALUES(?, ?, ?, ?)', (6, 'OpenStreetMap', lon, lat))])


class CountryPublishing(unittest.TestCase):
    def setUp(self):
        self.old = SM.PUBLISHED_COUNTRIES
        self.old_states = SM.states

    def tearDown(self):
        SM.PUBLISHED_COUNTRIES = self.old
        SM.states = self.old_states

    def test_base_only_build_fails_coverage(self):
        with tempfile.TemporaryDirectory() as d:
            make_set(d, detailed=False)
            self.assertEqual(set(SM.country_coverage(d, CODE)), set(SM.COVERAGE))

    def test_detail_in_every_layer_passes_coverage(self):
        with tempfile.TemporaryDirectory() as d:
            make_set(d, detailed=True)
            self.assertEqual(SM.country_coverage(d, CODE), {})
            self.assertTrue(all(SM.coverage_counts(d, CODE).values()))

    def test_detail_outside_the_country_box_does_not_count(self):
        with tempfile.TemporaryDirectory() as d:
            make_set(d, detailed=True)
            geo = Path(d) / 'derived/geo'
            db = sqlite3.connect(geo / 'national.sqlite')
            lon, lat = OUTSIDE
            db.execute('INSERT INTO feat VALUES(?, ?, ?, ?, ?, NULL)', (9, 'road', 'motorway', 'Elsewhere', 12))
            db.execute('INSERT INTO feat_idx VALUES(?, ?, ?, ?, ?, ?, ?)', (9, lon, lon, lat, lat, 12, 30))
            db.execute('INSERT INTO poi(id, cls, name, lon, lat) VALUES(?, ?, ?, ?, ?)', (10, 'pharmacy', 'Elsewhere', lon, lat))
            db.commit()
            db.close()
            db = sqlite3.connect(geo / 'water.sqlite')
            db.execute('INSERT INTO resource VALUES(?, ?, ?)', (11, lon, lat))
            db.commit()
            db.close()
            counts = SM.coverage_counts(d, CODE)
            self.assertEqual(counts['roads'], 1)
            self.assertEqual(counts['help points'], 1)
            self.assertEqual(counts['water points'], 1)

    def test_place_points_are_not_roads(self):
        with tempfile.TemporaryDirectory() as d:
            make_set(d, detailed=False)
            geo = Path(d) / 'derived/geo'
            db = sqlite3.connect(geo / 'national.sqlite')
            lon, lat = INSIDE
            for i in range(20):
                db.execute('INSERT INTO feat VALUES(?, ?, ?, ?, ?, NULL)', (100 + i, 'place', 'locality', 'Place', 14))
                db.execute('INSERT INTO feat_idx VALUES(?, ?, ?, ?, ?, ?, ?)', (100 + i, lon, lon, lat, lat, 14, 30))
            db.commit()
            db.close()
            self.assertEqual(SM.coverage_counts(d, CODE)['roads'], 0)

    def test_missing_layer_counts_as_no_detail(self):
        with tempfile.TemporaryDirectory() as d:
            make_set(d, detailed=True)
            (Path(d) / 'derived/geo/buildings.sqlite').unlink()
            self.assertIn('buildings', SM.country_coverage(d, CODE))

    def test_country_must_be_opted_in_before_coverage_is_even_considered(self):
        with tempfile.TemporaryDirectory() as d:
            make_set(d, detailed=True)
            SM.PUBLISHED_COUNTRIES = {}
            self.assertTrue(SM.country_publish_blockers(d, CODE))
            SM.PUBLISHED_COUNTRIES = {CODE: {}}
            self.assertEqual(SM.country_publish_blockers(d, CODE), [])

    def test_opted_in_but_base_only_country_is_still_refused(self):
        with tempfile.TemporaryDirectory() as d:
            make_set(d, detailed=False)
            SM.PUBLISHED_COUNTRIES = {CODE: {}}
            blockers = SM.country_publish_blockers(d, CODE)
            self.assertTrue(blockers)
            self.assertIn('no roads detail inside the country box', blockers)

    def test_regions_leave_countries_out_until_listed(self):
        SM.states = lambda: ['CA']
        SM.PUBLISHED_COUNTRIES = {}
        self.assertEqual(SM.regions(), ['CA'])
        SM.PUBLISHED_COUNTRIES = {CODE: {}}
        self.assertEqual(SM.regions(), ['CA', CODE])


if __name__ == '__main__':
    unittest.main()
