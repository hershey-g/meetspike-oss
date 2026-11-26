# iPhone simulator review screenshots

Captured from the native Debug app with synthetic fixtures on iOS 26.3.1, using Xcode 26.3. These are app screenshots, not design mockups. No real calendar events, heart-rate data or credentials are shown.

The small device is iPhone SE (3rd generation), 750 × 1334 pixels. The large device is iPhone 17 Pro Max, 1320 × 2868 pixels. Every listed state is captured in both appearances on both devices. Maximum text means the largest accessibility Dynamic Type category. Long screens have separate top, chart, sync and settings captures; content scrolls within safe areas.

Reproduce with `ios/capture-screenshots.py` after generating and building the Debug simulator app, as described in [the iPhone README](../../../ios/README.md). Capture runs headlessly with simctl; it does not open Simulator.app. `--only` can refresh selected state names and `--skip-install` reuses an already installed matching Debug build.

| State | SE dark | SE light | Pro Max dark | Pro Max light |
| --- | --- | --- | --- | --- |
| Live heart rate and active meeting | [PNG](se-dark-live.png) | [PNG](se-light-live.png) | [PNG](pro-max-dark-live.png) | [PNG](pro-max-light-live.png) |
| No upcoming meetings | [PNG](se-dark-empty.png) | [PNG](se-light-empty.png) | [PNG](pro-max-dark-empty.png) | [PNG](pro-max-light-empty.png) |
| Chart, summary and successful sync | [PNG](se-dark-chart-sync.png) | [PNG](se-light-chart-sync.png) | [PNG](pro-max-dark-chart-sync.png) | [PNG](pro-max-light-chart-sync.png) |

### Companies

| State | Dark |
| --- | --- |
| Companies list, synthetic example companies | [PNG](companies-list-dark.png) |

The fixtures cover display and layout. Real WHOOP radio connectivity, lock-screen delivery, permission prompts, notification delivery, network recovery against the configured server and battery use still require a signed build on a physical iPhone.
