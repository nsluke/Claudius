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

  init() {
    // Show real local numbers immediately, without requiring Tidbyt credentials.
    let local = TidbytManager.readTodayUsage()
    currentUsage = local

    // Then attempt a full push in the background.
    performSync()

    timerCancellable = Timer.publish(every: 900, on: .main, in: .common)
      .autoconnect()
      .sink { [weak self] _ in self?.performSync() }
  }

  /// Reads local JSONL files and pushes to Tidbyt.
  /// A missing Tidbyt token is a silent no-op (no error shown).
  func performSync() {
    guard !isSyncing else { return }
    isSyncing = true
    lastError = nil

    Task {
      let result = await TidbytManager.fetchAndPush()
      await MainActor.run {
        if let result {
          self.currentUsage = result
          self.lastSyncTime = Date()
        } else {
          // Refresh local data even when push fails.
          self.currentUsage = TidbytManager.readTodayUsage()
          let hasCredentials =
            KeychainHelper.shared.read(service: "ClaudeTidbyt", account: "TidbytToken") != nil &&
            UserDefaults.standard.string(forKey: "TidbytDeviceID") != nil
          if hasCredentials {
            self.lastError = "Push failed — check Tidbyt credentials"
          }
        }
        self.isSyncing = false
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
    Text("Cost: $\(appState.currentUsage.cost, specifier: "%.2f") / $\(costLimit, specifier: "%.2f")")
    Text("Tokens: \(formatTokens(appState.currentUsage.tokens)) / \(formatTokens(tokenLimit))")
    Text("Messages: \(appState.currentUsage.messages)")

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
      appState.performSync()
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

  var body: some Scene {
    MenuBarExtra(appState.isSyncing ? "Claude: …" : "Claude: $\(appState.currentUsage.cost, specifier: "%.2f")", systemImage: "terminal.fill") {
      MenuContent()
        .environmentObject(appState)
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
