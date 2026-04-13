# iOS Distribution App — Plan 3 of 3: iOS App

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** SwiftUI iOS app (iOS 17+) that reads shorts from Supabase, lets the user edit captions + thumbnail, and shares via native share sheet. Two-user app (Tadiwa + Elvis) with no sign-in screen. The app ships with the Supabase `anon` key only.

**Architecture:** Single SwiftUI target. Supabase Swift SDK for DB + Storage. AVKit for playback. Core Graphics for live thumbnail rendering. `URLCache` (2GB) for video caching. Settings JSON is source of truth for thumbnail — PNG is only rendered on-demand for sharing.

**Tech Stack:** Swift 5.9, SwiftUI, iOS 17+, `supabase-swift`, AVKit, Core Graphics.

**Reference spec:** `docs/superpowers/specs/2026-04-12-ios-distribution-app-design.md`

**Reference plans:** Plan 1 (Supabase backend) and Plan 2 (Mac uploader) must be complete and exporting real data into Supabase.

---

## File Structure

All files under `VideoEditor/iOSApp/` (new directory at repo root alongside existing Mac project).

```
VideoEditor/iOSApp/
├── iOSApp.xcodeproj                           (XcodeGen-generated)
├── project.yml                                 (XcodeGen source)
├── Package.resolved                            (swift-package-manager deps)
├── Info.plist
├── Config/
│   └── Config.swift                            # Supabase URL + service key + static brand palette
├── App/
│   ├── ShortsDistributionApp.swift             # @main
│   └── AppState.swift                          # observable global state, cache manager
├── Models/
│   ├── Short.swift                             # Swift model for shorts row
│   ├── Caption.swift
│   ├── ThumbnailSettings.swift
│   └── Platform.swift                          # enum with all 5 platforms
├── Networking/
│   ├── SupabaseClient.swift                    # Thin wrapper around supabase-swift (anon key only)
│   └── EdgeFunctions.swift                     # regenerate-caption client
├── Cache/
│   ├── VideoCache.swift                        # URLCache config, 2GB quota
│   └── FrameCache.swift                        # NSCache for candidate JPG data
├── Rendering/
│   └── ThumbnailCompositor.swift               # Core Graphics pill+logo render
├── Views/
│   ├── LibraryView.swift                       # Home grid
│   ├── LibraryCell.swift                       # Grid cell thumbnail+label
│   ├── DetailView.swift                        # Tabs host
│   ├── VideoPlayerView.swift                   # AVKit wrapper
│   ├── ThumbnailEditorView.swift               # Text/color/position/frame pickers
│   ├── CaptionEditorView.swift                 # 5-tab segmented control
│   ├── ShareButton.swift                       # Share sheet trigger
│   └── SettingsView.swift                      # Cache + status
└── Resources/
    ├── Assets.xcassets                         # App icon, logo asset
    └── technolgia_logo_tight.png               # Bundled logo for pill rendering
```

---

## Task 1: Create Xcode project via XcodeGen

**Files:**
- Create: `VideoEditor/iOSApp/project.yml`
- Create: `VideoEditor/iOSApp/Info.plist`

- [ ] **Step 1: Write the XcodeGen config**

Create `VideoEditor/iOSApp/project.yml`:

```yaml
name: ShortsDistribution
options:
  bundleIdPrefix: com.videoeditor
  deploymentTarget:
    iOS: "17.0"
configs:
  Debug: debug
  Release: release
packages:
  Supabase:
    url: https://github.com/supabase/supabase-swift
    from: "2.0.0"
targets:
  ShortsDistribution:
    type: application
    platform: iOS
    sources:
      - path: App
      - path: Config
      - path: Models
      - path: Networking
      - path: Cache
      - path: Rendering
      - path: Views
      - path: Resources
    resources:
      - path: Resources/Assets.xcassets
      - path: Resources/technolgia_logo_tight.png
    info:
      path: Info.plist
      properties:
        CFBundleDisplayName: TechNolgia
        UILaunchStoryboardName: ""
        UIApplicationSceneManifest:
          UIApplicationSupportsMultipleScenes: false
          UISceneConfigurations: {}
        NSPhotoLibraryAddUsageDescription: "Save shorts to Photos for sharing"
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.videoeditor.shorts
        TARGETED_DEVICE_FAMILY: "1,2"
        SWIFT_VERSION: 5.9
        IPHONEOS_DEPLOYMENT_TARGET: 17.0
        DEVELOPMENT_TEAM: "" # Set this in Xcode GUI — your Apple Dev Team ID
    dependencies:
      - package: Supabase
        product: Supabase
```

- [ ] **Step 2: Write Info.plist**

Create `VideoEditor/iOSApp/Info.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>$(EXECUTABLE_NAME)</string>
    <key>CFBundleIdentifier</key>
    <string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$(PRODUCT_NAME)</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSRequiresIPhoneOS</key>
    <true/>
    <key>UISupportedInterfaceOrientations</key>
    <array><string>UIInterfaceOrientationPortrait</string></array>
</dict>
</plist>
```

- [ ] **Step 3: Generate the Xcode project**

```bash
cd VideoEditor/iOSApp
xcodegen generate
```

Expected: `Created project at VideoEditor/iOSApp/ShortsDistribution.xcodeproj`.

- [ ] **Step 4: Copy the tight logo into Resources**

```bash
mkdir -p VideoEditor/iOSApp/Resources
cp /Users/tadies/Library/Containers/com.videoeditor.app/Data/Documents/technolgia_logo_tight.png \
   VideoEditor/iOSApp/Resources/technolgia_logo_tight.png
```

- [ ] **Step 5: Initialize Assets.xcassets**

Open the project in Xcode (`open VideoEditor/iOSApp/ShortsDistribution.xcodeproj`). Use File → New → File → Asset Catalog. Add it to Resources. Add a default app icon placeholder (can use a solid-color square for now).

Alternatively, create the catalog manually:
```bash
mkdir -p VideoEditor/iOSApp/Resources/Assets.xcassets/AppIcon.appiconset
cat > VideoEditor/iOSApp/Resources/Assets.xcassets/Contents.json <<'EOF'
{"info": {"author": "xcode", "version": 1}}
EOF
cat > VideoEditor/iOSApp/Resources/Assets.xcassets/AppIcon.appiconset/Contents.json <<'EOF'
{"images": [{"idiom": "universal", "platform": "ios", "size": "1024x1024"}], "info": {"author": "xcode", "version": 1}}
EOF
```

