//
//  ClaudiusApp.swift
//  Claudius
//
//  Created by Luke Solomon on 3/10/26.
//

import SwiftUI
import Combine
import Sparkle

// MARK: - Menu bar icon style

enum MenuBarIconStyle: String, CaseIterable, Identifiable {
  case bars            = "Bars"
  case numbers         = "Numbers"
  case barsAndNumbers  = "Bars + numbers"
  case sessionPercent  = "Session %"

  var id: String { rawValue }
}

// MARK: - Menu bar label

/// One bar/number in the menu bar. Kept separate from `UsageBucket` so
/// local-log mode — which has no buckets at all — renders through the same path.
struct MenuBarDatum: Identifiable, Equatable {
  let id: String
  let pct: Double        // 0...1
  let color: Color
}

private struct MenuBarLabel: View {
  let data: [MenuBarDatum]        // 1...maxBars, already ordered and truncated
  let isSyncing: Bool
  let style: MenuBarIconStyle
  let legacySessionPct: Double    // for `.sessionPercent`, mirrors prior behavior
  let legacyColor: Color

  var body: some View {
    switch style {
    case .bars:
      RenderedToImage {
        MenuBarBars(data: data)
      }
      .opacity(isSyncing ? 0.5 : 1)
    case .numbers:
      RenderedToImage {
        MenuBarNumbers(data: data)
      }
      .opacity(isSyncing ? 0.5 : 1)
    case .barsAndNumbers:
      RenderedToImage {
        MenuBarBarsAndNumbers(data: data)
      }
      .opacity(isSyncing ? 0.5 : 1)
    case .sessionPercent:
      let pct = Int((legacySessionPct * 100).rounded())
      HStack(spacing: 2) {
        Text(isSyncing ? "…" : "\(pct)%")
      }
      .foregroundStyle(legacyColor)
    }
  }
}

/// Renders an arbitrary SwiftUI view to an NSImage so it paints in MenuBarExtra's
/// label, which doesn't render Shapes directly. ImageRenderer defaults to a
/// light-mode environment, so we forward the live colorScheme — otherwise
/// `Color.primary` always bakes as black and disappears on a dark menu bar.
private struct RenderedToImage<Content: View>: View {
  @Environment(\.colorScheme) private var colorScheme
  @ViewBuilder let content: () -> Content

  var body: some View {
    let renderer = ImageRenderer(content:
      content().environment(\.colorScheme, colorScheme)
    )
    renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
    let nsImage = renderer.nsImage ?? NSImage()
    nsImage.isTemplate = false
    return Image(nsImage: nsImage)
  }
}

// MARK: - Bars

private struct MenuBarBars: View {
  let data: [MenuBarDatum]

  var body: some View {
    VStack(spacing: BarMetrics.gap) {
      ForEach(data) { datum in
        MiniBar(pct: datum.pct, color: datum.color)
      }
    }
  }
}

private struct MenuBarNumbers: View {
  let data: [MenuBarDatum]

  var body: some View {
    // Two stacked 11pt lines already fill the menu bar's ~22pt of height, so a
    // third value goes horizontal rather than shrinking the font to illegibility.
    if data.count >= 3 {
      HStack(spacing: 4) {
        ForEach(data) { datum in
          Text(BarMetrics.percentText(datum.pct))
            .font(BarMetrics.numberFont)
            .foregroundStyle(BarMetrics.textColor(for: datum.pct))
        }
      }
    } else {
      VStack(alignment: .leading, spacing: BarMetrics.gap) {
        ForEach(data) { datum in
          Text(BarMetrics.percentText(datum.pct))
            .font(BarMetrics.numberFont)
            .foregroundStyle(BarMetrics.textColor(for: datum.pct))
        }
      }
    }
  }
}

private struct MenuBarBarsAndNumbers: View {
  let data: [MenuBarDatum]

  var body: some View {
    if data.count >= 3 {
      HStack(spacing: 5) {
        ForEach(data) { datum in
          HStack(spacing: 1) {
            MiniBar(pct: datum.pct, color: datum.color, width: BarMetrics.compactWidth)
            Text(BarMetrics.percentText(datum.pct))
              .font(BarMetrics.numberFont)
              .foregroundStyle(BarMetrics.textColor(for: datum.pct))
          }
        }
      }
    } else {
      VStack(alignment: .leading, spacing: BarMetrics.gap) {
        ForEach(data) { datum in
          HStack(spacing: 1) {
            MiniBar(pct: datum.pct, color: datum.color)
            Text(BarMetrics.percentText(datum.pct))
              .font(BarMetrics.numberFont)
              .foregroundStyle(BarMetrics.textColor(for: datum.pct))
          }
        }
      }
    }
  }
}

