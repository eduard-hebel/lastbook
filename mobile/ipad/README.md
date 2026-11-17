# Lastbook for iPad (development preview)

A native iPad app for the Lastbook offline survival library: **Videos, Map and Chat**, working offline from a library stored
on the iPad. This is **source for contributors**, not a release.
- It is not in the App Store or TestFlight, and no iPad build is published.
- To try it, you build and sign it yourself with Xcode and install it on your own iPad.

Licence: MIT, like the rest of this repository (see [`/LICENSE`](../../LICENSE)). Third-party parts are listed in
[`/THIRD_PARTY_NOTICES.md`](../../THIRD_PARTY_NOTICES.md), in the section "iPad development preview".

## What works

- **Videos:** a native home feed, categories, search and a watch page. The watch page has the system player (Picture in Picture), a searchable transcript and Up next.
- **Map:** the offline map from the desktop app: streets for the chosen state, help and resource points, place search and street-address search.
- **Chat:** answers from the library with numbered citations that open the exact PDF page or video moment.
  - With the optional local AI (Gemma 4 26B A4B, or the small LFM2.5 2.6B, run in-process by llama.cpp), Chat writes cited answers.
  - Without the local AI, Chat shows the library pages that match.
- **Reading:** PDF pages drawn natively, so no PDF reaches the web view, plus saved web pages, transcripts and keyword search.
- **Setup inside the app:**
  1. Choose a library size: Small is the default.
  2. Choose your state: required; Lastbook never looks up your location.
  3. Tap Install once. It downloads and installs the library, the state map, that state's street addresses, and, where supported and chosen, the local AI.

  Downloads can be cancelled and resumed, and each is checked by SHA-256. The space needed is shown first. You can also bring a library in from Files instead.
- **A "what's ready" notice** lists anything not yet installed, so a partial setup never looks complete.

## How it works