- [ ] **Step 6: Add `.gitignore` entries**

Append to repo root `.gitignore`:

```
VideoEditor/iOSApp/ShortsDistribution.xcodeproj
VideoEditor/iOSApp/.swiftpm
VideoEditor/iOSApp/DerivedData
```

- [ ] **Step 7: Commit**

```bash
git add VideoEditor/iOSApp/project.yml VideoEditor/iOSApp/Info.plist \
       VideoEditor/iOSApp/Resources .gitignore
git commit -m "feat(ios): scaffold XcodeGen project + Info.plist + resources"
```

---

## Task 2: Config.swift with Supabase credentials

**Files:**
- Create: `VideoEditor/iOSApp/Config/Config.swift`

- [ ] **Step 1: Write the config file**

Create `VideoEditor/iOSApp/Config/Config.swift`:

```swift
import Foundation

/// Compile-time configuration. Credentials are baked in; this is a two-user private app.
/// If you open-source this repo, move these to a local, gitignored config.
enum Config {
    // Replace these with your actual values from Supabase → Settings → API.
    static let supabaseURL = URL(string: "https://REPLACE_WITH_PROJECT_REF.supabase.co")!
    static let supabaseAnonKey = "REPLACE_WITH_ANON_KEY"

    /// Brand color palette for thumbnail pill. Order matters — UI shows these left-to-right.
    static let brandPalette: [BrandColor] = [
        BrandColor(name: "Gold", hex: "#C9A028"),
        BrandColor(name: "Navy", hex: "#070D17"),
        BrandColor(name: "White", hex: "#FFFFFF"),
        BrandColor(name: "Pink", hex: "#E91E63"),
        BrandColor(name: "Green", hex: "#00C853"),
    ]

    struct BrandColor: Identifiable, Hashable {
        let name: String
        let hex: String
        var id: String { hex }
    }
}
```

- [ ] **Step 2: Add Config.swift to the project**

Re-run `xcodegen generate` so the new file appears in the Xcode source tree.

```bash
cd VideoEditor/iOSApp && xcodegen generate
```

- [ ] **Step 3: Sanity-check build**

Open the project in Xcode, select a simulator (iPhone 15 Pro), press Cmd+B. Expected: Build Succeeded. (The project has no code yet — it should compile as an empty app.)

