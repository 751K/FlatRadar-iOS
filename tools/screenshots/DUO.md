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

`DuoPose.c` is exclusively in `FlatRadarUITests`; its simulator HID calls are not
linked into the shipping app. The hinge control is adapted from the MIT-licensed
[hinge](https://github.com/artemnovichkov/hinge) tool; see [hinge-LICENSE](hinge-LICENSE).