private struct MiniBar: View {
  let pct: Double
  let color: Color
  var width: CGFloat = BarMetrics.width

  var body: some View {
    ZStack(alignment: .leading) {
      RoundedRectangle(cornerRadius: BarMetrics.corner)
        .fill(Color.gray.opacity(0.45))
        .frame(width: width, height: BarMetrics.height)
      RoundedRectangle(cornerRadius: BarMetrics.corner)
        .fill(color)
        .frame(width: width * CGFloat(min(max(pct, 0), 1)), height: BarMetrics.height)
        .animation(.easeOut(duration: 0.3), value: pct)
    }
  }
}

private enum BarMetrics {
  static let width: CGFloat = 22
  static let compactWidth: CGFloat = 14
  /// Sized so three bars fit the menu bar's ~22pt: 3×5 + 2×1 = 17pt.
  static let height: CGFloat = 5
  static let corner: CGFloat = 1.5
  static let gap: CGFloat = 1

  /// Hard cap on menu bar bars, however many buckets the API reports.
  static let maxBars = 3

  // Number rides on the translucent menu bar background — primary for contrast,
  // red only when the matching bar is in alert state (mirrors the bar's signal).
  static let numberFont: Font = .system(size: 11, weight: .semibold, design: .monospaced)

  static func textColor(for pct: Double) -> Color {
    pct >= 0.9 ? .red : .primary
  }

  static func percentText(_ pct: Double) -> String {
    "\(Int((pct * 100).rounded()))"
  }

  /// Local-log mode has no bucket to take a color from.
  static func localSessionColor(for pct: Double) -> Color {
    pct >= 0.9 ? .red : Color(hex: UsageBucket.sessionHex)
  }
}

/// Sample-data rendition of a menu-bar style. Used by the settings picker;
/// renders SwiftUI directly (Shapes paint fine inside a normal window).
struct MenuBarStylePreview: View {
  let style: MenuBarIconStyle

  private static let sampleSession: Double = 0.45

  /// Two samples: the picker segments are ~75pt wide, and a three-up
  /// "Bars + numbers" sample needs ~95pt and truncates. Two also matches what
  /// most accounts actually see, so the preview doesn't advertise a compact
  /// horizontal layout the user's menu bar won't use.
  private static let sample: [MenuBarDatum] = [
    MenuBarDatum(id: "session", pct: 0.45, color: Color(hex: UsageBucket.sessionHex)),
    MenuBarDatum(id: "weekly",  pct: 0.70, color: Color(hex: UsageBucket.weeklyAllHex)),
  ]

  var body: some View {
    switch style {
    case .bars:
      MenuBarBars(data: Self.sample)
    case .numbers:
      MenuBarNumbers(data: Self.sample)
    case .barsAndNumbers:
      MenuBarBarsAndNumbers(data: Self.sample)
    case .sessionPercent:
      Text("\(Int((Self.sampleSession * 100).rounded()))%")
        .foregroundStyle(.green)
    }
  }
}

// MARK: - Sparkle "Check for Updates" view

final class CheckForUpdatesViewModel: ObservableObject {
  @Published var canCheckForUpdates = false

  init(updater: SPUUpdater) {
    updater.publisher(for: \.canCheckForUpdates)
      .assign(to: &$canCheckForUpdates)
  }
}

struct CheckForUpdatesView: View {
  @ObservedObject private var viewModel: CheckForUpdatesViewModel
  private let updater: SPUUpdater

  init(updater: SPUUpdater) {
    self.updater = updater
    self.viewModel = CheckForUpdatesViewModel(updater: updater)
  }

  var body: some View {
    Button("Check for Updates…", action: updater.checkForUpdates)
      .disabled(!viewModel.canCheckForUpdates)
  }
}

// MARK: - App State Manager
class AppState: ObservableObject {
  @Published var currentUsage: UsageStats = UsageStats()
  @Published var isSyncing: Bool = false
  @Published var lastSyncTime: Date? = nil
  @Published var lastError: String? = nil

  private var timerCancellable: AnyCancellable?
  private var lastPushedTokens: Int = 0
  /// Last pushed utilization per bucket id. Keyed rather than a single value so
  /// a weekly-only change still reaches the device — the 5-hour and weekly
  /// windows move on completely different cadences.
  private var lastPushedBuckets: [String: Double] = [:]