- [ ] **Step 4: Commit (but don't commit real credentials)**

Make sure `Config.swift` has the REPLACE placeholders, not real keys. Do not add the service-role key to the iOS app.

```bash
git add VideoEditor/iOSApp/Config/Config.swift
git commit -m "feat(ios): add Config.swift with Supabase credential placeholders"
```

- [ ] **Step 5: Set real credentials locally**

Open `Config.swift` in Xcode, replace the three REPLACE_WITH strings with real values from Supabase dashboard. Do NOT commit this change. If you want to keep it out of future commits, `git update-index --assume-unchanged VideoEditor/iOSApp/Config/Config.swift`.

---

## Task 3: ShortsDistributionApp entry point + AppState

**Files:**
- Create: `VideoEditor/iOSApp/App/ShortsDistributionApp.swift`
- Create: `VideoEditor/iOSApp/App/AppState.swift`

- [ ] **Step 1: Write the App struct**

Create `VideoEditor/iOSApp/App/ShortsDistributionApp.swift`:

```swift
import SwiftUI

@main
struct ShortsDistributionApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environmentObject(appState)
        }
    }
}
```

- [ ] **Step 2: Write AppState**

Create `VideoEditor/iOSApp/App/AppState.swift`:

```swift
import Foundation
import SwiftUI

/// Global app state. Published properties cause SwiftUI views to refresh.
@MainActor
final class AppState: ObservableObject {
    @Published var shorts: [Short] = []
    @Published var isLoading: Bool = false
    @Published var errorMessage: String? = nil

    let supabase: SupabaseShortsClient

    init() {
        self.supabase = SupabaseShortsClient(
            url: Config.supabaseURL,
            anonKey: Config.supabaseAnonKey
        )
        // Configure video cache (2GB disk, 100MB memory) at launch.
        VideoCache.configure()
    }

    /// Reload library from Supabase.
    func refreshLibrary() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            shorts = try await supabase.listShorts()
        } catch {
            errorMessage = "Failed to load library: \(error.localizedDescription)"
        }
    }
}
```

- [ ] **Step 3: Regenerate + build**

```bash
cd VideoEditor/iOSApp && xcodegen generate
```

Expected: builds cleanly (once the stub types `Short`, `SupabaseShortsClient`, `VideoCache`, `LibraryView` exist — we add them in later tasks). For now, this will fail to build. That's expected.

- [ ] **Step 4: Commit**

```bash
git add VideoEditor/iOSApp/App
git commit -m "feat(ios): add app entry point + AppState"
```

---

## Task 4: Data models

**Files:**
- Create: `VideoEditor/iOSApp/Models/Platform.swift`
- Create: `VideoEditor/iOSApp/Models/Short.swift`
- Create: `VideoEditor/iOSApp/Models/Caption.swift`
- Create: `VideoEditor/iOSApp/Models/ThumbnailSettings.swift`

- [ ] **Step 1: Write Platform.swift**

```swift
import Foundation

enum Platform: String, CaseIterable, Codable, Identifiable {
    case youtube_shorts
    case tiktok
    case instagram_reels
    case twitter
    case linkedin

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .youtube_shorts: "YouTube"
        case .tiktok: "TikTok"
        case .instagram_reels: "Reels"
        case .twitter: "X"
        case .linkedin: "LinkedIn"
        }
    }

    var maxDurationSeconds: Double {
        switch self {
        case .youtube_shorts: 59
        case .instagram_reels: 90
        case .twitter: 140
        case .tiktok: 600
        case .linkedin: 600
        }
    }
}
```

- [ ] **Step 2: Write Short.swift**

```swift
import Foundation

struct Short: Codable, Identifiable, Hashable {
    let id: UUID
    let createdAt: Date
    let sourceAsset: String
    let hook: String
    let label: String
    let duration: Double
    let evergreenScore: Int
    let trendingScore: Int
    let platformFit: [String]
    let sourceStart: Double
    let sourceEnd: Double
    let videoPath: String
    let thumbnailPath: String
    let videoSize: Int64
    let reasoning: String

    enum CodingKeys: String, CodingKey {
        case id
        case createdAt = "created_at"
        case sourceAsset = "source_asset"
        case hook, label, duration
        case evergreenScore = "evergreen_score"
        case trendingScore = "trending_score"
        case platformFit = "platform_fit"
        case sourceStart = "source_start"
        case sourceEnd = "source_end"
        case videoPath = "video_path"
        case thumbnailPath = "thumbnail_path"
        case videoSize = "video_size"
        case reasoning
    }

    /// Fits this platform's duration limit.
    func fits(_ platform: Platform) -> Bool {
        duration <= platform.maxDurationSeconds
    }
}
```

- [ ] **Step 3: Write Caption.swift**

```swift
import Foundation

struct Caption: Codable, Identifiable, Hashable {
    let id: UUID
    let shortID: UUID
    let platform: String
    var title: String?
    var body: String
    var hashtags: [String]
    var lastEditedBy: String
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case shortID = "short_id"
        case platform, title, body, hashtags
        case lastEditedBy = "last_edited_by"
        case updatedAt = "updated_at"
    }
}
```

- [ ] **Step 4: Write ThumbnailSettings.swift**

```swift
import Foundation

struct ThumbnailSettings: Codable, Hashable {
    let shortID: UUID
    var labelText: String
    var labelColor: String        // hex like "#C9A028"
    var labelPosition: Position
    var frameIndex: Int
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case shortID = "short_id"
        case labelText = "label_text"
        case labelColor = "label_color"
        case labelPosition = "label_position"
        case frameIndex = "frame_index"
        case updatedAt = "updated_at"
    }

    enum Position: String, CaseIterable, Codable {
        case topLeft = "top-left"
        case topCenter = "top-center"
        case topRight = "top-right"
        case centerLeft = "center-left"
        case center = "center"
        case centerRight = "center-right"
        case bottomLeft = "bottom-left"
        case bottomCenter = "bottom-center"
        case bottomRight = "bottom-right"
    }
}
```

- [ ] **Step 5: Regenerate + commit**

```bash
cd VideoEditor/iOSApp && xcodegen generate
git add VideoEditor/iOSApp/Models
git commit -m "feat(ios): add Short/Caption/ThumbnailSettings/Platform models"
```

---

## Task 5: SupabaseShortsClient — read-only library fetch

**Files:**
- Create: `VideoEditor/iOSApp/Networking/SupabaseClient.swift`

- [ ] **Step 1: Write the client**

```swift
import Foundation
import Supabase

/// Our domain-specific Supabase client. Uses the anon key only; DB access is
/// constrained by RLS and media reads come from public buckets.
final class SupabaseShortsClient {
    let client: SupabaseClient

    init(url: URL, anonKey: String) {
        self.client = SupabaseClient(supabaseURL: url, supabaseKey: anonKey)
    }

    // MARK: - Shorts

    func listShorts() async throws -> [Short] {
        let response: [Short] = try await client
            .from("shorts")
            .select()
            .order("created_at", ascending: false)
            .execute()
            .value
        return response
    }

    // MARK: - Captions

    func listCaptions(forShort shortID: UUID) async throws -> [Caption] {
        try await client
            .from("captions")
            .select()
            .eq("short_id", value: shortID.uuidString.lowercased())
            .execute()
            .value
    }

    func updateCaption(shortID: UUID, platform: Platform, title: String?, body: String, hashtags: [String]) async throws {
        struct Patch: Encodable {
            let title: String?
            let body: String
            let hashtags: [String]
            let last_edited_by: String
        }
        let patch = Patch(title: title, body: body, hashtags: hashtags, last_edited_by: "ios")
        try await client
            .from("captions")
            .update(patch)
            .eq("short_id", value: shortID.uuidString.lowercased())
            .eq("platform", value: platform.rawValue)
            .execute()
    }

    // MARK: - Thumbnail settings

    func getThumbnailSettings(forShort shortID: UUID) async throws -> ThumbnailSettings {
        try await client
            .from("thumbnail_settings")
            .select()
            .eq("short_id", value: shortID.uuidString.lowercased())
            .single()
            .execute()
            .value
    }

    func updateThumbnailSettings(_ settings: ThumbnailSettings) async throws {
        struct Patch: Encodable {
            let label_text: String
            let label_color: String
            let label_position: String
            let frame_index: Int
        }
        let patch = Patch(
            label_text: settings.labelText,
            label_color: settings.labelColor,
            label_position: settings.labelPosition.rawValue,
            frame_index: settings.frameIndex
        )
        try await client
            .from("thumbnail_settings")
            .update(patch)
            .eq("short_id", value: settings.shortID.uuidString.lowercased())
            .execute()
    }

    // MARK: - Share intents

    func recordShare(shortID: UUID, platform: Platform) async throws {
        struct Event: Encodable {
            let short_id: String
            let platform: String
        }
        let event = Event(short_id: shortID.uuidString.lowercased(), platform: platform.rawValue)
        try await client
            .from("share_intents")
            .insert(event)
            .execute()
    }

    // MARK: - Storage URLs

    /// Buckets are public-read in v1; build deterministic public URLs.
    func publicObjectURL(bucket: String, path: String) -> URL {
        Config.supabaseURL
            .appendingPathComponent("storage/v1/object/public")
            .appendingPathComponent(bucket)
            .appendingPathComponent(path)
    }
}
```

- [ ] **Step 2: Regenerate + build**

```bash
cd VideoEditor/iOSApp && xcodegen generate
```

Open in Xcode, build (Cmd+B). Expected: Supabase package resolves on first build (may take a minute), then BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add VideoEditor/iOSApp/Networking/SupabaseClient.swift
git commit -m "feat(ios): add SupabaseShortsClient for DB + storage + public object URLs"
```

---

## Task 6: Cache layer — Videos + Frames

**Files:**
- Create: `VideoEditor/iOSApp/Cache/VideoCache.swift`
- Create: `VideoEditor/iOSApp/Cache/FrameCache.swift`

- [ ] **Step 1: Write VideoCache**

```swift
import Foundation

/// Configures URLCache for video streaming. Invoked once at app launch.
enum VideoCache {
    static func configure() {
        let memoryCapacity = 100 * 1024 * 1024           // 100 MB RAM
        let diskCapacity = 2 * 1024 * 1024 * 1024        // 2 GB disk
        let cache = URLCache(
            memoryCapacity: memoryCapacity,
            diskCapacity: diskCapacity,
            directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
                .appendingPathComponent("VideoCache")
        )
        URLCache.shared = cache
    }

    static func currentDiskUsage() -> Int {
        URLCache.shared.currentDiskUsage
    }

    static func clear() {
        URLCache.shared.removeAllCachedResponses()
    }
}
```

- [ ] **Step 2: Write FrameCache**

```swift
import Foundation

/// In-memory cache for candidate frame JPGs. Survives UI churn, evicts on memory pressure.
final class FrameCache {
    static let shared = FrameCache()

    private let cache: NSCache<NSString, NSData> = {
        let c = NSCache<NSString, NSData>()
        c.totalCostLimit = 50 * 1024 * 1024  // ~50 MB total
        return c
    }()

    func key(shortID: UUID, frameIndex: Int) -> NSString {
        "\(shortID.uuidString.lowercased())_\(frameIndex)" as NSString
    }

    func get(shortID: UUID, frameIndex: Int) -> Data? {
        cache.object(forKey: key(shortID: shortID, frameIndex: frameIndex)) as Data?
    }

    func put(shortID: UUID, frameIndex: Int, data: Data) {
        cache.setObject(data as NSData, forKey: key(shortID: shortID, frameIndex: frameIndex), cost: data.count)
    }
}
```

- [ ] **Step 3: Regenerate + commit**

```bash
cd VideoEditor/iOSApp && xcodegen generate
git add VideoEditor/iOSApp/Cache
git commit -m "feat(ios): add VideoCache (URLCache) + FrameCache (NSCache)"
```

---

## Task 7: LibraryView — grid of shorts

**Files:**
- Create: `VideoEditor/iOSApp/Views/LibraryView.swift`
- Create: `VideoEditor/iOSApp/Views/LibraryCell.swift`

- [ ] **Step 1: Write LibraryCell**

```swift
import SwiftUI

struct LibraryCell: View {
    let short: Short
    @State private var thumbnailData: Data? = nil
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                if let data = thumbnailData, let uiImage = UIImage(data: data) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .aspectRatio(9.0/16.0, contentMode: .fill)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                } else {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(white: 0.15))
                        .aspectRatio(9.0/16.0, contentMode: .fill)
                        .overlay(ProgressView().tint(.white))
                }

                Text(Self.durationLabel(short.duration))
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(Color.black.opacity(0.7))
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .padding(8)
            }
            Text(short.label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
        }
        .task { await loadThumbnail() }
    }

    private static func durationLabel(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        let m = s / 60
        let r = s % 60
        return m > 0 ? "\(m):\(String(format: "%02d", r))" : "\(r)s"
    }

    private func loadThumbnail() async {
        // v1: fetch the default thumbnail from Supabase. Later we'll render from settings locally.
        do {
            let url = appState.supabase.publicObjectURL(bucket: "thumbnails", path: short.id.uuidString.lowercased() + ".png")
            let (data, _) = try await URLSession.shared.data(from: url)
            thumbnailData = data
        } catch {
            // Silent: show placeholder
        }
    }
}
```

- [ ] **Step 2: Write LibraryView**

```swift
import SwiftUI

