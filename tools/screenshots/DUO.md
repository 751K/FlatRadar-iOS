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

`ScreenshotsDuoProbe` runs only the English login page and includes raw physical
screens, the app-window screenshot, and the final export for diagnosis. Cloud
build 432 confirmed that opening the hinge resets orientation, app-window
captures are black, and the physical inner PNG is rounded down to 2006 × 2852.
The capture now rotates after opening, uses the physical inner screen, and copies
the last row/column to restore the missing pixel on each edge. The captured content
is not rescaled. The exported landscape image must be exactly 2853 × 2007.

`DuoPose.c` is exclusively in `FlatRadarUITests`; its simulator HID calls are not
linked into the shipping app. The hinge control is adapted from the MIT-licensed
[hinge](https://github.com/artemnovichkov/hinge) tool; see [hinge-LICENSE](hinge-LICENSE).
