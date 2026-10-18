# ADR 0001: Native Swift

Date: 2026-10-14. Status: accepted.

The owner confirmed the recommended stack after Phase 0.

QA Workbench is one native macOS app written in Swift 6, with SwiftUI and AppKit only in the app target. Device and tool access lives in local packages behind protocols. The app spawns adb, the emulator, simctl, and later Flutter, as child processes.

Tauri with a React UI was the alternative. Frames, Vision, Translation, and ScreenCaptureKit still need an AppKit or SwiftUI host, so that UI would not remove the Swift work. Phase 0 did not find a reason to leave the native process.

Consequences: the deployment target is macOS 15, the language mode is Swift 6, and only the app target imports SwiftUI.
