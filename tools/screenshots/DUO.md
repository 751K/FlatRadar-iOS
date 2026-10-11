# iPhone Duo screenshots

The `FlatRadar` scheme offers two screenshot test plans:

| Test plan | Duo pose | Output |
| --- | --- | --- |
| `Screenshots` | Closed, portrait | 1398 × 2034 |
| `ScreenshotsDuoInner` | Fully open, landscape | 2853 × 2007 |

Select **iPhone Duo / iOS 27.1** and Xcode 27.1 or later in Xcode Cloud.
Each plan captures seven pages in five languages (35 PNGs). Both use the same
`UI_TEST_USERNAME` / `UI_TEST_PASSWORD` Cloud secrets; `ci_post_clone.sh` injects
them into the selected plan without putting credentials into the app bundle.

The inner plan sets `UI_TEST_DUO_INNER_LANDSCAPE=1`. The simulator test runner
posts Device Hub's hinge and orientation controls, including for Cloud simulator
clones, then selects the inner screen by its native pixel dimensions. A missing
inner framebuffer or an incorrect output size fails the test instead of silently
attaching another outer-screen screenshot.

`ScreenshotsDuoProbe` runs all seven pages in English before the full language
batch. `testCaptureDuoProbeLogin` remains available as a manual raw-display diagnostic. Cloud
build 432 confirmed that the initial orientation control produced a portrait
inner layout, app-window captures are black, and the physical inner PNG is rounded
down to 2006 × 2852.
Build 435 also confirmed that `XCUIDevice.orientation` reports a rotation without
changing the open screen. The native Device Hub `portrait` control produces the
wide inner pose; `landscape-left` stands the open phone upright. The capture posts
that control after the hinge settles, uses the physical inner screen, and copies
the last row/column to restore the missing pixel on each edge. The captured content
is not rescaled. The exported landscape image must be exactly 2853 × 2007.
The inner panel uses the opposite native rotation to iPad captures: render with
`.right` for Duo and retain `.left` for iPad (confirmed from build 444's pixels).
Keep each serialized HID payload alive until dispatch completes, and allow the
last event to be delivered before releasing the client. The automation proxy's
frame is unreliable on this headless simulator; inspect the physical capture.
Build 448 confirmed that the open phone's automation bridge cannot reliably find
the navigation tabs. Perform login, page selection, and selection assertions on
the closed cover first. Open the existing page only at capture time, allow it to
reflow, and capture the physical inner panel. Do not query the UI proxy after opening.

XCTest can encode even an opaque rendered image as RGBA. Before ASC upload, run
`swift tools/screenshots/export-opaque-png.swift path/to/screenshots/*.png` on macOS.
The exporter rejects actual transparency and writes RGB PNGs without resizing.
Build 451's seven pages were verified pixel-for-pixel against the RGBA originals
after export; dimensions remain 2853 × 2007.

`DuoPose.c` is exclusively in `FlatRadarUITests`; its simulator HID calls are not
linked into the shipping app. The hinge control is adapted from the MIT-licensed
[hinge](https://github.com/artemnovichkov/hinge) tool; see [hinge-LICENSE](hinge-LICENSE).