struct LibraryView: View {
    @EnvironmentObject var appState: AppState

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                if appState.shorts.isEmpty && !appState.isLoading {
                    VStack(spacing: 12) {
                        Image(systemName: "tray")
                            .font(.system(size: 48))
                            .foregroundStyle(.secondary)
                        Text("No shorts yet")
                            .font(.headline)
                        Text("Produce some on Mac.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }.padding(.top, 80)
                } else {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(appState.shorts) { short in
                            NavigationLink(value: short) {
                                LibraryCell(short: short)
                            }
                            .buttonStyle(.plain)
                        }
                    }.padding()
                }
            }
            .navigationTitle("TechNolgia")
            .navigationDestination(for: Short.self) { short in
                DetailView(short: short)
            }
            .refreshable { await appState.refreshLibrary() }
            .task { await appState.refreshLibrary() }
            .overlay(alignment: .top) {
                if let msg = appState.errorMessage {
                    Text(msg)
                        .font(.caption)
                        .padding(8)
                        .background(Color.red.opacity(0.9))
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .padding(.top, 8)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(destination: SettingsView()) {
                        Image(systemName: "gearshape")
                    }
                }
            }
        }
    }
}
```

- [ ] **Step 3: Create a stub DetailView + SettingsView so the project builds**

Create `VideoEditor/iOSApp/Views/DetailView.swift`:

```swift
import SwiftUI

struct DetailView: View {
    let short: Short
    var body: some View { Text("Detail for \(short.label)") }
}
```

Create `VideoEditor/iOSApp/Views/SettingsView.swift`:

```swift
import SwiftUI

struct SettingsView: View {
    var body: some View {
        Form {
            Section("Cache") {
                Text("Video cache: \(VideoCache.currentDiskUsage() / 1_048_576) MB")
                Button("Clear cache") { VideoCache.clear() }
            }
        }
        .navigationTitle("Settings")
    }
}
```

- [ ] **Step 4: Build + run on simulator**

```bash
cd VideoEditor/iOSApp && xcodegen generate
```

Open in Xcode, select iPhone 15 Pro simulator, press Cmd+R. Expected: app launches, navigates to library, shows a list of shorts (or empty state if Supabase is empty).

Verify: if Supabase has shorts from Plan 2, they appear in the grid with thumbnails.

- [ ] **Step 5: Commit**

```bash
git add VideoEditor/iOSApp/Views
git commit -m "feat(ios): add LibraryView + LibraryCell (read-only grid)"
```

---

## Task 8: DetailView skeleton with video player

**Files:**
- Modify: `VideoEditor/iOSApp/Views/DetailView.swift`
- Create: `VideoEditor/iOSApp/Views/VideoPlayerView.swift`

- [ ] **Step 1: Write VideoPlayerView**

```swift
import SwiftUI
import AVKit

struct VideoPlayerView: View {
    let videoURL: URL
    @State private var player: AVPlayer?

    var body: some View {
        VideoPlayer(player: player)
            .aspectRatio(9.0/16.0, contentMode: .fit)
            .onAppear {
                let p = AVPlayer(url: videoURL)
                p.isMuted = true
                p.play()
                player = p
            }
            .onDisappear {
                player?.pause()
            }
    }
}
```

- [ ] **Step 2: Expand DetailView**

Replace the stub in `VideoEditor/iOSApp/Views/DetailView.swift`:

```swift
import SwiftUI

