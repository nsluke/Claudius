//
//  ClaudeWebUsageService.swift
//  Claudius
//
//  Fetches usage data directly from claude.ai's internal API.
//

import Foundation

/// Represents the data source used for usage stats.
enum UsageDataSource: String {
  case web = "claude.ai"
  case local = "local logs"
}

// MARK: - API Response Models

/// Usage window from /api/organizations/{orgId}/usage
private struct UsageWindow: Decodable {
  let utilization: Double  // percentage 0–100
  let resets_at: String    // ISO 8601 timestamp
}

/// Full response from /api/organizations/{orgId}/usage
private struct UsageAPIResponse: Decodable {
  let five_hour: UsageWindow?
  let seven_day: UsageWindow?
  let seven_day_oauth_apps: UsageWindow?
  let seven_day_opus: UsageWindow?
  let seven_day_sonnet: UsageWindow?
  let seven_day_cowork: UsageWindow?
  let extra_usage: ExtraUsage?

  struct ExtraUsage: Decodable {
    let is_enabled: Bool?
    let monthly_limit: Double?
    let used_credits: Double?
    let utilization: Double?
  }
}

// MARK: - Web Usage Service

struct ClaudeWebUsageService {

  private static let baseURL = "https://claude.ai"

  /// Attempts to fetch usage stats from claude.ai.
  /// Returns nil if the fetch fails for any reason.
  static func fetchUsage(sessionKey: String, orgId: String) async -> UsageStats? {
    guard !sessionKey.isEmpty, !orgId.isEmpty else {
      print("Claudius Web: Missing session key or org ID")
      return nil
    }

    let endpoint = "\(baseURL)/api/organizations/\(orgId)/usage"
    guard let url = URL(string: endpoint) else { return nil }

    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")
    request.setValue("application/json", forHTTPHeaderField: "content-type")
    request.setValue("*/*", forHTTPHeaderField: "Accept")
    request.setValue("web_claude_ai", forHTTPHeaderField: "anthropic-client-platform")
    request.setValue("1.0.0", forHTTPHeaderField: "anthropic-client-version")
    request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")

    do {
      let (data, response) = try await URLSession.shared.data(for: request)

      guard let httpResponse = response as? HTTPURLResponse else {
        print("Claudius Web: Not an HTTP response")
        return nil
      }

      if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
        print("Claudius Web: Session key expired or invalid (HTTP \(httpResponse.statusCode))")
        return nil
      }

      guard httpResponse.statusCode == 200 else {
        print("Claudius Web: Usage endpoint returned HTTP \(httpResponse.statusCode)")
        return nil
      }

      let usage = try JSONDecoder().decode(UsageAPIResponse.self, from: data)
      return buildStats(from: usage)

    } catch {
      print("Claudius Web: Failed to fetch usage: \(error)")
      return nil
    }
  }

  /// Converts the API response into UsageStats.
  /// The API returns utilization as a percentage (0–100).
  /// We convert to estimated tokens using the configured plan limits.
  private static func buildStats(from usage: UsageAPIResponse) -> UsageStats {
    var stats = UsageStats()
    stats.dataSource = .web

    // Read the plan's token limit from UserDefaults (set via SettingsView)
    let tokenLimit = UserDefaults.standard.integer(forKey: "TokenLimit")
    let costLimit = UserDefaults.standard.double(forKey: "CostLimit")

    if let fiveHour = usage.five_hour {
      let pct = fiveHour.utilization / 100.0

      // Estimate tokens from utilization percentage
      if tokenLimit > 0 {
        stats.tokens = Int(pct * Double(tokenLimit))
      }

      // Estimate cost from utilization percentage
      if costLimit > 0 {
        stats.cost = pct * costLimit
      }

      // Parse resets_at to derive the window start (5 hours before reset)
      if let resetDate = parseISO8601(fiveHour.resets_at) {
        let windowStart = resetDate.addingTimeInterval(-5 * 60 * 60)
        stats.oldestMessageDate = windowStart
        stats.newestMessageDate = resetDate.addingTimeInterval(-5 * 60 * 60)
      }

      // Store the raw utilization for direct display
      stats.fiveHourUtilization = fiveHour.utilization
      stats.fiveHourResetsAt = parseISO8601(fiveHour.resets_at)
    }

    if let sevenDay = usage.seven_day {
      stats.sevenDayUtilization = sevenDay.utilization
      stats.sevenDayResetsAt = parseISO8601(sevenDay.resets_at)
    }

    print("Claudius Web: 5h utilization = \(usage.five_hour?.utilization ?? 0)%, " +
          "7d utilization = \(usage.seven_day?.utilization ?? 0)%")

    return stats
  }

  private static func parseISO8601(_ string: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: string) ?? ISO8601DateFormatter().date(from: string)
  }
}
