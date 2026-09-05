# FlatRadar iOS Maintenance Notes

The iOS app is feature-complete for the current FlatRadar product scope and is now in maintenance mode. Large feature development has moved to backend reliability and multi-platform data quality.

For the Android client — its status, distribution, and roadmap — see [ANDROID_PLAN.md](https://github.com/751K/FlatRadar-Android/blob/master/docs/ANDROID_PLAN.md) in [FlatRadar-Android](https://github.com/751K/FlatRadar-Android). This document is iOS only.

[Download on the App Store](https://apps.apple.com/us/app/flarradar/id6769857080)

## Current Scope

- Native SwiftUI app at the root of this repository, under `FlatRadar/`.
- Connects to the shared Flask API under `/api/v1/*`.
- Supports admin, user, and guest roles.
- Covers Dashboard, Listings, Listing Detail, Map, Calendar, Notifications, Settings, Admin tools, legal pages, and StoreKit coffee donations.
- Uses APNs for iOS push notifications and SSE for live in-app updates.
- Conditional GET caching (URLCache 2MB memory + 20MB disk) against the backend's ETag / 304 support.
- Performance work worth preserving: static `DateFormatter` instances, pre-normalized `featureMap` keys, a non-blocking notification first screen, and map clustering off the main actor.
- Localized into English (source), 简体中文, 繁體中文, Nederlands and Español, through `FlatRadar/Localizable.xcstrings`.

## Maintenance Policy

iOS should now receive:

- compatibility fixes for new iOS / Xcode releases;
- crash, navigation, notification, and API contract fixes;
- App Store metadata, privacy, and legal text updates;
- small UI polish that keeps parity with the shared product;
- security and dependency hygiene.

iOS should not be the default place for large new product experiments. New cross-platform behavior should first be specified in the backend's [API.md](https://github.com/751K/holland2stay-monitor/blob/master/docs/API.md) and then implemented consistently across Web, Android, and iOS as needed.

## Quick Start

```bash
git clone https://github.com/751K/FlatRadar-iOS.git
cd FlatRadar-iOS
open FlatRadar.xcodeproj
```

Run the `FlatRadar` scheme on a simulator or physical device. The app connects to `flatradar.app` by default; point it at another deployment from Settings.

## Architecture Pointers

```text
FlatRadar/
├── FlatRadarApp.swift          # app entry, environment injection
├── Models/                     # Codable API models and display helpers
├── Networking/                 # APIClient, APIError, SSE, Keychain, biometrics
├── Stores/                     # @Observable state and business logic
├── Navigation/                 # tab/path/deep-link coordination
├── Push/                       # APNs delegate bridge
├── Diagnostics/                # MetricKit crash/hang collection and upload
└── Views/                      # SwiftUI screens
```

The API contract lives in the backend repo, not here: [API.md](https://github.com/751K/holland2stay-monitor/blob/master/docs/API.md) is the human-readable version and [openapi.json](https://github.com/751K/holland2stay-monitor/blob/master/docs/openapi.json) the machine-readable one shared by iOS and Android. Treat the spec as the source of truth — the backend diffs it against its live route set in both directions, so it tells you when it falls behind.

## Release Checklist

- Build with the current stable Xcode.
- Verify login, guest mode, listings/detail, map, calendar, notifications, settings, legal pages, and account deletion.
- Verify APNs registration, foreground notification handling, and notification deep links on a physical device.
- Confirm `PrivacyInfo.xcprivacy`, App Store privacy answers, support URL, terms, and privacy policy still match current behavior.
- Run the iOS unit test target when touching models, stores, navigation, networking, or push behavior.
- Run `python3 -m pytest`. It checks the repo's own build configuration — the Swift language mode, the version numbers in the pbxproj, the dark AppIcon, the screenshot upload plan — the parts that fail without saying so.

## Ownership Notes

- Legal text is no longer maintained as an iOS-only source of truth. The backend legal API is canonical, with local app text used only as fallback.
- Listing and chart models should tolerate unknown fields. Backend additions should not require an iOS release unless the UI needs to expose the new data.
- APNs remains iOS-specific, but device registration uses the shared `platform` field so backend push routing can coexist with Android FCM.