struct DetailView: View {
    let short: Short
    @EnvironmentObject var appState: AppState
    @State private var videoURL: URL? = nil
    @State private var loadError: String? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Player
                if let url = videoURL {
                    VideoPlayerView(videoURL: url)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                } else if let err = loadError {
                    Text(err).foregroundStyle(.red).padding()
                } else {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(white: 0.15))
                        .aspectRatio(9.0/16.0, contentMode: .fit)
                        .overlay(ProgressView().tint(.white))
                }

                // Header
                VStack(alignment: .leading, spacing: 4) {
                    Text(short.label)
                        .font(.title3.weight(.semibold))
                    Text(short.hook)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)

                // Placeholders for editors (filled in later tasks)
                Text("Thumbnail editor — coming next").foregroundStyle(.secondary).padding(.horizontal)
                Text("Caption editor — coming next").foregroundStyle(.secondary).padding(.horizontal)
            }
            .padding(.vertical)
        }
        .navigationTitle(short.label)
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadVideo() }
    }

    private func loadVideo() async {
        do {
            let url = appState.supabase.publicObjectURL(
                bucket: "videos",
                path: short.id.uuidString.lowercased() + ".mp4"
            )
            videoURL = url
        } catch {
            loadError = "Could not load video: \(error.localizedDescription)"
        }
    }
}
```

- [ ] **Step 3: Regenerate + build + run**

```bash
cd VideoEditor/iOSApp && xcodegen generate
```

Run on simulator. Tap a short → video plays. Expected: video streams from Supabase, autoplays muted.

- [ ] **Step 4: Commit**

```bash
git add VideoEditor/iOSApp/Views/DetailView.swift VideoEditor/iOSApp/Views/VideoPlayerView.swift
git commit -m "feat(ios): add DetailView with streaming video player"
```

---

## Task 9: CaptionEditorView with 5-platform tabs

**Files:**
- Create: `VideoEditor/iOSApp/Views/CaptionEditorView.swift`
- Create: `VideoEditor/iOSApp/Networking/EdgeFunctions.swift`

- [ ] **Step 1: Write EdgeFunctions**

```swift
import Foundation

/// Client for Supabase Edge Functions we've deployed.
enum EdgeFunctions {
    struct RegenerateCaptionResponse: Decodable {
        let title: String?
        let body: String
        let hashtags: [String]
    }

    static func regenerateCaption(
        shortID: UUID,
        platform: Platform,
        tone: String = "default"
    ) async throws -> RegenerateCaptionResponse {
        var url = Config.supabaseURL
        url.append(path: "functions/v1/regenerate-caption")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(Config.supabaseAnonKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        struct Body: Encodable {
            let short_id: String
            let platform: String
            let tone: String
        }
        request.httpBody = try JSONEncoder().encode(Body(
            short_id: shortID.uuidString.lowercased(),
            platform: platform.rawValue,
            tone: tone
        ))

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "EdgeFunctions", code: 0, userInfo: [NSLocalizedDescriptionKey: "Edge function failed"])
        }
        return try JSONDecoder().decode(RegenerateCaptionResponse.self, from: data)
    }
}
```

- [ ] **Step 2: Write CaptionEditorView**

```swift
import SwiftUI

struct CaptionEditorView: View {
    let short: Short
    @EnvironmentObject var appState: AppState
    @State private var selectedPlatform: Platform = .youtube_shorts
    @State private var captions: [String: Caption] = [:]
    @State private var loadError: String? = nil
    @State private var isRegenerating: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Platform", selection: $selectedPlatform) {
                ForEach(Platform.allCases) { p in
                    Text(p.displayName).tag(p)
                }
            }
            .pickerStyle(.segmented)

            if let caption = captions[selectedPlatform.rawValue] {
                platformEditor(caption: caption)
            } else if let err = loadError {
                Text(err).foregroundStyle(.red)
            } else {
                ProgressView()
            }
        }
        .padding(.horizontal)
        .task { await loadCaptions() }
    }

    @ViewBuilder
    private func platformEditor(caption: Caption) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if selectedPlatform == .youtube_shorts {
                TextField("Title", text: bindingForTitle())
                    .textFieldStyle(.roundedBorder)
            }
            TextEditor(text: bindingForBody())
                .frame(minHeight: 120)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.3)))

            Text("Hashtags: \(caption.hashtags.joined(separator: " "))")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button(isRegenerating ? "Regenerating…" : "Regenerate with Claude") {
                    Task { await regenerate() }
                }
                .disabled(isRegenerating)
                Spacer()
                Button("Save") {
                    Task { await save() }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    // Swift doesn't allow `dict[key]?.field = value`, so we copy-out, mutate, copy-in.
    private func bindingForTitle() -> Binding<String> {
        Binding(
            get: { captions[selectedPlatform.rawValue]?.title ?? "" },
            set: { newValue in
                guard var cap = captions[selectedPlatform.rawValue] else { return }
                cap.title = newValue.isEmpty ? nil : newValue
                captions[selectedPlatform.rawValue] = cap
            }
        )
    }

    private func bindingForBody() -> Binding<String> {
        Binding(
            get: { captions[selectedPlatform.rawValue]?.body ?? "" },
            set: { newValue in
                guard var cap = captions[selectedPlatform.rawValue] else { return }
                cap.body = newValue
                captions[selectedPlatform.rawValue] = cap
            }
        )
    }

    private func loadCaptions() async {
        do {
            let fetched = try await appState.supabase.listCaptions(forShort: short.id)
            var dict: [String: Caption] = [:]
            for cap in fetched { dict[cap.platform] = cap }
            captions = dict
        } catch {
            loadError = "Failed to load captions: \(error.localizedDescription)"
        }
    }

    private func save() async {
        guard let caption = captions[selectedPlatform.rawValue] else { return }
        do {
            try await appState.supabase.updateCaption(
                shortID: short.id,
                platform: selectedPlatform,
                title: caption.title,
                body: caption.body,
                hashtags: caption.hashtags
            )
        } catch {
            loadError = "Save failed: \(error.localizedDescription)"
        }
    }

    private func regenerate() async {
        isRegenerating = true
        defer { isRegenerating = false }
        do {
            let fresh = try await EdgeFunctions.regenerateCaption(shortID: short.id, platform: selectedPlatform)
            if var existing = captions[selectedPlatform.rawValue] {
                existing.title = fresh.title
                existing.body = fresh.body
                existing.hashtags = fresh.hashtags
                existing.lastEditedBy = "claude_regen"
                captions[selectedPlatform.rawValue] = existing
            }
        } catch {
            loadError = "Regenerate failed: \(error.localizedDescription)"
        }
    }
}
```

- [ ] **Step 3: Wire it into DetailView**

In `DetailView.swift`, replace the "Caption editor — coming next" line with:

```swift
CaptionEditorView(short: short)
```

- [ ] **Step 4: Regenerate + build + run**

```bash
cd VideoEditor/iOSApp && xcodegen generate
```

Run, tap a short, scroll to captions, verify: 5 tabs show, tapping switches text, Save persists (check Supabase dashboard), Regenerate calls the edge function and updates.

- [ ] **Step 5: Commit**

```bash
git add VideoEditor/iOSApp/Views/CaptionEditorView.swift \
       VideoEditor/iOSApp/Networking/EdgeFunctions.swift \
       VideoEditor/iOSApp/Views/DetailView.swift
