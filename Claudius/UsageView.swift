//
//  UsageView.swift
//  Claudius
//
//  Created by Luke Solomon on 3/11/26.
//

import SwiftUI

struct UsageView: View {
  @EnvironmentObject var appState: AppState

  // Mirror the star file fallback defaults.
  private var costLimit: Double {
    let v = UserDefaults.standard.double(forKey: "CostLimit")
    return v > 0 ? v : 5.0
  }
  private var tokenLimit: Int {
    let v = UserDefaults.standard.integer(forKey: "TokenLimit")
    return v > 0 ? v : 44_000
  }

  private var costPct:  Double { min(appState.currentUsage.cost / costLimit, 1.0) }
  private var tokenPct: Double { min(Double(appState.currentUsage.tokens) / Double(tokenLimit), 1.0) }

  private var costColor:  Color { costPct  < 0.9 ? Color(hex: "#d97757") : .red }
  private var tokenColor: Color { tokenPct < 0.9 ? Color(hex: "#4caf50") : .red }

  private var formattedTokens: String {
    let t = appState.currentUsage.tokens
    return t >= 1_000_000
      ? String(format: "%.1fM", Double(t) / 1_000_000)
      : t >= 1_000
        ? String(format: "%.1fk", Double(t) / 1_000)
        : "\(t)"
  }

  private var timeToReset: String {
    guard let oldest = appState.currentUsage.oldestMessageDate else {
      return "N/A"
    }
    let expirationDate = oldest.addingTimeInterval(5 * 60 * 60)
    let timeInterval = expirationDate.timeIntervalSinceNow
    
    if timeInterval <= 0 {
      return "Now"
    }
    
    let hours = Int(timeInterval) / 3600
    let minutes = Int(timeInterval) / 60 % 60
    
    if hours > 0 {
        return "\(hours)h \(minutes)m"
    } else {
        return "\(minutes)m"
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      // Header
      HStack {
        Image(systemName: "terminal.fill")
          .foregroundStyle(Color(hex: "#d97757"))
        Text("Claude Code · 5h window")
          .font(.headline)
        Spacer()
        
        SettingsLink {
          Image(systemName: "gearshape")
        }
        .buttonStyle(.plain)
        .help("Settings")

        Button {
          appState.performSync()
        } label: {
          Image(systemName: appState.isSyncing ? "arrow.trianglehead.2.clockwise" : "arrow.clockwise")
        }
        .buttonStyle(.plain)
        .disabled(appState.isSyncing)
        .symbolEffect(.rotate, isActive: appState.isSyncing)
      }
      .padding(.horizontal, 20)
      .padding(.top, 20)
      .padding(.bottom, 16)

      Divider()

      // Metrics
      VStack(spacing: 16) {
        MetricRow(
          label: "Cost",
          value: "$\(String(format: "%.2f", appState.currentUsage.cost))",
          limit: "$\(String(format: "%.2f", costLimit))",
          pct: costPct,
          color: costColor
        )

        MetricRow(
          label: "Tokens",
          value: formattedTokens,
          limit: tokenLimit >= 1_000_000
            ? String(format: "%.0fM", Double(tokenLimit) / 1_000_000)
            : String(format: "%.0fk", Double(tokenLimit) / 1_000),
          pct: tokenPct,
          color: tokenColor
        )

        HStack {
          VStack(alignment: .leading, spacing: 4) {
            Text("Messages")
              .font(.caption)
              .foregroundStyle(.secondary)
            Text("\(appState.currentUsage.messages)")
              .font(.system(.body, design: .monospaced).bold())
          }
          Spacer()
          VStack(alignment: .trailing, spacing: 4) {
            Text("Window clears in")
              .font(.caption)
              .foregroundStyle(.secondary)
            Text(timeToReset)
              .font(.system(.body, design: .monospaced).bold())
          }
        }
        .padding(.top, 8)
      }
      .padding(20)

      Divider()

      // Footer
      HStack {
        if let lastSync = appState.lastSyncTime {
          Text("Synced \(lastSync.formatted(.relative(presentation: .named)))")
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
          Text("Reading local logs")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        if let error = appState.lastError {
          Text(error)
            .font(.caption)
            .foregroundStyle(.red)
        }
      }
      .padding(.horizontal, 20)
      .padding(.vertical, 10)
    }
    .frame(width: 340)
  }
}

// MARK: - Metric Row

private struct MetricRow: View {
  let label: String
  let value: String
  let limit: String
  let pct:   Double
  let color: Color

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .firstTextBaseline) {
        Text(label)
          .font(.subheadline)
          .foregroundStyle(.secondary)
        Spacer()
        Text(value)
          .font(.system(.title2, design: .monospaced).bold())
          .foregroundStyle(color)
        Text("/ \(limit)")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      // Progress bar
      GeometryReader { geo in
        ZStack(alignment: .leading) {
          RoundedRectangle(cornerRadius: 3)
            .fill(Color(hex: "#222222"))
            .frame(height: 6)
          RoundedRectangle(cornerRadius: 3)
            .fill(color)
            .frame(width: geo.size.width * pct, height: 6)
            .animation(.easeOut(duration: 0.4), value: pct)
        }
      }
      .frame(height: 6)

      Text("\(Int(pct * 100))% of limit")
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
  }
}

// MARK: - Hex Color helper

private extension Color {
  init(hex: String) {
    let h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
    var rgb: UInt64 = 0
    Scanner(string: h).scanHexInt64(&rgb)
    self.init(
      red:   Double((rgb >> 16) & 0xFF) / 255,
      green: Double((rgb >> 8)  & 0xFF) / 255,
      blue:  Double( rgb        & 0xFF) / 255
    )
  }
}
