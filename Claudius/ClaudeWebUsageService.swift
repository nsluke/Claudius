//
//  ClaudeWebUsageService.swift
//  Claudius
//
//  Fetches usage data from the Anthropic OAuth API using Claude Code's
//  OAuth token stored in the macOS Keychain.
//

import Foundation

/// Represents the data source used for usage stats.
enum UsageDataSource: String {
  case web = "claude.ai"
  case local = "local logs"
}

// MARK: - API Response Models

/// Usage period from /api/oauth/usage
private struct UsagePeriod: Decodable {
  let utilization: Double  // percentage 0–100
  let resets_at: String    // ISO 8601 timestamp
}

/// Full response from /api/oauth/usage
private struct OAuthUsageResponse: Decodable {
  let five_hour: UsagePeriod?
  let seven_day: UsagePeriod?

}

// MARK: - Web Usage Service

struct ClaudeWebUsageService {

  private static let endpoint = "https://platform.claude.com/api/oauth/usage"

  /// Attempts to fetch usage stats using the OAuth token from Claude Code's Keychain entry.
  /// Returns nil if the token is missing or the fetch fails.
  static func fetchUsage() async -> UsageStats? {
    guard let accessToken = await KeychainHelper.shared.readClaudeOAuthToken() else {
      print("Claudius Web: No Claude Code OAuth token found in Keychain")
      return nil
    }

    guard let url = URL(string: endpoint) else { return nil }

    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

    // Retry up to 3 times with backoff for rate limiting
    for attempt in 0..<3 {
      if attempt > 0 {
        let delay = UInt64(pow(2.0, Double(attempt))) * 1_000_000_000
        try? await Task.sleep(nanoseconds: delay)
      }

      do {
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
          print("Claudius Web: Not an HTTP response")
          return nil
        }

        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
          print("Claudius Web: OAuth token expired or invalid (HTTP \(httpResponse.statusCode))")
          return nil
        }

        if httpResponse.statusCode == 429 {
          print("Claudius Web: Rate limited, retrying (attempt \(attempt + 1)/3)...")
          continue
        }

        guard httpResponse.statusCode == 200 else {
          print("Claudius Web: Usage endpoint returned HTTP \(httpResponse.statusCode)")
          return nil
        }

        let usage = try JSONDecoder().decode(OAuthUsageResponse.self, from: data)
        return buildStats(from: usage)

      } catch {
        print("Claudius Web: Failed to fetch usage: \(error)")
        return nil
      }
    }

    print("Claudius Web: Usage fetch failed after 3 retries (rate limited)")
    return nil
  }

  /// Converts the API response into UsageStats.
  private static func buildStats(from usage: OAuthUsageResponse) -> UsageStats {
    var stats = UsageStats()
    stats.dataSource = .web

    // Read the plan's token limit from UserDefaults (set via SettingsView)
    let tokenLimit = UserDefaults.standard.integer(forKey: "TokenLimit")
    let costLimit = UserDefaults.standard.double(forKey: "CostLimit")

    if let fiveHour = usage.five_hour {
      let pct = fiveHour.utilization / 100.0

      if tokenLimit > 0 {
        stats.tokens = Int(pct * Double(tokenLimit))
      }
      if costLimit > 0 {
        stats.cost = pct * costLimit
      }

      if let resetDate = parseISO8601(fiveHour.resets_at) {
        let windowStart = resetDate.addingTimeInterval(-5 * 60 * 60)
        stats.oldestMessageDate = windowStart
        stats.newestMessageDate = Date()
      }

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
