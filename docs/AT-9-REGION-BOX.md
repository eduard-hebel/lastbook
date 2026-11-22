# Vienna (`AT-9`) as a non-US region: box, ID and attribution flow

Status: code path for the box and the ID only. No Austrian source layer, no dataset fixture and no attribution record
is added here, and nothing is published. This document is the technical half of the coordination on pull request #84;
the source layers, licences and provenance stay with @caeylin's work on the merged Austria proposal
([REGIONS-AT.md](REGIONS-AT.md), [regions-at-proposed.json](regions-at-proposed.json)).

## What this branch changes

- `packaging/nonus-regions.json` holds one region, `AT-9` (Wien). Its `box` is the unpadded BEV VGD box from
  REGIONS-AT.md: 16.1818, 48.1179, 16.5775, 48.3227.
- `packaging/build_packs.py` gains `subdivision_box()` and a branch in `region_box()` and `build_map()`. A code in
  `SUBDIVISIONS` uses its official boundary plus the same 0.15 degree margin as a state and a country. It never falls
  through to `state_box()`, which reads US ZIP centres.
- `packaging/test_region_boxes.py` checks the padded box, that `eu-at` still uses the country extract, and that
  `build_map('AT-9')` cuts with that box and writes `map-set.json` with `name: "AT-9"`.

This branch does not publish `AT-9`. `packaging/state_maps.py` still lists only US states and opted-in countries, and
the country coverage guard from #84 remains separate. Publishing a subdivision needs the same coverage check against
a real source snapshot.

## How the region ID flows

1. `build_packs.py map AT-9` passes `AT-9` to `state_set()` with `subdivision_box('AT-9')`.
2. `build_map()` writes `map-set.json` with `"name": "AT-9"`. The hyphen and digit keep it apart from every two-letter
   US state code and from the `eu-<iso>` country codes.
3. A future publisher zips the set as `Lastbook-Map-AT-9.zip` and writes a manifest `maps` entry with `id: "AT-9"`.
   Setup already matches a map by `map-set.json`'s `name` to the entry's `id`, so `state.current.map` would report
   `AT-9` and nothing in setup needs a new code path for the ID.
4. The display name comes from the entry's `title` (`Wien (Vienna)` here), not from the code. Setup already shows the
   manifest title.

## How attribution would flow, and what is still missing

There is no place for attribution in a map set today:

- `map-set.json` is checked by `packaging/state_maps.py` and accepts only `name`, `files`, `bytes` and `seconds`.
- The manifest `maps` entry keeps `id`, `title`, `kind`, `includes`, sizes and files. `engine/setup/manifest.py`
  rebuilds entries from known fields, so an extra field is dropped before setup sees it.

So a real Austrian provenance record cannot simply be added to `map-set.json` or the manifest today; it would fail the
scan or disappear on validation. The flow that needs agreeing with @caeylin before code is:

1. The source-snapshot build writes one provenance record per layer (URL, licence, access date, SHA-256, credit line).
2. The map build copies that record into a new map-set field, for example `attribution`, and the scan's allowed set is
   widened by exactly that field.
3. The publisher copies the same record into the manifest entry, and `engine/setup/manifest.py` keeps it.
4. Setup shows it where the map already credits its sources; the app can read it from `map-set.json`.

None of steps 1 to 4 is in this branch. Until they land, an `AT-9` build would carry the same generic
`includes` text as a state and no Austrian credit, so it must not be published as an Austrian map.

## What the box does and does not mean

The box is an envelope, as a US state's box is. The `AT-9` box lies wholly inside the `AT-3` (Lower Austria) box, so a
Lower Austria set already contains Vienna's rows. The reverse is not true: `AT-9` holds Vienna and whatever else falls
inside its envelope, bounded by the source layers' coverage. The box says nothing about whether Vienna's streets,
buildings, terrain or help points exist in the source snapshot; that is exactly what the coverage check and @caeylin's
offline smoke test have to establish.