git commit -m "feat(ios): add CaptionEditorView with 5 platform tabs + regenerate"
```

---

## Task 10: ThumbnailCompositor — live local render

**Files:**
- Create: `VideoEditor/iOSApp/Rendering/ThumbnailCompositor.swift`

- [ ] **Step 1: Write the compositor**

```swift
import UIKit
import CoreGraphics
import CoreText

/// Renders a thumbnail UIImage from a base frame + pill text + logo.
/// Runs on-device in ~50-100ms for a 1080x1920 output. Must match Mac's renderer visually.
enum ThumbnailCompositor {
    struct Input {
        let baseFrame: UIImage         // 1080x1920, already 9:16 composed
        let labelText: String
        let labelColor: UIColor
        let labelPosition: ThumbnailSettings.Position
        let logo: UIImage?             // Already transparent-background
    }

    static func render(_ input: Input) -> UIImage {
        let size = CGSize(width: 1080, height: 1920)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            let cg = ctx.cgContext
            // Base frame (scaleAspectFill)
            input.baseFrame.draw(in: CGRect(origin: .zero, size: size))

            // Logo top-right
            if let logo = input.logo {
                let maxW: CGFloat = 500
                let aspect = logo.size.height / logo.size.width
                let drawSize = CGSize(width: maxW, height: maxW * aspect)
                let x = size.width - drawSize.width - 24
                let y = 20.0
                logo.draw(in: CGRect(origin: CGPoint(x: x, y: y), size: drawSize))
            }

            // Pill
            drawPill(in: cg, frameSize: size, input: input)
        }
    }

    private static func drawPill(in ctx: CGContext, frameSize size: CGSize, input: Input) {
        let textColor: UIColor = (input.labelColor.hex == "#C9A028" || input.labelColor.hex == "#FFFFFF" || input.labelColor.hex == "#00C853") ? UIColor(hex: "#070D17") : UIColor.white

        let font = chooseFont(preferred: [
            "BarlowCondensed-Black", "Anton-Regular", "Impact", "HelveticaNeue-CondensedBlack", "Helvetica-Bold"
        ], size: 64)

        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor,
            .kern: -2.0,
        ]
        let textSize = (input.labelText.uppercased() as NSString).size(withAttributes: attrs)
        let padX: CGFloat = 40, padY: CGFloat = 24, radius: CGFloat = 24
        let pillW = textSize.width + padX * 2
        let pillH = textSize.height + padY * 2

        let origin = originForPosition(input.labelPosition, frameSize: size, pillSize: CGSize(width: pillW, height: pillH))
        let pillRect = CGRect(origin: origin, size: CGSize(width: pillW, height: pillH))

        // Shadow + fill
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 4), blur: 8, color: UIColor.black.withAlphaComponent(0.5).cgColor)
        input.labelColor.setFill()
        UIBezierPath(roundedRect: pillRect, cornerRadius: radius).fill()
        ctx.restoreGState()

        // Text
        let textX = pillRect.minX + padX
        let textY = pillRect.minY + padY
        (input.labelText.uppercased() as NSString).draw(at: CGPoint(x: textX, y: textY), withAttributes: attrs)
    }

    private static func originForPosition(
        _ pos: ThumbnailSettings.Position, frameSize: CGSize, pillSize: CGSize
    ) -> CGPoint {
        let margin: CGFloat = 60
        let hCenter = (frameSize.width - pillSize.width) / 2
        let vCenter = (frameSize.height - pillSize.height) / 2
        let left: CGFloat = margin
        let right = frameSize.width - pillSize.width - margin
        let top: CGFloat = margin
        let bottom = frameSize.height - pillSize.height - margin
        switch pos {
        case .topLeft:      return CGPoint(x: left, y: top)
        case .topCenter:    return CGPoint(x: hCenter, y: top)
        case .topRight:     return CGPoint(x: right, y: top)
        case .centerLeft:   return CGPoint(x: left, y: vCenter)
        case .center:       return CGPoint(x: hCenter, y: vCenter)
        case .centerRight:  return CGPoint(x: right, y: vCenter)
        case .bottomLeft:   return CGPoint(x: left, y: bottom)
        case .bottomCenter: return CGPoint(x: hCenter, y: bottom)
        case .bottomRight:  return CGPoint(x: right, y: bottom)
        }
    }

    private static func chooseFont(preferred: [String], size: CGFloat) -> UIFont {
        for name in preferred {
            if let f = UIFont(name: name, size: size) { return f }
        }
        return UIFont.systemFont(ofSize: size, weight: .black)
    }
}

extension UIColor {
    convenience init(hex: String) {
        var h = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if h.hasPrefix("#") { h.removeFirst() }
        let scanner = Scanner(string: h)
        var rgb: UInt64 = 0
        scanner.scanHexInt64(&rgb)
        self.init(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }

    var hex: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X", Int(r*255), Int(g*255), Int(b*255))
    }
}
```

- [ ] **Step 2: Regenerate + commit**

```bash
cd VideoEditor/iOSApp && xcodegen generate
git add VideoEditor/iOSApp/Rendering/ThumbnailCompositor.swift
git commit -m "feat(ios): add ThumbnailCompositor for local Core Graphics render"
```

---

## Task 11: ThumbnailEditorView with live preview

**Files:**
- Create: `VideoEditor/iOSApp/Views/ThumbnailEditorView.swift`
- Modify: `VideoEditor/iOSApp/Views/DetailView.swift`

- [ ] **Step 1: Write ThumbnailEditorView**

```swift
import SwiftUI

