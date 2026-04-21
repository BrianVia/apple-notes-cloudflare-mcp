# Apple clients — macOS (and, later, iOS)

This is the SwiftUI side of notekeeper. It's structured in two units:

- **`NotekeeperCore/`** — a Swift Package (SPM) with `APIClient`, Codable
  `Models`, and a Keychain-backed `CredentialStore`. Pure library. Both the
  Mac and future iOS apps depend on it. Can be built without Xcode via
  `swift build`.
- **`NotekeeperMac/`** — a SwiftUI macOS app target. Its Xcode project is
  generated from `project.yml` via [XcodeGen](https://github.com/yonaskolb/XcodeGen)
  — no binary `.xcodeproj` is checked in.

iOS target will follow the same shape once the Mac app is proven (roadmap P1).

## Prerequisites

- macOS 14+ (Sonoma)
- Xcode 15.4+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`

## Build & test the core package (no Xcode required)

```bash
cd apps/apple/NotekeeperCore
swift build          # compiles the library
swift test           # runs the decoding tests
```

The tests decode live-shape payloads copied from real server responses, so
they catch schema drift between the Worker and this client.

## Generate and run the Mac app

```bash
cd apps/apple/NotekeeperMac
xcodegen generate    # produces NotekeeperMac.xcodeproj from project.yml
open NotekeeperMac.xcodeproj
```

In Xcode:

1. Select the `NotekeeperMac` scheme and the `My Mac` run destination.
2. In the target's **Signing & Capabilities** pane, pick your personal team
   (automatic signing). The entitlements file already declares the App
   Sandbox and network-client capabilities; no Developer Program membership
   is needed for local runs.
3. ⌘R to launch.

On first launch click **Connect** in the toolbar and paste:

- Endpoint: `https://notekeeper.brian-via.workers.dev`
- API key: the `nk_live_…` token from the dev bootstrap

Credentials are stored via the Keychain (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`)
so subsequent launches reconnect automatically. Use **Disconnect** to forget
them.

## What the scaffold covers today

- **Connect / disconnect** with Keychain persistence
- **Note list** — pulls `GET /v1/notes`, re-pulls on `refreshable` gesture
- **Create note** (⌘N) — posts an untitled draft
- **Edit & save** — PATCH the whole body on ⌘S. Marks "Unsaved changes" in
  the editor footer when `draftBody != lastSavedBody`.
- **Soft-delete** — `model.trashSelected()` is wired up but no UI button yet
  (add a keyboard shortcut or context menu when you dogfood it).

## What's explicitly NOT covered (yet)

- **Live CRDT sync.** The editor PATCHes the whole body. The DO sync protocol
  (the 3-byte SYNC_STEP_1 / SYNC_STEP_2 / UPDATE that `apps/api/src/do/note-do.ts`
  speaks) is future work — it needs the Swift Yjs port (`yswift`) added as a
  package dependency. Track roadmap P1 "CRDT sync".
- **Rich markdown rendering.** Editor is a plain `TextEditor` over the raw
  markdown. Inline formatting (hiding `#` syntax, rendering checkboxes) is
  roadmap P1 "macOS UI".
- **Folders, tags, search, pin/unpin, trash view.** The API client exposes
  all of them (`listFolders`, `search`, etc.); they're not wired to UI yet.
- **iOS target.** `NotekeeperCore` already builds for iOS 17+; create
  `NotekeeperIOS/project.yml` when ready.

## Structure

```
apps/apple/
├── NotekeeperCore/
│   ├── Package.swift
│   ├── Sources/NotekeeperCore/
│   │   ├── APIClient.swift
│   │   ├── Models.swift
│   │   ├── CredentialStore.swift
│   │   └── NotekeeperError.swift
│   └── Tests/NotekeeperCoreTests/
│       └── ModelsTests.swift
└── NotekeeperMac/
    ├── project.yml            # XcodeGen spec
    ├── NotekeeperMac.entitlements
    └── Sources/
        ├── NotekeeperMacApp.swift
        ├── AppModel.swift
        └── RootView.swift
```

## Gitignore

Generated files — add these to `.gitignore` if not already:

```
apps/apple/**/*.xcodeproj
apps/apple/**/.build
apps/apple/**/.swiftpm
apps/apple/**/DerivedData
```
