# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

PocketPic is a SwiftUI photo app for iOS, iPadOS, and macOS (via Mac Catalyst) that helps users capture consistent selfies over time. The core feature is showing a faint overlay of the last photo in the camera viewfinder to help users frame shots identically. Photos can be exported as a timelapse MP4 video with optional eye-alignment stabilization.

- **Targets**: iOS 18+, macOS 15+ (`TARGETED_DEVICE_FAMILY = "1,2,6"`)
- **Bundle ID**: `com.olivertran.PocketPic`
- **Swift version**: 5.0

## Build & Run

This is a pure Xcode project — open `PocketPic.xcodeproj` in Xcode and run the `PocketPic` scheme on a device or simulator. There is no CLI build system, test runner, or package manager.

There are no automated tests in this project currently.

## Architecture

The app has a flat file structure with no subdirectories. All source files live in `PocketPic/`.

**Data flow**: `PhotoStore` (ObservableObject) is instantiated in `ContentView` and passed down via `@EnvironmentObject`. It owns all photo state and persistence.

### Key files

| File | Role |
|------|------|
| `ContentView.swift` | Root TabView (Gallery / Camera / Settings). Manages `showCamera` state and presents `CameraView` as fullScreenCover (iOS) or sheet (macOS). |
| `PhotoStore.swift` | Single source of truth for the photo list. Loads from the Photos library album first, falls back to local JSON metadata. Handles save, delete, thumbnail/full-image async loading. |
| `CameraView.swift` | Camera UI. Wraps `CameraController` (AVFoundation session manager). Loads the last photo as an overlay preview. |
| `OverlayView.swift` | Semi-transparent image overlay rendered on top of the camera feed. |
| `GalleryView.swift` | Lazy grid of thumbnails with multi-select, delete, and export actions. |
| `ExportViewModel.swift` | Builds an MP4 using AVAssetWriter. Optionally aligns frames by eye position via `EyeDetectionService`. Supports H.264 (standard) and HEVC (native resolution mode). |
| `EyeDetectionService.swift` | Uses Vision framework (`VNDetectFaceLandmarksRequest`) to locate eyes in an image, returning `EyeLocations` in image-pixel coordinates. |
| `ExportView.swift` | Sheet UI for export options (FPS picker, eye-align toggle, share/save). |
| `SettingsView.swift` | Album picker, overlay opacity slider, native-resolution toggle, hide-photos-in-gallery toggle. |
| `PlatformCompatibility.swift` | `typealias PlatformImage = UIImage / NSImage` and shared `Color` extensions (`appAccent`, `systemBackground`, `systemGroupedBackground`). |

### Cross-platform pattern

Every file uses `#if canImport(UIKit) / canImport(AppKit)` guards for platform-specific code. **Always use `PlatformImage` instead of `UIImage`/`NSImage` directly.** Platform-specific UI (e.g. `NSSavePanel`, `UIActivityViewController`) must be wrapped in the appropriate conditional compilation block.

### Photo storage

Photos are saved in two places simultaneously:
1. **Local disk** — JPEG files in `Documents/PocketPicPhotos/` with a UUID filename; metadata persisted to `Documents/photos_metadata.json`.
2. **Photos library** — saved to a named album (default: "PocketPic") via `PHPhotoLibrary`.

On launch, `PhotoStore` prefers reading from the Photos library album; it falls back to local JSON metadata if Photos access is denied.

`Photo.filename` doubles as the `PHAsset.localIdentifier` when a photo comes from the Photos library, and as a UUID-based filename when stored locally.

### Video export

`ExportViewModel.exportVideo` runs on `@MainActor` but delegates all encoding to `Task.detached`. Eye alignment (`makeAlignedPixelBuffer`) applies a `CGAffineTransform` (translate → rotate → scale) to align each frame's eyes to the reference frame's eye positions. Falls back to unaligned rendering if Vision can't detect eyes.