  init() {
    // Show real local numbers immediately, without requiring Tidbyt credentials.
    let local = TidbytManager.readTodayUsage()
    currentUsage = local

    // Then attempt a full push in the background.
    performSync(force: true)

    timerCancellable = Timer.publish(every: 300, on: .main, in: .common)
      .autoconnect()
      .sink { [weak self] _ in self?.performSync(force: false) }
  }

  /// Utilization per bucket id, as pushed to the device.
  static func bucketUtilizations(_ stats: UsageStats) -> [String: Double] {
    Dictionary(
      stats.buckets.map { ($0.id, $0.utilization) },
      uniquingKeysWith: { first, _ in first }
    )
  }

  /// Whether this sync warrants a Tidbyt push. Pure, so the throttle is
  /// testable — the previous version gated on the 5-hour value alone, which
  /// meant a weekly-only change never reached the device.
  static func shouldPush(
    stats: UsageStats,
    force: Bool,
    lastPushedBuckets: [String: Double],
    lastPushedTokens: Int
  ) -> Bool {
    guard stats.buckets.isEmpty else {
      // Web mode: push if the set of buckets changed, or any one of them
      // moved by at least 1 point.
      let current = bucketUtilizations(stats)
      if force || Set(current.keys) != Set(lastPushedBuckets.keys) { return true }
      return current.contains { id, pct in
        guard let previous = lastPushedBuckets[id] else { return true }
        return abs(pct - previous) >= 1.0
      }
    }

    // Local mode: push if tokens changed by at least 1%
    let tokenDiff = abs(stats.tokens - lastPushedTokens)
    let percentChange = lastPushedTokens == 0 ? 1.0 : Double(tokenDiff) / Double(lastPushedTokens)
    return force || percentChange > 0.01
  }

  /// Fetches usage — tries OAuth API first, falls back to local JSONL.
  /// Then pushes to Tidbyt if credentials are set.
  func performSync(force: Bool = false) {
    guard !isSyncing else { return }
    isSyncing = true
    lastError = nil

    Task {
      // Source priority:
      //  1. The Claude desktop app's on-disk usage cache. No token, no network
      //     request, so it cannot expire, prompt, or be rate limited. This is
      //     the correct source for anyone running Claude Code through the
      //     desktop app, whose CLI Keychain item stops being maintained.
      //  2. The OAuth API, for people running the Claude Code CLI.
      //  3. Local JSONL estimates.
      var stats = DesktopUsageReader.readUsage()

      if stats == nil {
        stats = await ClaudeWebUsageService.fetchUsage(force: force)
        if stats == nil {
          let reason = await KeychainHelper.shared.claudeAuthProblem() ?? "OAuth fetch failed"
          print("Claudius: no web usage (\(reason)); falling back to local logs")
          await MainActor.run { self.lastError = "\(reason) — using local logs" }
        }
      }

      // Fall back to local JSONL parsing
      if stats == nil {
        var localStats = TidbytManager.readTodayUsage()
        localStats.dataSource = .local
        stats = localStats
      }

      guard let stats else { return }

      let currentBuckets = Self.bucketUtilizations(stats)
      let shouldPush = Self.shouldPush(
        stats: stats,
        force: force,
        lastPushedBuckets: self.lastPushedBuckets,
        lastPushedTokens: self.lastPushedTokens
      )

      if shouldPush {
        let pushed = await TidbytManager.push(stats: stats)
        await MainActor.run {
          self.currentUsage = stats
          if pushed {
            self.lastSyncTime = Date()
            self.lastPushedTokens = stats.tokens
            self.lastPushedBuckets = currentBuckets
          } else {
            let hasCredentials =
              KeychainHelper.shared.read(service: "ClaudeTidbyt", account: "TidbytToken") != nil &&
              UserDefaults.standard.string(forKey: "TidbytDeviceID") != nil
            if hasCredentials {
              self.lastError = (self.lastError ?? "") + (self.lastError != nil ? " · " : "") + "Tidbyt push failed"
            }
          }
          self.isSyncing = false
        }
      } else {
        await MainActor.run {
          self.currentUsage = stats
          self.isSyncing = false
        }
      }
    }
  }
}

// MARK: - Menu Content View

struct MenuContent: View {
  @EnvironmentObject var appState: AppState
  @Environment(\.openWindow) private var openWindow
  let updater: SPUUpdater

  private var costLimit: Double {
    let v = UserDefaults.standard.double(forKey: "CostLimit")
    return v > 0 ? v : 5.0
  }
  private var tokenLimit: Int {
    let v = UserDefaults.standard.integer(forKey: "TokenLimit")
    return v > 0 ? v : 44_000
  }