- **The app:** a SwiftUI app (`Lastbook/Design/` for the screens, `Lastbook/Shell/` for the app shell).
- **The engine:** the desktop engine's routes (`server.py`, `engine/library.py`, `retrieval.py`, the map code) ported to Swift (`Lastbook/Engine/`, `Lastbook/API/`). It reads the **same library files** as the desktop app: `library-data/` and `derived/geo/*.sqlite`.
- **No server:** requests go to the engine in-process. The web parts (map and reader pages, from the repository's `web/`, copied in at build time) use a `lastbook://` URL scheme handler. There is no network port.
- **Videos in AV1 or VP9:** if this iPad's own decoder can't play a video's format, the video plays from an H.264 copy (`Engine/VideoCompat.swift`). The decision is a real check on each iPad, its decoder plus one decoded frame, never a list of models. The video keeps its id, transcript and seeking.
- **The local AI:** llama.cpp at the same pinned commit as the desktop runner, built from source into a static library (`scripts/build_llama_ios.sh`, `llm/`). It runs with no network and no port.
  - It loads in the background when the app opens, and is freed when the app goes to the background or on a memory warning.

## Network use

Lastbook reaches the network only when the person starts a download in the install screen:
- library packs, maps and addresses from `downloads.lastbook.org`;
- the AI model from Hugging Face, the same hosts as desktop setup.

Each download is HTTPS with the system's certificate check plus pinned root certificates, and is checked by SHA-256. Otherwise there is no network use at all: no analytics, no location lookup and no cloud AI. A web link opens Safari only after the person agrees.

## Current limitations

- **Development preview.** The local AI has run with the Small library on one physical iPad Pro (M1, 16 GB). Other iPads and longer use are untested.
- **Local AI memory:** the Gemma model file is 17 GB. Setup turns it on by default only on iPads with 16 GB-class memory, and marks smaller iPads "not tested". Lastbook checks the fit after the file is in place. The small model (LFM2.5 2.6B, a 1.6 GB file, about 2 GB of memory with its context) is the one that can fit a phone; it is recognised wherever the big one is, but it has not run on a physical device yet.
- **Encyclopedias (ZIM files) don't open on iPad yet:** there is no ZIM reader in the app. The rest of the library works.
- **H.264 video copies** (for iPads that can't play a video's AV1 or VP9 format) are not on the download site for any pack yet.
  - Build them with `tools/videocompat` and `tools/make_video_copies_zip.py`, then import the zip from Files.
  - The install screen says so. On such iPads, those videos are listed as not ready.
  - iPads that play the original formats don't need copies.
- **Medium and All need a lot of space.**
  - Medium needs about 136 GB free during install.
  - All needs about 776 GB free during install, so a 1 TB-class iPad.
  - These two packs haven't been installed end to end on an iPad yet.
- **Downloads pause** when Lastbook leaves the screen. They resume, with Retry, from where they stopped.

## Build

You need:
- an **Apple silicon Mac** with Xcode. It was built and tested with Xcode 27 beta; older Xcode versions are untested. The deployment target is iPadOS 18.
- CMake 3.28 or later and git, for the local AI runtime;
- an iPad on iPadOS 18 or later.

Get the pinned llama.cpp source (once; Xcode never downloads code):

```bash
cd mobile/ipad
bash scripts/prepare_dependencies.sh
```

It clones llama.cpp at `dde879bc4f954b809892fd0d660515f42536394a` into `build/deps/llama.cpp`, which is git-ignored. The
build refuses a different or modified checkout. To use a checkout you already have at that commit, set `LLAMA_SRC`.

Unsigned builds, to check that everything compiles:

```bash
xcodebuild -project Lastbook.xcodeproj -scheme Lastbook -destination 'generic/platform=iOS Simulator' -derivedDataPath build/dd CODE_SIGNING_ALLOWED=NO build
```

```bash
xcodebuild -project Lastbook.xcodeproj -scheme Lastbook -configuration Release -destination 'generic/platform=iOS' -derivedDataPath build/dd CODE_SIGNING_ALLOWED=NO build
```

**To run on your iPad,** open `Lastbook.xcodeproj` and set your own team and bundle identifier. Put local overrides in
`Local.xcconfig`, which is git-ignored, for example `DEVELOPMENT_TEAM = ABCDE12345` and `PRODUCT_BUNDLE_IDENTIFIER = com.example.lastbook`.

The local AI uses the `com.apple.developer.kernel.increased-memory-limit` and
`com.apple.developer.kernel.extended-virtual-addressing` entitlements (`Lastbook.entitlements`), so your provisioning profile
must include them. Without them, the rest of the app works.

**A library for testing:** use the app's Install screen, or copy a desktop `LastbookData` folder (from a pack on
lastbook.org) into Files › On My iPad › Lastbook.

## Tests and tools (Mac)

Run these from `mobile/ipad`.

**Installer fixture tests.** No downloads or devices.

```bash
bash tools/build_mediumalltest.sh && build/mediumalltest
```

This plans and checks Small, Medium and All installs against tiny fixtures; the current result is 32 pass. `tools/build_installtest.sh` builds `build/installtest`, which runs single plan, install and download steps.

**Parity with the desktop engine.**
1. Put a test copy of a `LastbookData` folder at `build/LastbookData`.
2. Build the tool: `bash tools/build_apidump.sh`.
3. From the repository root, run the desktop server against that copy: `python3 server.py --data mobile/ipad/build/LastbookData --port 8960 --no-index`.
4. From `mobile/ipad`, compare: `python3 tools/compare.py -f tools/parity-map.txt`, and likewise for `parity-library`, `parity-videos` and `parity-pages`.

**Video copies.** `tools/videocompat` builds H.264 copies of a library's AV1 and VP9 videos.
- AV1 is decoded by Apple's frameworks. VP9 is decoded by an ffmpeg you supply (`--ffmpeg`); none is bundled or downloaded.
- `tools/validate_videocompat.py` checks the copies with ffmpeg.

**The local AI.** `bash tools/run_ai_regression.sh MODEL_FOLDER` runs the local-AI scenarios on a Mac against the model file, which is read only.

Never commit build output, libraries, model files, signing files or `Local.xcconfig`. The `.gitignore` here excludes them.
