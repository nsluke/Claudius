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
  @Published var currentUsage: (cost: Double, tokens: Int) = (0.0, 0)
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

// MARK: - Main App Scene
@main
struct ClaudeTidbytApp: App {
  @StateObject private var appState = AppState()

  var body: some Scene {
    MenuBarExtra(appState.isSyncing ? "Claude: …" : "Claude: $\(appState.currentUsage.cost, specifier: "%.2f")", systemImage: "terminal.fill") {
      Text("Cost: $\(appState.currentUsage.cost, specifier: "%.2f")")
      Text("Tokens: \(appState.currentUsage.tokens)")

      if let error = appState.lastError {
        Text(error)
          .foregroundStyle(.red)
      }

      if let lastSync = appState.lastSyncTime {
        Text("Last sync: \(lastSync.formatted(.relative(presentation: .named)))")
          .foregroundStyle(.secondary)
      }

      Divider()

      Button(appState.isSyncing ? "Syncing…" : "Sync Now") {
        appState.performSync()
      }
      .disabled(appState.isSyncing)

      Divider()

      SettingsLink {
        Text("Settings…")
      }

      Divider()
      Button("Quit") { NSApplication.shared.terminate(nil) }
    }

    Settings {
      SettingsView(currentUsage: $appState.currentUsage)
        .frame(width: 420, height: 320)
    }
  }
}