  private func formatTokens(_ t: Int) -> String {
    t >= 1_000_000
      ? String(format: "%.1fM", Double(t) / 1_000_000)
      : t >= 1_000
        ? String(format: "%.1fk", Double(t) / 1_000)
        : "\(t)"
  }

  var body: some View {
    if appState.currentUsage.buckets.isEmpty {
      Text("Tokens: \(formatTokens(appState.currentUsage.tokens)) / \(formatTokens(tokenLimit))")
    } else {
      ForEach(appState.currentUsage.buckets) { bucket in
        Text("\(bucket.displayName): \(Int(bucket.utilization.rounded()))%")
      }
    }

    if let error = appState.lastError {
      Text(error).foregroundStyle(.red)
    }

    if let lastSync = appState.lastSyncTime {
      Text("Updated \(lastSync.formatted(.relative(presentation: .named)))")
        .foregroundStyle(.secondary)
    }

    Divider()

    Button("Dashboard") {
      NSApp.activate(ignoringOtherApps: true)
      openWindow(id: "usage")
    }
    .keyboardShortcut("d")

    Button(appState.isSyncing ? "Syncing…" : "Sync Now") {
      appState.performSync(force: true)
    }
    .keyboardShortcut("r")
    .disabled(appState.isSyncing)

    Divider()

    SettingsLink { Text("Settings…") }
      .keyboardShortcut(",")

    CheckForUpdatesView(updater: updater)

    Divider()
    Button("Quit") { NSApplication.shared.terminate(nil) }
      .keyboardShortcut("q")
  }
}

// MARK: - Main App Scene

@main
struct ClaudiusApp: App {
  @StateObject private var appState = AppState()
  @AppStorage("MenuBarIconStyle") private var menuBarStyleRaw: String = MenuBarIconStyle.bars.rawValue
  private let updaterController: SPUStandardUpdaterController

  init() {
    updaterController = SPUStandardUpdaterController(
      startingUpdater: true,
      updaterDelegate: nil,
      userDriverDelegate: nil
    )
  }

  private var menuBarStyle: MenuBarIconStyle {
    MenuBarIconStyle(rawValue: menuBarStyleRaw) ?? .bars
  }

  private var costLimit: Double {
    let v = UserDefaults.standard.double(forKey: "CostLimit")
    return v > 0 ? v : 5.0
  }

  private var tokenLimit: Int {
    let v = UserDefaults.standard.integer(forKey: "TokenLimit")
    return v > 0 ? v : 44_000
  }

  /// Session utilization (0…1). Falls back to local tokens / tokenLimit when web data isn't available.
  private var sessionPct: Double {
    if let webPct = appState.currentUsage.fiveHourUtilization {
      return min(webPct / 100.0, 1.0)
    }
    guard tokenLimit > 0 else { return 0 }
    return min(Double(appState.currentUsage.tokens) / Double(tokenLimit), 1.0)
  }

  /// What the menu bar actually draws: every reported bucket, in order,
  /// capped at `BarMetrics.maxBars`. Falls back to a single locally-estimated
  /// session bar when there's no web data.
  private var menuData: [MenuBarDatum] {
    let buckets = appState.currentUsage.buckets
    guard buckets.isEmpty else {
      return buckets.prefix(BarMetrics.maxBars).map {
        MenuBarDatum(id: $0.id, pct: $0.fraction, color: $0.color)
      }
    }
    return [MenuBarDatum(
      id: "session",
      pct: sessionPct,
      color: BarMetrics.localSessionColor(for: sessionPct)
    )]
  }

  /// Color used by the legacy `.sessionPercent` style — preserves prior thresholds.
  private var legacyColor: Color {
    let pct: Double
    if let webPct = appState.currentUsage.fiveHourUtilization {
      pct = webPct / 100.0
    } else {
      pct = min(appState.currentUsage.cost / costLimit, 1.0)
    }
    if pct < 0.75 { return .green }
    if pct < 0.90 { return .yellow }
    return .red
  }

  var body: some Scene {
    MenuBarExtra {
      MenuContent(updater: updaterController.updater)
        .environmentObject(appState)
    } label: {
      MenuBarLabel(
        data: menuData,
        isSyncing: appState.isSyncing,
        style: menuBarStyle,
        legacySessionPct: sessionPct,
        legacyColor: legacyColor
      )
    }

    Window("Claude Usage", id: "usage") {
      UsageView()
        .environmentObject(appState)
    }
    .windowResizability(.contentSize)

    Settings {
      SettingsView(currentUsage: $appState.currentUsage)
        .frame(width: 420)
    }
  }
}
