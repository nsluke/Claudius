//
//  SettingsView.swift
//  Claudius
//
//  Created by Luke Solomon on 3/10/26.
//

import SwiftUI

struct SettingsView: View {
  @Binding var currentUsage: (cost: Double, tokens: Int)

  @State private var tidbytToken: String = ""
  @State private var deviceID: String = ""
  @State private var costLimit: String = ""
  @State private var tokenLimit: String = ""
  @State private var isSyncing: Bool = false
  @State private var statusMessage: String = ""

  var body: some View {
    Form {
      Section("Tidbyt Credentials") {
        SecureField("Tidbyt API Token", text: $tidbytToken)
        TextField("Tidbyt Device ID", text: $deviceID)
      }

      Section("Daily Budgets") {
        TextField("Cost limit (e.g. 10.00)", text: $costLimit)
        TextField("Token limit (e.g. 50000)", text: $tokenLimit)
      }

      Section("Local Usage Source") {
        LabeledContent("Log directory") {
          Text("~/.claude/projects/")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        LabeledContent("Today's cost") {
          Text("$\(currentUsage.cost, specifier: "%.4f")")
        }
        LabeledContent("Today's tokens") {
          Text("\(currentUsage.tokens)")
        }
      }

      Section {
        HStack {
          Button(isSyncing ? "Syncing…" : "Save & Sync Now") {
            saveAndPush()
          }
          .disabled(isSyncing || tidbytToken.isEmpty || deviceID.isEmpty)

          if !statusMessage.isEmpty {
            Text(statusMessage)
              .foregroundStyle(statusMessage.hasPrefix("✓") ? .green : .red)
              .font(.caption)
          }
        }
      }
    }
    .padding()
    .onAppear(perform: loadKeys)
  }

  private func loadKeys() {
    tidbytToken = KeychainHelper.shared.read(service: "ClaudeTidbyt", account: "TidbytToken") ?? ""
    deviceID    = UserDefaults.standard.string(forKey: "TidbytDeviceID") ?? ""
    let cl = UserDefaults.standard.double(forKey: "CostLimit")
    costLimit   = cl > 0 ? String(format: "%.2f", cl) : ""
    let tl = UserDefaults.standard.integer(forKey: "TokenLimit")
    tokenLimit  = tl > 0 ? "\(tl)" : ""
  }

  private func saveAndPush() {
    isSyncing = true
    statusMessage = ""

    if let tData = tidbytToken.data(using: .utf8) {
      KeychainHelper.shared.save(tData, service: "ClaudeTidbyt", account: "TidbytToken")
    }
    UserDefaults.standard.set(deviceID, forKey: "TidbytDeviceID")
    if let cl = Double(costLimit)  { UserDefaults.standard.set(cl,  forKey: "CostLimit") }
    if let tl = Int(tokenLimit)    { UserDefaults.standard.set(tl,  forKey: "TokenLimit") }

    Task {
      let newUsage = await TidbytManager.fetchAndPush()
      await MainActor.run {
        if let newUsage {
          currentUsage  = newUsage
          statusMessage = "✓ Pushed to Tidbyt"
        } else {
          statusMessage = "✗ Sync failed — check Tidbyt token & device ID"
        }
        isSyncing = false
      }
    }
  }
}