struct ThumbnailEditorView: View {
    let short: Short
    @EnvironmentObject var appState: AppState
    @State private var settings: ThumbnailSettings? = nil
    @State private var frameImages: [Int: UIImage] = [:]
    @State private var logoImage: UIImage? = UIImage(named: "technolgia_logo_tight")
    @State private var isLoading: Bool = true
    @State private var errorMessage: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Thumbnail").font(.headline).padding(.horizontal)

            if let settings, let preview = renderPreview(settings: settings) {
                Image(uiImage: preview)
                    .resizable()
                    .aspectRatio(9.0/16.0, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding(.horizontal)
            } else if isLoading {
                ProgressView().padding()
            } else if let err = errorMessage {
                Text(err).foregroundStyle(.red).padding()
            }

            if settings != nil {
                editorControls(settings: Binding(
                    get: { settings ?? ThumbnailSettings(
                        shortID: short.id, labelText: short.label, labelColor: "#C9A028",
                        labelPosition: .bottomCenter, frameIndex: 0, updatedAt: Date()
                    ) },
                    set: { newValue in settings = newValue }
                ))
            }
        }
        .task { await load() }
    }

    @ViewBuilder
    private func editorControls(settings: Binding<ThumbnailSettings>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Label text", text: settings.labelText)
                .textFieldStyle(.roundedBorder)

            Text("Color").font(.caption).foregroundStyle(.secondary)
            HStack {
                ForEach(Config.brandPalette) { color in
                    Circle()
                        .fill(Color(UIColor(hex: color.hex)))
                        .overlay(Circle().stroke(Color.white, lineWidth: settings.wrappedValue.labelColor == color.hex ? 3 : 1))
                        .frame(width: 36, height: 36)
                        .onTapGesture { settings.wrappedValue.labelColor = color.hex }
                }
            }

            Text("Position").font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 8) {
                ForEach(ThumbnailSettings.Position.allCases, id: \.rawValue) { pos in
                    Button(action: { settings.wrappedValue.labelPosition = pos }) {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(settings.wrappedValue.labelPosition == pos ? Color.accentColor : Color.gray.opacity(0.4), lineWidth: 2)
                            .frame(height: 44)
                            .overlay(Text(pos.rawValue.replacingOccurrences(of: "-", with: " ")).font(.caption))
                    }
                    .buttonStyle(.plain)
                }
            }

            Text("Frame").font(.caption).foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(0..<10) { idx in
                        if let img = frameImages[idx] {
                            Image(uiImage: img)
                                .resizable()
                                .aspectRatio(9.0/16.0, contentMode: .fill)
                                .frame(width: 60, height: 107)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                                .overlay(RoundedRectangle(cornerRadius: 4).stroke(
                                    settings.wrappedValue.frameIndex == idx ? Color.accentColor : Color.clear, lineWidth: 3))
                                .onTapGesture { settings.wrappedValue.frameIndex = idx }
                        } else {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color(white: 0.2))
                                .frame(width: 60, height: 107)
                        }
                    }
                }
            }

            Button("Save thumbnail") { Task { await save() } }
                .buttonStyle(.borderedProminent)
                .padding(.top, 8)
        }
        .padding(.horizontal)
    }

    private func renderPreview(settings: ThumbnailSettings) -> UIImage? {
        guard let base = frameImages[settings.frameIndex] else { return nil }
        return ThumbnailCompositor.render(.init(
            baseFrame: base,
            labelText: settings.labelText,
            labelColor: UIColor(hex: settings.labelColor),
            labelPosition: settings.labelPosition,
            logo: logoImage
        ))
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let s = try await appState.supabase.getThumbnailSettings(forShort: short.id)
            settings = s
            await loadFrames()
        } catch {
            errorMessage = "Failed to load settings: \(error.localizedDescription)"
        }
    }

    private func loadFrames() async {
        // Load all 10 candidate frames in parallel.
        await withTaskGroup(of: (Int, UIImage?).self) { group in
            for i in 0..<10 {
                group.addTask {
                    if let cached = FrameCache.shared.get(shortID: short.id, frameIndex: i),
                       let img = UIImage(data: cached) {
                        return (i, img)
                    }
                    do {
                        let url = appState.supabase.publicObjectURL(
                            bucket: "frames",
                            path: "\(short.id.uuidString.lowercased())/frame_\(i).jpg"
                        )
                        let (data, _) = try await URLSession.shared.data(from: url)
                        FrameCache.shared.put(shortID: short.id, frameIndex: i, data: data)
                        return (i, UIImage(data: data))
                    } catch {
                        return (i, nil)
                    }
                }
            }
            for await (idx, img) in group {
                if let img { frameImages[idx] = img }
            }
        }
    }

    private func save() async {
        guard let settings else { return }
        do {
            try await appState.supabase.updateThumbnailSettings(settings)
        } catch {
            errorMessage = "Save failed: \(error.localizedDescription)"
        }
    }
}
```

- [ ] **Step 2: Wire into DetailView**

Replace the "Thumbnail editor — coming next" text in `DetailView.swift` with:

```swift
ThumbnailEditorView(short: short)
```

- [ ] **Step 3: Regenerate + build + run**

```bash
cd VideoEditor/iOSApp && xcodegen generate
```

Run, tap a short, scroll to thumbnail editor. Verify:
- Preview renders the current settings
- Typing in label field updates preview live
- Tapping a color updates preview
- Tapping a position cell updates preview
- Tapping a frame thumbnail updates preview
- Save button persists (check Supabase `thumbnail_settings` row)

- [ ] **Step 4: Commit**

```bash
git add VideoEditor/iOSApp/Views/ThumbnailEditorView.swift \
       VideoEditor/iOSApp/Views/DetailView.swift
git commit -m "feat(ios): add ThumbnailEditorView with live render"
```

---

## Task 12: Share button + share_intents recording

**Files:**
- Create: `VideoEditor/iOSApp/Views/ShareButton.swift`
- Modify: `VideoEditor/iOSApp/Views/DetailView.swift`

- [ ] **Step 1: Write ShareButton**

```swift
import SwiftUI
import UIKit

