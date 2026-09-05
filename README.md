# FlatRadar for iOS

[![App Store](https://img.shields.io/badge/App_Store-Download-0D96F6?style=flat-square&logo=appstore&logoColor=white)](https://apps.apple.com/us/app/flarradar/id6769857080)
[![iOS Tests](https://img.shields.io/github/actions/workflow/status/751K/FlatRadar-iOS/ios.yml?style=flat-square&label=tests)](https://github.com/751K/FlatRadar-iOS/actions/workflows/ios.yml)
[![Platform](https://img.shields.io/badge/iOS-18.0%2B-000000?style=flat-square&logo=apple&logoColor=white)](https://developer.apple.com/ios/)
[![SwiftUI](https://img.shields.io/badge/SwiftUI-Swift_6-FA7343?style=flat-square&logo=swift&logoColor=white)](https://developer.apple.com/xcode/swiftui/)
[![Backend](https://img.shields.io/badge/backend-holland2stay--monitor-0057CC?style=flat-square&logo=github)](https://github.com/751K/holland2stay-monitor)
[![License](https://img.shields.io/badge/license-PolyForm%20Noncommercial%201.0.0-blue?style=flat-square)](https://github.com/751K/holland2stay-monitor/blob/master/LICENSE)

The iOS client for [FlatRadar](https://flatradar.app), a monitor for the Dutch
rental market. It watches seven platforms — Holland2Stay, OurDomain, OurCampus,
Xior, Magis, Plaza and Student Experience — and pushes a notification the moment
a listing matches what you are looking for.

The scraping, matching and notification pipeline lives in the backend repo,
[751K/holland2stay-monitor](https://github.com/751K/holland2stay-monitor). This
repo is the app that sits in front of it.

## What it does

- **Dashboard** — supply and price trends across the platforms you follow.
- **Browse** — listings, map and availability calendar. Three tabs on iPad,
  one segmented tab on iPhone.
- **Filters** — 13 dimensions (city, price, rooms, contract, energy label,
  furnishing, …). Not every platform reports every dimension, so the app tells
  you when a filter only narrows some of the platforms you have selected.
- **Alerts** — APNs push for new matches, plus a live in-app feed over SSE.
- **Deep links** — a notification opens straight to the listing, on the list or
  on the map.
- **Face ID / Touch ID** sign-in, guest browsing, and admin tools for
  self-hosters.

Runs on iPhone and iPad. English, 简体中文, 繁體中文, Nederlands and Español.

## Requirements

- iOS 18.0+
- Xcode 26 (a **GM** release — Apple rejects builds made with a beta Xcode)

## Build

```bash
git clone https://github.com/751K/FlatRadar-iOS.git
cd FlatRadar-iOS
open FlatRadar.xcodeproj
```

Run the `FlatRadar` scheme. The app talks to `flatradar.app` by default; point
it at your own deployment from Settings.

## Layout

```text
FlatRadar/          App source — Models, Networking, Stores, Navigation, Push, Views
FlatRadarTests/     Unit tests
FlatRadarUITests/   UI tests, including the App Store screenshot automation
scripts/            Simulator selection, xcresult parsing, screenshot extraction
tests/              pytest for scripts/ and for the CI configuration itself
tools/asc/          App Store Connect API tooling
ci_scripts/         Xcode Cloud hooks — must sit next to the .xcodeproj
```

## Testing

```bash
xcodebuild test -project FlatRadar.xcodeproj -scheme FlatRadar \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
python3 -m pytest      # scripts/ and the CI configuration
```

The pytest suite is not incidental. It guards the parts of the build that fail
*quietly* — for example that the scheme's default test plan still contains the
unit test target. Without that check `xcodebuild test` will happily print
`Test Succeeded` after executing zero tests, which is what it did for a while.

## CI

| Workflow | Trigger | What it does |
|---|---|---|
| `ios.yml` | every push / PR | unit tests, and asserts they actually ran |

Builds are **not** produced here. `release.yml` existed for that and never once
worked: cloud signing could not mint a distribution identity for this account,
so `xcodebuild -exportArchive` failed with `Cloud signing permission error` on
its only real run — after quietly creating a throwaway development certificate
against the account's quota. Xcode Cloud already produces shippable builds
(255/256 shipped 2.0.0), so that workflow was deleted rather than repaired.

App Store screenshots are **not** built here. They run on **Xcode Cloud**, which
does the same suite roughly an order of magnitude faster than a GitHub runner
(1m28s for seven cases against tens of minutes) and picks its devices from its
own workflow configuration. The GitHub workflow that used to do it is gone;
`scripts/xcode_cloud.py` is the entry point that replaced it:

```bash
python3 scripts/xcode_cloud.py run --wait     # trigger a screenshot build
python3 scripts/xcode_cloud.py status 265     # per-case, per-device results
python3 scripts/xcode_cloud.py fetch  265     # download and extract the PNGs
```

Credentials reach the tests through `ci_scripts/ci_post_clone.sh`, which writes
them into the test plan: Xcode Cloud refuses environment variables named
`TEST_RUNNER_*`, and `xcodebuild` forwards only variables with exactly that
prefix. The script explains the whole knot.

## The contract with the backend

One file connects the two repos: `docs/openapi.json` in the backend.

Before the split, changing an endpoint and changing the client were the same
commit. They are not any more — the backend can add a field or rename an enum
and nothing here reacts until runtime. So the backend derives its route set from
the live Flask app and diffs it against that spec in both directions: a route
the spec is missing fails, and a route the spec invents fails too. **Treat that
spec as the source of truth**, and it will tell you when it falls behind.

## Security

The repo is public and holds no credentials. `ios.yml` needs none. Everything
that does need them runs elsewhere: Xcode Cloud reads its own secret environment
variables, and local tooling (`tools/asc/`, `scripts/xcode_cloud.py`) reads
`~/.config/asc/`. There are deliberately **no** App Store Connect secrets in this
repo's GitHub Secrets — nothing here would consume them, and a stored copy that
nothing reads is a copy that can silently drift from the one that matters.

One silent failure mode is worth knowing about. When the screenshot tests find no
credentials they fall back to guest mode rather than failing, so a missing or
wrong credential yields a fully green run with the Alerts screen quietly absent —
guests have no Alerts tab. There used to be a workflow that logged in to check
for exactly that; it was deleted once screenshots moved to Xcode Cloud, because
it read *this* repo's copy of the credentials while the run used Xcode Cloud's,
so its green stopped meaning anything. The guard that does hold is inside the
suite: `testCapture05_Notifications` asserts the Alerts tab is the selected one,
which cannot pass in guest mode.

## Contributing

The app is feature-complete for the current product scope and is maintained
rather than actively expanded: compatibility with new iOS and Xcode releases,
crash and contract fixes, App Store metadata, and small UI work that keeps
parity with the other clients. New cross-platform behaviour is specified in the
backend's `docs/API.md` first, then implemented on each client.

Two conventions worth knowing before you send a patch:

- Listing and chart models must tolerate unknown fields. A new backend field
  should not require an iOS release unless the UI wants to show it.
- Legal text comes from the backend; the copy bundled in the app is only a
  fallback.
