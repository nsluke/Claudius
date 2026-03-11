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

  private func formatInterval(_ date: Date?) -> String {
    guard let date else { return "N/A" }
    let seconds = date.addingTimeInterval(5 * 60 * 60).timeIntervalSinceNow
    if seconds <= 0 { return "Now" }
    let h = Int(seconds) / 3600
    let m = Int(seconds) / 60 % 60
    return h > 0 ? "\(h)h \(m)m" : "\(m)m"
  }

  private var nextDropIn: String {
    formatInterval(appState.currentUsage.oldestMessageDate)
  }

  private var fullyClearIn: String {
    formatInterval(appState.currentUsage.newestMessageDate)
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

        TokenTimeSeriesChart(
          buckets: appState.currentUsage.tokenTimeSeries,
          color: tokenColor
        )

        Text("These figures are estimates. Anthropic uses a 5-hour sliding window — each message ages out individually 5 hours after it was sent, so usage decreases gradually rather than resetting all at once.")
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)

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
            Text("Next drop")
              .font(.caption)
              .foregroundStyle(.secondary)
            Text(nextDropIn)
              .font(.system(.body, design: .monospaced).bold())
          }
          Spacer()
          VStack(alignment: .trailing, spacing: 4) {
            Text("Fully clear")
              .font(.caption)
              .foregroundStyle(.secondary)
            Text(fullyClearIn)
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

// MARK: - Token Time Series Chart

private struct TokenTimeSeriesChart: View {
  let buckets: [Int]
  let color: Color

  private var maxValue: Int { buckets.max() ?? 1 }

  /// Format a bucket's token count for the tooltip.
  private func formatTokens(_ t: Int) -> String {
    t >= 1_000
      ? String(format: "%.1fk", Double(t) / 1_000)
      : "\(t)"
  }

  /// Label for the time axis — shows hours ago.
  private func timeLabel(for index: Int) -> String {
    let minutesAgo = (29 - index) * 10
    let h = minutesAgo / 60
    return minutesAgo == 0 ? "now" : "\(h)h"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Output tokens · 5h")
        .font(.subheadline)
        .foregroundStyle(.secondary)

      GeometryReader { geo in
        let barWidth = (geo.size.width - CGFloat(buckets.count - 1)) / CGFloat(buckets.count)
        let chartHeight = geo.size.height

        HStack(alignment: .bottom, spacing: 1) {
          ForEach(Array(buckets.enumerated()), id: \.offset) { index, value in
            let fraction = maxValue > 0 ? CGFloat(value) / CGFloat(maxValue) : 0
            RoundedRectangle(cornerRadius: 1.5)
              .fill(value > 0 ? color.opacity(0.4 + 0.6 * Double(fraction)) : Color(hex: "#222222"))
              .frame(width: barWidth, height: max(value > 0 ? 2 : 1, chartHeight * fraction))
              .help("\(formatTokens(value)) tokens · \(timeLabel(for: index))")
          }
        }
      }
      .frame(height: 48)

      // Time axis labels
      HStack {
        Text("5h ago")
          .font(.system(size: 9))
          .foregroundStyle(.quaternary)
        Spacer()
        Text("2.5h")
          .font(.system(size: 9))
          .foregroundStyle(.quaternary)
        Spacer()
        Text("now")
          .font(.system(size: 9))
          .foregroundStyle(.quaternary)
      }
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
