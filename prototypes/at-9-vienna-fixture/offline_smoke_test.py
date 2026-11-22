#!/usr/bin/env python3
"""Offline smoke test for the AT-9 Vienna fixture and the real map cutter.

  python3 offline_smoke_test.py

The whole build runs with sockets and urllib disabled. It then checks the known Stephansdom
sample, the help-point counts, the place finder, hashes, the provenance sidecar, and the real
packaging/state_maps.py scan contract. It also shows the two contract failures that keep the
sidecar outside the map set: an extra file in the set and an unknown key in map-set.json.
"""
import hashlib
import json
import shutil
import socket
import sqlite3
import sys
import tempfile
import types
import unittest
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
sys.path.insert(0, str(REPO / 'packaging'))
sys.modules.setdefault('r2_publish', types.ModuleType('r2_publish'))

import cut_fixture                            # noqa: E402
import state_maps as sm                       # noqa: E402

sm.S.read_terms = lambda p: ['zzz-not-present']

BOX = (16.1818, 48.1179, 16.5775, 48.3227)


class NetworkBlocked(RuntimeError):
    pass


def blocked(*a, **k):
    raise NetworkBlocked('network access is disabled for this test')


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        while chunk := f.read(1 << 22):
            h.update(chunk)
    return h.hexdigest()