struct ShareButton: View {
    let short: Short
    let activeCaption: Caption?
    let thumbnailImage: UIImage?
    @EnvironmentObject var appState: AppState
    @State private var isPreparing: Bool = false
    @State private var shareItems: [Any] = []
    @State private var showShareSheet: Bool = false

    var body: some View {
        Button {
            Task { await prepareAndShare() }
        } label: {
            HStack { Image(systemName: "square.and.arrow.up"); Text(isPreparing ? "Preparing…" : "Share") }
                .frame(maxWidth: .infinity)
                .padding()
                .background(.blue, in: RoundedRectangle(cornerRadius: 12))
                .foregroundColor(.white)
                .font(.headline)
        }
        .disabled(isPreparing)
        .sheet(isPresented: $showShareSheet) {
            ActivityViewController(items: shareItems)
                .onDisappear { Task { await recordShareIntent() } }
        }
    }

    private func prepareAndShare() async {
        isPreparing = true
        defer { isPreparing = false }
        do {
            // Download video to local temp file
            let url = appState.supabase.publicObjectURL(
                bucket: "videos",
                path: "\(short.id.uuidString.lowercased()).mp4"
            )
            let (data, _) = try await URLSession.shared.data(from: url)
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(short.id.uuidString.lowercased()).mp4")
            try data.write(to: tempURL)

            var items: [Any] = [tempURL]

            // Compose caption text from active platform tab
            if let cap = activeCaption {
                var text = cap.body
                if !cap.hashtags.isEmpty {
                    text += "\n\n" + cap.hashtags.joined(separator: " ")
                }
                items.append(text)
            }

            // Optionally attach thumbnail (some apps pick this up as preview)
            if let thumb = thumbnailImage {
                items.append(thumb)
            }

            shareItems = items
            showShareSheet = true
        } catch {
            // Silent fail; could surface a toast
        }
    }

    private func recordShareIntent() async {
        // We don't know which platform the user actually picked from the share sheet.
        // Record the platform tab that was active as an intent metric.
        guard let cap = activeCaption, let platform = Platform(rawValue: cap.platform) else { return }
        try? await appState.supabase.recordShare(shortID: short.id, platform: platform)
    }
}

/// UIKit activity view controller wrapped for SwiftUI.
struct ActivityViewController: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
```

- [ ] **Step 2: Wire into DetailView**

Add to `DetailView.swift`. First change: track the active platform + its caption + the rendered thumbnail so the share button knows what to include.

Simpler pattern: pass the share button the `short` and let it re-fetch what it needs. For v1, minimal wiring — place at the bottom of the ScrollView:

```swift
ShareButton(short: short, activeCaption: nil, thumbnailImage: nil)
    .padding(.horizontal)
    .padding(.bottom, 24)
```

(Passing `nil` for caption/thumbnail keeps v1 simple. Share sheet still works with just the video. We can pipe real active values in a follow-up if needed.)

- [ ] **Step 3: Regenerate + build + run**

```bash
cd VideoEditor/iOSApp && xcodegen generate
```

Run on a physical device (share sheet requires real hardware for some apps). Tap Share → iOS share sheet opens with the video attached. Pick TikTok/YouTube/etc. to verify the target app receives the video.

- [ ] **Step 4: Commit**

```bash
git add VideoEditor/iOSApp/Views/ShareButton.swift \
       VideoEditor/iOSApp/Views/DetailView.swift
git commit -m "feat(ios): add ShareButton with download + iOS share sheet + share-intent recording"
```

---

## Task 13: End-to-end polish + test

- [ ] **Step 1: Add app icon**

Use the existing TechNolgia card logo (already in the repo) as the app icon:

```bash
# The card-style TechNolgia logo is square-friendly
cp /Users/tadies/Library/Containers/com.videoeditor.app/Data/Documents/technolgia_logo_card.png \
   /tmp/app_icon_source.png

# Resize to 1024x1024 (square, flattened) using sips
sips -z 1024 1024 /tmp/app_icon_source.png \
   --out VideoEditor/iOSApp/Resources/Assets.xcassets/AppIcon.appiconset/Icon-1024.png
```

Update `VideoEditor/iOSApp/Resources/Assets.xcassets/AppIcon.appiconset/Contents.json`:

```json
{
  "images": [
    {
      "filename": "Icon-1024.png",
      "idiom": "universal",
      "platform": "ios",
      "size": "1024x1024"
    }
  ],
  "info": { "author": "xcode", "version": 1 }
}
```

- [ ] **Step 2: Install the TechNolgia logo as a named asset**

Ensure `technolgia_logo_tight.png` is accessible via `UIImage(named:)` — it already is in `Resources/`, but double-check by running and looking at the rendered preview.

- [ ] **Step 3: Run on physical device**

Plug your iPhone in, select it as the run destination in Xcode, press Cmd+R. You'll need to:
- Set DEVELOPMENT_TEAM in Xcode → Signing & Capabilities
- Trust the dev certificate on the phone (Settings → General → VPN & Device Management)

Verify the full happy path:
1. App launches → Library grid shows all shorts from Supabase
2. Tap a short → Detail screen with streaming video
3. Edit caption → Save → reload app → caption persists
4. Edit thumbnail label/color/position/frame → Save → reload → persists
5. Tap Share → iOS share sheet → pick an app → it opens with the video
6. Check Supabase `share_intents` table → new row

- [ ] **Step 4: Install on Elvis's device**

Build an Ad Hoc or TestFlight build (Product → Archive → Distribute App). Add Elvis's Apple ID and device UDID to your developer account if using Ad Hoc, or invite him via TestFlight.

- [ ] **Step 5: Confirm shared library works**

On Elvis's phone, open the app. Verify he sees the same library, can edit captions, and his edits show up on your phone (pull-to-refresh). Conflicts (both editing same caption) should resolve last-write-wins per spec.

- [ ] **Step 6: Final commit**

```bash
git add VideoEditor/iOSApp/Resources/Assets.xcassets
git commit -m "feat(ios): add app icon + final polish"
```

---

## Done

Plan 3 complete when:
- iOS app installed on both phones
- Library populated from Supabase, both phones see same list
- Caption editing works per-platform, regenerate calls edge function
- Thumbnail editor lets user change text, color, position, frame
- Share sheet successfully hands video to target apps
- share_intents rows recorded on share-sheet dismissal as intent metrics
