//
//  ClaudiusApp.swift
//  Claudius
//
//  Created by Luke Solomon on 3/10/26.
//

import SwiftUI
import Combine

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

    timerCancellable = Timer.publish(every: 60, on: .main, in: .common)
      .autoconnect()
      .sink { [weak self] _ in self?.performSync(force: false) }
  }

  /// Fetches usage — tries claude.ai web API first, falls back to local JSONL.
  /// Then pushes to Tidbyt if credentials are set.
  func performSync(force: Bool = false) {
    guard !isSyncing else { return }
    isSyncing = true
    lastError = nil

    Task {
      // Try web API first if session key + org ID are configured
      var stats: UsageStats?
      let sessionKey = KeychainHelper.shared.read(service: "ClaudeSession", account: "SessionKey") ?? ""
      let orgId = UserDefaults.standard.string(forKey: "ClaudeOrgID") ?? ""

      if !sessionKey.isEmpty && !orgId.isEmpty {
        stats = await ClaudeWebUsageService.fetchUsage(sessionKey: sessionKey, orgId: orgId)
        if stats == nil {
          print("Claudius: Web fetch failed, falling back to local logs")
          await MainActor.run { self.lastError = "Web fetch failed — using local logs" }
        }
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

    Divider()
    Button("Quit") { NSApplication.shared.terminate(nil) }
      .keyboardShortcut("q")
  }
}

// MARK: - Main App Scene

@main
struct ClaudiusApp: App {
  @StateObject private var appState = AppState()

  private var costLimit: Double {
    let v = UserDefaults.standard.double(forKey: "CostLimit")
    return v > 0 ? v : 5.0
  }
  
  private var usageColor: Color {
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

  private var tokenLimit: Int {
    let v = UserDefaults.standard.integer(forKey: "TokenLimit")
    return v > 0 ? v : 44_000
  }

  var body: some Scene {
    MenuBarExtra {
      MenuContent()
        .environmentObject(appState)
    } label: {
      let pct: Int = {
        if let webPct = appState.currentUsage.fiveHourUtilization {
          return Int(webPct)
        }
        return tokenLimit > 0 ? Int(Double(appState.currentUsage.tokens) / Double(tokenLimit) * 100) : 0
      }()
      let usageText = appState.isSyncing ? "…" : "\(pct)%"
//      HStack {
//        Image(systemName: "laurel.leading")
        Text( "􁊘 \(usageText) 􁊙")
          .foregroundStyle(usageColor)
//      }
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
