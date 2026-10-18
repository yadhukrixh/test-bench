# ADR 0002: App Sandbox off

Date: 2026-10-14. Status: accepted.

The App Sandbox is off. The app launches the Android emulator, adb, simctl, and Flutter, and it reads the Android SDK directory outside the container. A sandboxed app cannot do that without temporary exceptions that still break developer tools.

Distribution will be a Developer ID signed disk image, not a Mac App Store build. That signing work is Phase 9. Local builds may be ad-hoc signed so the bundle opens on this machine.

The sandbox stays off until a design exists that can launch those tools without it. No such design is in scope for v1.
