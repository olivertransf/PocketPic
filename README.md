# PocketPic

A daily photo journal for iPhone, iPad, and Mac. Capture one photo per day with a live alignment overlay, then export a time-lapse montage with optional on-device eye alignment.

[Website](website/) · [Privacy Policy](website/privacy.html) · [Support](website/support.html)

## Why PocketPic

Long-running photo projects fall apart when framing drifts. PocketPic ghosts your previous shot over the viewfinder so you can match pose and angle day after day, then turns the series into a shareable video in a few taps.

## Features

- **Daily capture** — full-screen camera on iOS; menu bar quick-shot on macOS
- **Alignment overlay** — previous photo on the viewfinder with adjustable opacity
- **Time-lapse export** — H.264 (1080p) or HEVC (native resolution), 5–60 fps
- **Eye alignment** — optional Vision-powered face alignment during export (on-device)
- **Photo library** — month-grouped mosaic, streak tracking, full-screen zoom viewer
- **PhotoKit sync** — saves to a configurable album (default `PocketPic`)
- **Privacy mode** — hide in-app thumbnails without deleting photos from your library
- **Bulk actions** — multi-select and delete

## Screenshots

_Add App Store screenshots here after capture._

## Getting started

### Requirements

- Xcode 16+
- iOS 18+ or macOS 15+

### Build and run

```bash
git clone https://github.com/olivertransf/PocketPic.git
cd PocketPic
open PocketPic.xcodeproj
```

Select an iPhone, iPad, or Mac destination in Xcode and run. Camera and Photos permissions are requested on first use.

### Bundle identifier

`com.olivertran.PocketPic` — update signing in Xcode with your own team before distributing.

## Project structure

```
PocketPic/
├── PocketPic/           # SwiftUI app source
├── PocketPic.xcodeproj/
├── website/             # Static marketing site (App Store + Vercel)
└── LICENSE
```

## Website

The `website/` folder is a static site for App Store Connect (marketing, privacy, support). Deploy with Vercel:

| Setting | Value |
|---------|-------|
| Root Directory | `website` |
| Build Command | *(empty)* |
| Output Directory | `.` |

## Tech stack

| Area | Technology |
|------|------------|
| UI | SwiftUI |
| Camera | AVFoundation |
| Export | AVFoundation (`AVAssetWriter`) |
| Photos | PhotoKit |
| Face alignment | Vision (`VNDetectFaceLandmarksRequest`) |

## Privacy

PocketPic does not collect analytics or transmit your photos to external servers. Camera and Photos access are used only for capture, display, and export. Face analysis for eye alignment runs entirely on your device. See the [privacy policy](website/privacy.html) for details.

## License

MIT — see [LICENSE](LICENSE).
