# AT-9 Vienna: bounded source fixture and provenance prototype

Status: **private prototype on an independent fork branch. Not a production map, not complete, and not proposed upstream.**
Nothing here publishes a map, opens a pull request or comments on one. The dataset work overlaps what
@caeylin volunteered to do in Immortal-Protocols/lastbook PR #84, so this is review material for that
coordinator, not a competing change.

The branch starts from `eduard-hebel/lastbook` at `at-9-region-box` (`bed374b`, "Maps: cut a non-US
subdivision such as Vienna AT-9 from its own box"). It adds only new files under
`prototypes/at-9-vienna-fixture/`; it does not edit `packaging/`, `docs/` or `engine/`.

## What this proves

- A genuine Vienna input can be cut by **the repository's own cutter**, `packaging/build_packs.py` ->
  `build_map('AT-9')`, into a map set that passes the real `packaging/state_maps.py` `scan()` file
  contract with zero failures.
- The bounded official BEV place-name sample and a bounded OpenStreetMap help-point sample survive
  the cut, including the known **Sankt Stephan/Stephansdom** point at 16.3730427 E, 48.2082586 N.
- The whole build and test run with sockets and `urllib` disabled.
- The source files have verified URLs, licences, access dates and SHA-256 values.

## What this does not prove

- It is **not** a publishable Austrian map. The fixture has no addresses, terrain, buildings, crops,
  water lines or dams.
- It does **not** show that `map-set.json` or the release manifest carries provenance. They do not.
- It does **not** show that an AT-9 build from the current US source snapshot is Austrian. It is not:
  see "Findings that matter for a real build" below.
- It does **not** replace the address-search decision for four-digit postcodes or slash house numbers
  in `docs/REGIONS-AT.md`.

## Sources, all verified on 2026-11-22

| Use | Source | URL | Licence | Bytes | SHA-256 |
|---|---|---|---|---|---|
| 1,082 named points in the AT-9 box | BEV, Digitales Landschaftsmodell - Geographische Namen, Stichtag 23.03.2026 (record `49ca903b-2ca8-4751-8b5d-490bb73dcfec`) | https://data.bev.gv.at/download/DLM/DLM_20260323/DLM_7000_NAMEN_20260323.gpkg | CC BY 4.0 | 58,527,744 | `a58763bc033ef26a1723c2daae77aa7511f18c604a87c4faefb7ee0b5a4a09f2` |
| 2,344 help points (hospital, pharmacy, fire station, police, drinking water) | OpenStreetMap contributors, one bounded Overpass response for the AT-9 box, sanitized to location and name | https://maps.mail.ru/osm/tools/overpass/api/interpreter | ODbL 1.0 | 422,376 committed (808,515 raw) | `fdb0cb92be375e31af3de37ed665fc911b528f391928d9e24e794a9540324065` committed (`89e6181c6d6920b0c5360cd1ffff815268d084f18151a2a7bc2f956ebb7ee59c` raw) |

The exact catalogue record, DOI, product page, licence statement, ETag, `Last-Modified` and the
download guard are in `sources.lock.json`. The raw 58.5 MB GeoPackage is **not committed**; the
frozen 244 KB derived BEV sample is, with its own hash. The committed OSM sample is 412 KB: only element id, coordinates and the tags `amenity`, `emergency` and `name`; contact, address, operator and payment tags were removed before commit. The 808,515-byte raw response stays in the uncommitted `cache/`.

BEV's record says "Für dieses Produkt gilt die Standardlizenz CC-BY-4.0" and links
https://creativecommons.org/licenses/by/4.0/. It gives no mandatory citation string, so the credit
line used here is composed from the record and is marked as such:

> © BEV - Bundesamt für Eich- und Vermessungswesen, Digitales Landschaftsmodell - Geographische
> Namen, Stichtag 23.03.2026, CC BY 4.0

OpenStreetMap data is © OpenStreetMap contributors, ODbL 1.0. The ODbL share-alike applies to the
OpenStreetMap-derived part of a produced database; mixing it with CC BY 4.0 BEV rows needs a licence
decision before publishing. This prototype records the licences and does not resolve that question.

The canonical Overpass endpoints (`overpass-api.de`, `overpass.kumi.systems`,
`overpass.private.coffee`) timed out from this build host. The public mirror named above answered and
is recorded as the actual endpoint used. That is a real provenance difference, not an official
endpoint claim.

## What is in the fixture

`fixture/national.sqlite` is the schema `build_packs.state_set()` reads:

- `feat` / `feat_idx`: 1,082 BEV named points with `layer='place'`, mapped to `cls`
  `city`/`town`/`suburb`/`village`/`hamlet`/`locality` and a `minz`.
- `poi`: 2,344 OpenStreetMap help points in the five classes `web/map.js` has layers for.
- `meta`: source, data date, box, licence, credit, sidecar pointer and the note that this is a
  bounded prototype.

`fixture/places.sqlite` has 1,649 rows: 1,082 BEV names with `source='BEV DLM Geographische Namen
23.03.2026'` and 567 named OSM help points with `source='OpenStreetMap'`. The last string is what the
cutter and the coverage check look for.

`fixture/provenance.json` is the sidecar. It is **outside** any map set because a file inside the set
fails the scan contract and `map-set.json` rejects an extra key. The cut build writes the same sidecar
to `out/AT-9.provenance.json`, again outside `out/maps/AT-9/`.

Counts of the derived BEV sample: settlements 184, areas 118, terrain 102, water 76, other landmarks
602. Ried names (1,742 field names) are intentionally left out; they are not help-map places.
Defibrillators (427) were fetched by the same Overpass query but are not used because `web/map.js`
has no defibrillator layer.

## Run it

Python 3.14 was used. `pyproj` is needed only to derive the BEV sample from the raw GeoPackage; the
fixture build, cut and test work from the committed JSON samples.

```sh
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt

# 1. Optional: fetch the two raw sources and verify them. Writes cache/ only.
.venv/bin/python fetch_sources.py            # or --offline to verify only

# 2. Optional: rebuild the committed BEV sample from the 58.5 MB GeoPackage.
.venv/bin/python derive_bev_sample.py
.venv/bin/python derive_bev_sample.py --check

# 3. Build the two genuine fixture files from the frozen samples.
.venv/bin/python build_fixture.py

# 4. Cut a real AT-9 map set with packaging/build_packs.py's own cutter.
.venv/bin/python cut_fixture.py

# 5. Offline smoke test: network disabled, known place, counts, hashes, scan contract.
.venv/bin/python offline_smoke_test.py
```

`cut_fixture.py` assembles `out/cutter-source/` from the two genuine files plus empty schema stubs
for the layers this prototype does not carry. The stubs have no rows. Without them the cutter cannot
run, because it expects a complete source snapshot. The cut itself is the repository's code; only
`geo_source()` is pointed at the fixture and the download-space floor is relaxed for a few megabytes.

## Test evidence

`offline_smoke_test.py` runs 13 tests. Last run: **13 passed, 0 failed** (about 0.1 s). It checks:

1. sockets, `create_connection`, `getaddrinfo` and `urllib.request.urlopen` raise before the build;
2. `map-set.json` has exactly `name`, `files`, `bytes`, `seconds`; the file set equals
   `state_maps.ALLOWED`; total is 970,811 bytes;
3. the known Stephansdom point and its place-finder row are present with the expected coordinates;
4. help-point counts are 1,789 drinking water, 363 pharmacies, 110 police, 58 fire stations and 24
   hospitals, all inside the box;
5. the place finder has 567 OSM rows and 1,082 BEV rows, and its FTS index finds Stephansdom;
6. the cut `national.sqlite` has only the `status` meta key, so no attribution survives the cut;
7. the sidecar is outside the set and its two source records have URL, licence, licence URL, access
   date, SHA-256 and credit;
8. adding the sidecar inside the set makes the real scan fail on the file contract;
9. adding an `attribution` key to `map-set.json` makes the real scan fail on the key contract;
10. the unmodified set passes the real scan with no failures;
11. the coverage counter reports 1,076 "roads" although there are zero road rows (see below);
12. the committed samples and, when present, the raw GeoPackage match `sources.lock.json`;
13. no built file contains `/home/`, the build user's name, the working-directory name or a private
    key, and no file is larger than 5 MB.

## Findings that matter for a real build

These are the reasons this stays a prototype. Each is tested or read directly from the named code.

1. **Provenance has nowhere to live today.** `packaging/state_maps.py:141` accepts only `name`,
   `files`, `bytes` and `seconds` in `map-set.json`; an extra key fails the scan.
   `engine/setup/manifest.py:83` rebuilds a map entry from known fields, so an `attribution` field is
   dropped before setup sees it. The scan also requires the set's file list to equal `ALLOWED`
   (`packaging/state_maps.py:135`), so a provenance file *inside* the set fails too. This prototype
   therefore writes a sidecar **outside** the set and does not claim the manifest transfers it.
2. **The cut drops source provenance.** `state_set()` copies no `meta` from the source; the cut
   `national.sqlite` ends up with only `status`. A real build must add attribution to the set and to
   the manifest before anyone calls an AT-9 map Austrian.
3. **The base is not Austrian and is not box-filtered.** `base_set()` inserts every non-OSM place
   row, and `state_set()` clones the whole base before adding rows inside the box. Building AT-9
   from today's US source snapshot would carry the US low-zoom base and every US gazetteer place into
   an AT-9 map. This fixture avoids that because its source is Vienna-only. A production build needs
   an Austrian base or a region-filtered place copy.
4. **The coverage guard can be fooled.** `packaging/state_maps.py:77` counts "roads" as any `feat`
   with `minz>8`, not `layer='road'`. The 1,082 place points make this fixture report 1,076 "roads"
   while holding zero roads. The guard would pass an AT-9 set with no streets at all. The test asserts
   this false positive rather than hiding it.
5. **OSM help points are not an official list.** They are useful and bounded, but completeness varies.
   The official BMI police list and the blackout promise discussed in `docs/REGIONS-AT.md` would be
   stronger for police stations, and were not fetched here.
6. **Licence mixing needs a decision.** BEV rows are CC BY 4.0; OSM rows are ODbL 1.0. The sidecar
   records both. Whether a combined database can be distributed as a Lastbook map set is a decision
   for the maintainers, not something this prototype asserts.

## Files

| File | What it is |
|---|---|
| `sources.lock.json` | URLs, licences, access dates, byte counts and SHA-256 values; also what was deliberately not downloaded |
| `overpass-help-points-at9.overpassql` | The exact bounded Overpass query |
| `fetch_sources.py` | Fetch missing sources, verify every hash, or verify offline |
| `derive_bev_sample.py` | Derive the committed Vienna sample from the BEV GeoPackage |
| `build_fixture.py` | Build `fixture/national.sqlite`, `fixture/places.sqlite` and the sidecar |
| `cut_fixture.py` | Run the repository's real cutter on the fixture |
| `offline_smoke_test.py` | The 13-test offline evidence run |
| `sample/` | Frozen bounded samples: the derived BEV names and the sanitized Overpass help points |
| `sanitize_osm.py` | Remove contact, address and operator tags from the Overpass response |
| `fixture/` | The two genuine cutter-readable SQLite files and their sidecar |

## Next step for @caeylin

Review the fixture and the six findings, especially 1 to 3. The smallest useful code change is a
provenance field that both `map-set.json` and `engine/setup/manifest.py` keep, plus an Austrian base
or a region-filtered place copy. Until those land, this branch should not be merged or published as
an Austrian map.
