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

private struct MenuBarLabel: View {
  let sessionPct: Double          // 0...1, always defined (falls back to local tokens/limit)
  let weeklyPct: Double?          // nil when web data unavailable
  let isSyncing: Bool
  let style: MenuBarIconStyle
  let legacyColor: Color          // for `.sessionPercent`, mirrors prior behavior

  var body: some View {
    switch style {
    case .bars:
      RenderedToImage {
        MenuBarBars(sessionPct: sessionPct, weeklyPct: weeklyPct)
      }
      .opacity(isSyncing ? 0.5 : 1)
    case .numbers:
      RenderedToImage {
        MenuBarNumbers(sessionPct: sessionPct, weeklyPct: weeklyPct)
      }
      .opacity(isSyncing ? 0.5 : 1)
    case .barsAndNumbers:
      RenderedToImage {
        MenuBarBarsAndNumbers(sessionPct: sessionPct, weeklyPct: weeklyPct)
      }
      .opacity(isSyncing ? 0.5 : 1)
    case .sessionPercent:
      let pct = Int((sessionPct * 100).rounded())
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
  let sessionPct: Double
  let weeklyPct: Double?

  var body: some View {
    VStack(spacing: BarMetrics.gap) {
      MiniBar(pct: sessionPct, color: BarMetrics.sessionColor(for: sessionPct))
      if let weeklyPct {
        MiniBar(pct: weeklyPct, color: BarMetrics.weeklyColor(for: weeklyPct))
      }
    }
  }
}

private struct MenuBarNumbers: View {
  let sessionPct: Double
  let weeklyPct: Double?

  private static func textColor(for pct: Double) -> Color {
    pct >= 0.9 ? .red : .primary
  }

  private static let numberFont: Font = .system(size: 11, weight: .semibold, design: .monospaced)

  var body: some View {
    VStack(alignment: .leading, spacing: BarMetrics.gap) {
      Text("\(Int((sessionPct * 100).rounded()))")
        .font(Self.numberFont)
        .foregroundStyle(Self.textColor(for: sessionPct))
      if let weeklyPct {
        Text("\(Int((weeklyPct * 100).rounded()))")
          .font(Self.numberFont)
          .foregroundStyle(Self.textColor(for: weeklyPct))
      }
    }
  }
}

private struct MenuBarBarsAndNumbers: View {
  let sessionPct: Double
  let weeklyPct: Double?

  // Number rides on the translucent menu bar background — primary for contrast,
  // red only when the matching bar is in alert state (mirrors the bar's signal).
  private static func textColor(for pct: Double) -> Color {
    pct >= 0.9 ? .red : .primary
  }

  private static let numberFont: Font = .system(size: 11, weight: .semibold, design: .monospaced)

  var body: some View {
    VStack(alignment: .leading, spacing: BarMetrics.gap) {
      HStack(spacing: 1) {
        MiniBar(pct: sessionPct, color: BarMetrics.sessionColor(for: sessionPct))
        Text("\(Int((sessionPct * 100).rounded()))")
          .font(Self.numberFont)
          .foregroundStyle(Self.textColor(for: sessionPct))
      }
      if let weeklyPct {
        HStack(spacing: 1) {
          MiniBar(pct: weeklyPct, color: BarMetrics.weeklyColor(for: weeklyPct))
          Text("\(Int((weeklyPct * 100).rounded()))")
            .font(Self.numberFont)
            .foregroundStyle(Self.textColor(for: weeklyPct))
        }
      }
    }
  }
}

private struct MiniBar: View {
  let pct: Double
  let color: Color

  var body: some View {
    ZStack(alignment: .leading) {
      RoundedRectangle(cornerRadius: BarMetrics.corner)
        .fill(Color.gray.opacity(0.45))
        .frame(width: BarMetrics.width, height: BarMetrics.height)
      RoundedRectangle(cornerRadius: BarMetrics.corner)
        .fill(color)
        .frame(width: BarMetrics.width * CGFloat(min(max(pct, 0), 1)), height: BarMetrics.height)
        .animation(.easeOut(duration: 0.3), value: pct)
    }
  }
}

private enum BarMetrics {
  static let width: CGFloat = 22
  static let height: CGFloat = 8
  static let corner: CGFloat = 1.5
  static let gap: CGFloat = 0

  // Mirror UsageView's palette: session green / weekly Claude-orange, both flip red ≥ 90%.
  static func sessionColor(for pct: Double) -> Color {
    pct < 0.9 ? Color(red: 0x4c / 255, green: 0xaf / 255, blue: 0x50 / 255) : .red
  }
  static func weeklyColor(for pct: Double) -> Color {
    pct < 0.9 ? Color(red: 0xd9 / 255, green: 0x77 / 255, blue: 0x57 / 255) : .red
  }
}

/// Sample-data rendition of a menu-bar style. Used by the settings picker;
/// renders SwiftUI directly (Shapes paint fine inside a normal window).
struct MenuBarStylePreview: View {
  let style: MenuBarIconStyle

  private static let sampleSession: Double = 0.45
  private static let sampleWeekly: Double = 0.70

  var body: some View {
    switch style {
    case .bars:
      MenuBarBars(sessionPct: Self.sampleSession, weeklyPct: Self.sampleWeekly)
    case .numbers:
      MenuBarNumbers(sessionPct: Self.sampleSession, weeklyPct: Self.sampleWeekly)
    case .barsAndNumbers:
      MenuBarBarsAndNumbers(sessionPct: Self.sampleSession, weeklyPct: Self.sampleWeekly)
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
  private var lastPushedUtilization: Double = -1

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

  /// Fetches usage — tries OAuth API first, falls back to local JSONL.
  /// Then pushes to Tidbyt if credentials are set.
  func performSync(force: Bool = false) {
    guard !isSyncing else { return }
    isSyncing = true
    lastError = nil

    Task {
      // Try OAuth API first (reads token from Claude Code's Keychain entry)
      var stats: UsageStats?
      stats = await ClaudeWebUsageService.fetchUsage()
      if stats == nil {
        print("Claudius: OAuth fetch failed, falling back to local logs")
        await MainActor.run { self.lastError = "OAuth fetch failed — using local logs" }
      }

      // Fall back to local JSONL parsing
      if stats == nil {
        var localStats = TidbytManager.readTodayUsage()
        localStats.dataSource = .local
        stats = localStats
      }

      guard let stats else { return }

      let shouldPush: Bool
      if let webPct = stats.fiveHourUtilization {
        // Web mode: push if utilization changed by at least 1 point
        shouldPush = force || abs(webPct - self.lastPushedUtilization) >= 1.0
      } else {
        // Local mode: push if tokens changed by at least 1%
        let tokenDiff = abs(stats.tokens - self.lastPushedTokens)
        let percentChange = self.lastPushedTokens == 0 ? 1.0 : Double(tokenDiff) / Double(self.lastPushedTokens)
        shouldPush = force || percentChange > 0.01
      }

      if shouldPush {
        let pushed = await TidbytManager.push(stats: stats)
        await MainActor.run {
          self.currentUsage = stats
          if pushed {
            self.lastSyncTime = Date()
            self.lastPushedTokens = stats.tokens
            if let webPct = stats.fiveHourUtilization {
              self.lastPushedUtilization = webPct
            }
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
    if let webPct = appState.currentUsage.fiveHourUtilization {
      Text("Session: \(Int(webPct))%")
    } else {
      Text("Tokens: \(formatTokens(appState.currentUsage.tokens)) / \(formatTokens(tokenLimit))")
    }
    if let sevenDay = appState.currentUsage.sevenDayUtilization {
      Text("Weekly: \(Int(sevenDay))%")
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

  /// Weekly utilization (0…1) when reported by the web API; nil otherwise.
  private var weeklyPct: Double? {
    appState.currentUsage.sevenDayUtilization.map { min($0 / 100.0, 1.0) }
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
        sessionPct: sessionPct,
        weeklyPct: weeklyPct,
        isSyncing: appState.isSyncing,
        style: menuBarStyle,
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
