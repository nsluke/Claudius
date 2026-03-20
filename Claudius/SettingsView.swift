//
//  SettingsView.swift
//  Claudius
//
//  Created by Luke Solomon on 3/10/26.
//

import SwiftUI

enum ClaudePlan: String, CaseIterable, Identifiable {
  case pro      = "Claude Pro"
  case max5x    = "Max 5x"
  case max20x   = "Max 20x"
  case manual   = "Manual"
  
  var id: String { self.rawValue }
  
  /// Token limits per 5-hour window (input + output only).
  /// Matches claude-code-usage-monitor's PLAN_LIMITS.
  var tokenLimit: Int? {
    switch self {
    case .pro:    return 19_000
    case .max5x:  return 88_000
    case .max20x: return 220_000
    case .manual: return nil
    }
  }

  /// Cost limits per 5-hour window (USD).
  /// Matches claude-code-usage-monitor's PLAN_LIMITS.
  var costLimit: Double? {
    switch self {
    case .pro:    return 18.00
    case .max5x:  return 35.00
    case .max20x: return 140.00
    case .manual: return nil
    }
  }
}

enum TidbytLayout: String, CaseIterable, Identifiable {
  case defaultLayout = "Default"
  case minimal = "Minimal"
  case graph = "Graph"
  
  var id: String { self.rawValue }
  
  var starFile: String {
    switch self {
    case .defaultLayout: return "claude_usage"
    case .minimal:       return "claude_minimal"
    case .graph:         return "claude_graph"
    }
  }
}

struct SettingsView: View {
  @Binding var currentUsage: UsageStats

  @State private var oauthTokenFound: Bool = false
  @State private var tidbytToken: String = ""
  @State private var deviceID: String = ""
  @State private var selectedLayout: TidbytLayout = .defaultLayout
  @State private var costLimit: String = ""
  @State private var tokenLimit: String = ""
  @State private var selectedPlan: ClaudePlan = .manual
  @State private var isSyncing: Bool = false
  @State private var statusMessage: String = ""

  var body: some View {
    Form {
      Section("Claude Code OAuth") {
        HStack {
          Image(systemName: oauthTokenFound ? "checkmark.circle.fill" : "xmark.circle.fill")
            .foregroundStyle(oauthTokenFound ? .green : .red)
          Text(oauthTokenFound ? "OAuth token found in Keychain" : "No OAuth token found")
        }

        Text("Claudius reads the OAuth token that Claude Code stores in your macOS Keychain. Make sure Claude Code is installed and you're logged in.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Section("Tidbyt Credentials (optional)") {
        SecureField("Tidbyt API Token", text: $tidbytToken)
        TextField("Tidbyt Device ID", text: $deviceID)

        Picker("Tidbyt Layout", selection: $selectedLayout) {
          ForEach(TidbytLayout.allCases) { layout in
            Text(layout.rawValue).tag(layout)
          }
        }

        Text("Device IDs can be found in the Tidbyt app on your phone. Find them by tapping the ⚙️ icon -> Developer -> Get API key")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Section {
        HStack {
          Button("Save") {
            saveSettings()
          }

          Button(isSyncing ? "Syncing…" : "Push to Tidbyt") {
            saveAndPush()
          }
          .disabled(isSyncing || tidbytToken.isEmpty || deviceID.isEmpty)

          Spacer()

          if !statusMessage.isEmpty {
            Text(statusMessage)
              .foregroundStyle(statusMessage.hasPrefix("✓") ? .green : .red)
              .font(.caption)
          }
        }
      }

      Section("Usage Limits") {
        Picker("Subscription Plan", selection: $selectedPlan) {
          ForEach(ClaudePlan.allCases) { plan in
            Text(plan.rawValue).tag(plan)
          }
        }
        .onChange(of: selectedPlan) {
          if selectedPlan != .manual {
            if let tl = selectedPlan.tokenLimit { tokenLimit = "\(tl)" }
            if let cl = selectedPlan.costLimit  { costLimit = String(format: "%.2f", cl) }
          }
        }

        TextField("Cost limit ($)", text: $costLimit)
          .disabled(selectedPlan != .manual)
        TextField("Token limit", text: $tokenLimit)
          .disabled(selectedPlan != .manual)
        
        if selectedPlan != .manual {
          Text("Limits are automatically set for \(selectedPlan.rawValue). Switch to Manual to override.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      if currentUsage.dataSource == .local {
        Section("Current Window") {
          LabeledContent("Log directory") {
            Text("~/.claude/projects/")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          LabeledContent("Cost") {
            Text("$\(currentUsage.cost, specifier: "%.4f")")
          }
          LabeledContent("Tokens") {
            Text("\(currentUsage.tokens)")
          }
          LabeledContent("Messages") {
            Text("\(currentUsage.messages)")
          }
        }
      }

    }
    .formStyle(.grouped)
    .onAppear(perform: loadKeys)
  }

  private func loadKeys() {
    oauthTokenFound = KeychainHelper.shared.readClaudeOAuthToken() != nil
    tidbytToken = KeychainHelper.shared.read(service: "ClaudeTidbyt", account: "TidbytToken") ?? ""
    deviceID    = UserDefaults.standard.string(forKey: "TidbytDeviceID") ?? ""
    
    if let layoutRaw = UserDefaults.standard.string(forKey: "TidbytLayout"),
       let layout = TidbytLayout(rawValue: layoutRaw) {
      selectedLayout = layout
    }
    
    if let planRaw = UserDefaults.standard.string(forKey: "ClaudePlan"),
       let plan = ClaudePlan(rawValue: planRaw) {
      selectedPlan = plan
    }
    
    let cl = UserDefaults.standard.double(forKey: "CostLimit")
    costLimit   = cl > 0 ? String(format: "%.2f", cl) : ""
    let tl = UserDefaults.standard.integer(forKey: "TokenLimit")
    tokenLimit  = tl > 0 ? "\(tl)" : ""
  }

  private func saveSettings() {
    if let tData = tidbytToken.data(using: .utf8) {
      KeychainHelper.shared.save(tData, service: "ClaudeTidbyt", account: "TidbytToken")
    }
    UserDefaults.standard.set(deviceID, forKey: "TidbytDeviceID")
    UserDefaults.standard.set(selectedLayout.rawValue, forKey: "TidbytLayout")
    UserDefaults.standard.set(selectedPlan.rawValue, forKey: "ClaudePlan")
    if let cl = Double(costLimit)  { UserDefaults.standard.set(cl,  forKey: "CostLimit") }
    if let tl = Int(tokenLimit)    { UserDefaults.standard.set(tl,  forKey: "TokenLimit") }
    statusMessage = "✓ Saved"
  }

  private func saveAndPush() {
    saveSettings()
    isSyncing = true
    statusMessage = ""

    Task {
      // Use OAuth API if available, same as performSync
      var stats: UsageStats?
      stats = await ClaudeWebUsageService.fetchUsage()
      if stats == nil {
        var local = TidbytManager.readTodayUsage()
        local.dataSource = .local
        stats = local
      }
      guard let stats else { return }
      let pushed = await TidbytManager.push(stats: stats)
      await MainActor.run {
        currentUsage = stats
        if pushed {
          statusMessage = "✓ Pushed to Tidbyt"
        } else {
          statusMessage = "✗ Push failed — check Tidbyt token & device ID"
        }
        isSyncing = false
      }
    }
  }
}
