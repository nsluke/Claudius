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
  
  var tokenLimit: Int? {
    switch self {
    case .pro:    return 44_000
    case .max5x:  return 88_000
    case .max20x: return 220_000
    case .manual: return nil
    }
  }
  
  var costLimit: Double? {
    switch self {
    case .pro:    return 5.00
    case .max5x:  return 25.00
    case .max20x: return 100.00
    case .manual: return nil
    }
  }
}

struct SettingsView: View {
  @Binding var currentUsage: UsageStats

  @State private var tidbytToken: String = ""
  @State private var deviceID: String = ""
  @State private var costLimit: String = ""
  @State private var tokenLimit: String = ""
  @State private var selectedPlan: ClaudePlan = .manual
  @State private var isSyncing: Bool = false
  @State private var statusMessage: String = ""

  var body: some View {
    Form {
      Section("Tidbyt Credentials (optional)") {
        SecureField("Tidbyt API Token", text: $tidbytToken)
        TextField("Tidbyt Device ID", text: $deviceID)
        Text("These can be found in the Tidbyt app on your phone. Find them by tapping the ⚙️ icon -> Developer -> Get API key")
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
        .onChange(of: selectedPlan) { newValue in
          if newValue != .manual {
            if let tl = newValue.tokenLimit { tokenLimit = "\(tl)" }
            if let cl = newValue.costLimit  { costLimit = String(format: "%.2f", cl) }
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
    .formStyle(.grouped)
    .onAppear(perform: loadKeys)
  }

  private func loadKeys() {
    tidbytToken = KeychainHelper.shared.read(service: "ClaudeTidbyt", account: "TidbytToken") ?? ""
    deviceID    = UserDefaults.standard.string(forKey: "TidbytDeviceID") ?? ""
    
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
      let newUsage = await TidbytManager.fetchAndPush()
      await MainActor.run {
        if let newUsage {
          currentUsage  = newUsage
          statusMessage = "✓ Pushed to Tidbyt"
        } else {
          statusMessage = "✗ Push failed — check Tidbyt token & device ID"
        }
        isSyncing = false
      }
    }
  }
}