class ViennaFixture(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.saved = (socket.socket, socket.create_connection, socket.getaddrinfo, urllib.request.urlopen)
        socket.socket = blocked
        socket.create_connection = blocked
        socket.getaddrinfo = blocked
        urllib.request.urlopen = blocked
        cls.tmp = tempfile.TemporaryDirectory()
        cls.out = Path(cls.tmp.name) / 'out'
        cls.info = cut_fixture.build(cls.out)
        cls.map = cls.out / 'maps' / 'AT-9'
        cls.geo = cls.map / 'derived' / 'geo'

    @classmethod
    def tearDownClass(cls):
        socket.socket, socket.create_connection, socket.getaddrinfo, urllib.request.urlopen = cls.saved
        cls.tmp.cleanup()

    def db(self, name):
        return sqlite3.connect(f'file:{self.geo / name}?mode=ro', uri=True)

    def test_network_guard_is_active(self):
        with self.assertRaises(NetworkBlocked):
            socket.create_connection(('example.com', 80), timeout=1)
        with self.assertRaises(NetworkBlocked):
            urllib.request.urlopen('https://example.com', timeout=1)

    def test_map_set_contract_and_box(self):
        info = json.loads((self.map / 'map-set.json').read_text(encoding='utf-8'))
        self.assertEqual(info['name'], 'AT-9')
        self.assertEqual(set(info), {'name', 'files', 'bytes', 'seconds'})
        rels = {p.relative_to(self.map).as_posix() for p in self.map.rglob('*') if p.is_file()}
        self.assertEqual(rels, sm.ALLOWED)
        self.assertNotIn('provenance.json', rels)
        self.assertEqual(info['files'], {r: (self.map / r).stat().st_size for r in rels - {'map-set.json'}})
        self.assertEqual(info['bytes'], sum(info['files'].values()))
        self.assertLess(info['bytes'], 5_000_000)

    def test_known_stephansdom_place(self):
        db = self.db('national.sqlite')
        row = db.execute("SELECT layer, cls, name, minz, geom FROM feat WHERE name='Sankt Stephan/Stephansdom'").fetchone()
        db.close()
        self.assertIsNotNone(row)
        layer, cls, name, minz, geom = row
        self.assertEqual((layer, cls, name, minz), ('place', 'locality', 'Sankt Stephan/Stephansdom', 14))
        import struct
        self.assertEqual(struct.unpack('<4i', geom)[:2], (1, 1))
        places = self.db('places.sqlite')
        found = places.execute("SELECT name, kind, lat, lon, source FROM place WHERE name='Sankt Stephan/Stephansdom'").fetchone()
        places.close()
        self.assertIsNotNone(found)
        self.assertAlmostEqual(found[2], 48.2082586, places=6)
        self.assertAlmostEqual(found[3], 16.3730427, places=6)
        self.assertTrue(found[4].startswith('BEV DLM'))

    def test_help_point_counts_and_box(self):
        db = self.db('national.sqlite')
        counts = dict(db.execute('SELECT cls, count(*) FROM poi GROUP BY cls').fetchall())
        self.assertEqual(counts, {'drinking_water': 1789, 'pharmacy': 363, 'police': 110, 'fire_station': 58, 'hospital': 24})
        west, south, east, north = BOX
        bad = db.execute('SELECT count(*) FROM poi WHERE lon<? OR lon>? OR lat<? OR lat>?', (west, east, south, north)).fetchone()[0]
        db.close()
        self.assertEqual(bad, 0)

    def test_place_finder_sources_and_fts(self):
        db = self.db('places.sqlite')
        sources = dict(db.execute('SELECT source, count(*) FROM place GROUP BY source').fetchall())
        self.assertEqual(sources['OpenStreetMap'], 567)
        self.assertEqual(sources['BEV DLM Geographische Namen 23.03.2026'], 1082)
        hit = db.execute("SELECT p.name FROM place_fts f JOIN place p ON p.id=f.rowid WHERE place_fts MATCH 'stephansdom'").fetchall()
        db.close()
        self.assertIn(('Sankt Stephan/Stephansdom',), hit)

    def test_cut_set_carries_no_attribution_today(self):
        db = self.db('national.sqlite')
        keys = {k for (k,) in db.execute('SELECT key FROM meta')}
        db.close()
        self.assertEqual(keys, {'status'})
        self.assertNotIn('attribution', keys)

    def test_sidecar_is_outside_and_complete(self):
        sidecar = self.out / 'AT-9.provenance.json'
        self.assertTrue(sidecar.exists())
        self.assertFalse((self.map / 'provenance.json').exists())
        p = json.loads(sidecar.read_text(encoding='utf-8'))
        self.assertEqual(p['schema'], 'lastbook-map-provenance/1')
        self.assertEqual(p['map_id'], 'AT-9')
        self.assertGreaterEqual(len(p['sources']), 2)
        for s in p['sources']:
            for key in ('url', 'licence', 'licence_url', 'access_date', 'sha256', 'credit'):
                self.assertTrue(s.get(key), f'{s.get("title")} lacks {key}')
            self.assertRegex(s['sha256'], r'^[0-9a-f]{64}$')
        self.assertEqual(p['cut']['map_set']['name'], 'AT-9')

    def test_sidecar_inside_set_fails_the_contract(self):
        extra = self.map / 'provenance.json'
        shutil.copy2(self.out / 'AT-9.provenance.json', extra)
        try:
            fails, _ = sm.scan(self.map, 'AT-9')
        finally:
            extra.unlink()
        self.assertTrue(any('files differ from the contract' in f for f in fails), fails)

    def test_unknown_map_set_key_fails_the_scan(self):
        path = self.map / 'map-set.json'
        original = path.read_text(encoding='utf-8')
        info = json.loads(original)
        info['attribution'] = {'licence': 'CC BY 4.0'}
        path.write_text(json.dumps(info, indent=1), encoding='utf-8')
        try:
            fails, _ = sm.scan(self.map, 'AT-9')
        finally:
            path.write_text(original, encoding='utf-8')
        self.assertTrue(any('map-set.json does not name the region' in f for f in fails), fails)

    def test_real_scan_contract_passes(self):
        fails, _ = sm.scan(self.map, 'AT-9')
        self.assertEqual(fails, [])

    def test_coverage_roads_is_a_false_positive(self):
        counts = sm.coverage_counts(self.map)
        db = self.db('national.sqlite')
        place_rows = db.execute("SELECT count(*) FROM feat WHERE minz>8").fetchone()[0]
        road_rows = db.execute("SELECT count(*) FROM feat WHERE layer='road'").fetchone()[0]
        db.close()
        self.assertEqual(road_rows, 0)
        self.assertEqual(counts['roads'], place_rows)
        self.assertGreater(counts['roads'], 1000)

    def test_sources_and_samples_match_the_lock(self):
        lock = json.loads((HERE / 'sources.lock.json').read_text(encoding='utf-8'))
        bev = HERE / 'sample' / 'bev-vienna-names-20260323.json'
        self.assertEqual(sha256_file(bev), lock['derived']['bev_vienna_names']['sha256'])
        osm = HERE / 'sample' / 'osm-help-points-at9.json'
        self.assertEqual(sha256_file(osm), lock['sources']['osm_help_points_at9']['sha256'])
        raw = HERE / 'cache' / 'osm-help-points-at9.raw.json'
        if raw.exists():
            self.assertEqual(sha256_file(raw), lock['sources']['osm_help_points_at9']['raw_sha256'])
        gpkg = HERE / 'cache' / 'DLM_7000_NAMEN_20260323.gpkg'
        if gpkg.exists():
            self.assertEqual(sha256_file(gpkg), lock['sources']['bev_dlm_names_20260323']['sha256'])

    def test_no_private_data(self):
        needles = (b'/home/', b'eduard', b'lastbook-vienna-fixture', b'BEGIN PRIVATE KEY')
        for p in self.map.rglob('*'):
            if not p.is_file():
                continue
            data = p.read_bytes()
            self.assertLess(len(data), 5_000_000, p)
            for needle in needles:
                self.assertNotIn(needle, data, p)


if __name__ == '__main__':
    unittest.main(verbosity=2)
