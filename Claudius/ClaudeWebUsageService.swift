//
//  ClaudeWebUsageService.swift
//  Claudius
//
//  Fetches usage data from the Anthropic OAuth API using Claude Code's
//  OAuth token stored in the macOS Keychain.
//
//  The response shape is treated as unstable on purpose — see UsageBucket.swift
//  for why. This file's job is transport and diagnostics; all decoding and
//  bucket merging lives in the domain model so it can be unit-tested.
//

import Foundation

/// Represents the data source used for usage stats.
enum UsageDataSource: String {
  case web = "claude.ai"
  case local = "local logs"
}

// MARK: - Web Usage Service

struct ClaudeWebUsageService {

  /// The host Claudius has always used. Kept primary because it works today.
  private static let primaryEndpoint = "https://platform.claude.com/api/oauth/usage"
  /// Overwhelmingly the more common host in the wild — used only as a fallback,
  /// so a deprecation of the primary degrades instead of going dark.
  private static let fallbackEndpoint = "https://api.anthropic.com/api/oauth/usage"

  private static var userAgent: String {
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    return "Claudius/\(version) (macOS)"
  }

  private enum FetchOutcome {
    case ok(Data)
    /// Bad or expired token — trying another host won't help.
    case unauthorized
    /// This host is unhappy; the other one might not be.
    case tryOtherHost(String)
    case failed(String)
  }

  /// Attempts to fetch usage stats using the OAuth token from Claude Code's Keychain entry.
  /// Returns nil if the token is missing or the fetch fails.
  /// `force` is passed through to token acquisition so an explicit Sync Now
  /// retries even after a denied keychain prompt.
  static func fetchUsage(force: Bool = false) async -> UsageStats? {
    guard let accessToken = await KeychainHelper.shared.readClaudeOAuthToken(force: force) else {
      print("Claudius Web: No Claude Code OAuth token found in Keychain")
      return nil
    }

    for endpoint in [primaryEndpoint, fallbackEndpoint] {
      switch await fetch(endpoint: endpoint, token: accessToken) {
      case .ok(let data):
        if endpoint != primaryEndpoint {
          print("Claudius Web: primary host failed; answered by \(endpoint)")
        }
        dumpRawResponseIfRequested(data)
        return decode(data)

      case .unauthorized:
        return nil

      case .tryOtherHost(let reason):
        print("Claudius Web: \(endpoint) — \(reason); trying fallback host")
        continue

      case .failed(let reason):
        print("Claudius Web: \(endpoint) — \(reason)")
        return nil
      }
    }

    return nil
  }

  // MARK: - Transport

  private static func fetch(endpoint: String, token: String) async -> FetchOutcome {
    guard let url = URL(string: endpoint) else { return .failed("bad endpoint URL") }

    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
    request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

    // Retry up to 3 times with backoff for rate limiting
    for attempt in 0..<3 {
      if attempt > 0 {
        let delay = UInt64(pow(2.0, Double(attempt))) * 1_000_000_000
        try? await Task.sleep(nanoseconds: delay)
      }

      do {
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
          return .failed("not an HTTP response")
        }

        switch httpResponse.statusCode {
        case 200:
          return .ok(data)

        case 401:
          // The token itself is bad. A different host won't fix that.
          print("Claudius Web: \(endpoint) — OAuth token rejected (HTTP 401)")
          return .unauthorized

        case 429:
          print("Claudius Web: Rate limited, retrying (attempt \(attempt + 1)/3)...")
          continue

        case 403, 404, 500...599:
          return .tryOtherHost("HTTP \(httpResponse.statusCode)")

        default:
          return .failed("HTTP \(httpResponse.statusCode)")
        }
      } catch {
        return .tryOtherHost("request error: \(error.localizedDescription)")
      }
    }

    return .failed("rate limited after 3 retries")
  }

  // MARK: - Decoding

  static func decode(_ data: Data) -> UsageStats? {
    do {
      let response = try JSONDecoder().decode(OAuthUsageResponse.self, from: data)
      return buildStats(from: response)
    } catch {
      print("Claudius Web: Failed to decode usage response: \(error)")
      return nil
    }
  }

  /// Converts the decoded response into UsageStats.
  static func buildStats(from response: OAuthUsageResponse) -> UsageStats {
    var stats = UsageStats()
    stats.dataSource = .web
    stats.buckets = UsageBucket.merge(from: response)

    // Legacy convenience fields. `fiveHourUtilization != nil` is the app-wide
    // "we have web data" discriminator, so these stay populated.
    let session = stats.buckets.first { $0.role == .session }
    let weekly  = stats.buckets.first { $0.role == .weeklyAll }

    stats.fiveHourUtilization = session?.utilization
    stats.fiveHourResetsAt    = session?.resetsAt
    stats.sevenDayUtilization = weekly?.utilization
    stats.sevenDayResetsAt    = weekly?.resetsAt

    // Read the plan's token limit from UserDefaults (set via SettingsView)
    let tokenLimit = UserDefaults.standard.integer(forKey: "TokenLimit")
    let costLimit = UserDefaults.standard.double(forKey: "CostLimit")

    if let session {
      let pct = session.fraction

      if tokenLimit > 0 {
        stats.tokens = Int(pct * Double(tokenLimit))
      }
      if costLimit > 0 {
        stats.cost = pct * costLimit
      }

      if let resetDate = session.resetsAt {
        stats.oldestMessageDate = resetDate.addingTimeInterval(-5 * 60 * 60)
        stats.newestMessageDate = Date()
      }
    }

    logCensus(stats.buckets, response: response)
    return stats
  }

  // MARK: - Diagnostics

  /// Logs what was actually found. Deliberately distinguishes "absent" from
  /// "zero" — conflating them is what would make a renamed field invisible.
  private static func logCensus(_ buckets: [UsageBucket], response: OAuthUsageResponse) {
    let summary = buckets
      .map { "\($0.displayName)=\(String(format: "%.1f", $0.utilization))%" }
      .joined(separator: ", ")
    print("Claudius Web: \(buckets.count) bucket(s): \(summary.isEmpty ? "none" : summary)")

    let consumed: Set<String> = ["five_hour", "seven_day"]
    let unusedWindows = response.windows.keys.filter {
      !consumed.contains($0) && !$0.hasPrefix("seven_day_")
    }
    if !unusedWindows.isEmpty {
      print("Claudius Web: ignored unrecognized window key(s): \(unusedWindows.sorted().joined(separator: ", "))")
    }
    if !response.unmappedKeys.isEmpty {
      print("Claudius Web: key(s) with no utilization: \(response.unmappedKeys.sorted().joined(separator: ", "))")
    }
  }

  /// Writes the raw response body to ~/Library/Logs/Claudius/ when the hidden
  /// `DumpUsageJSON` default is set. This is how you capture what your own
  /// account actually returns:
  ///   defaults write comm.claudius.app DumpUsageJSON -bool YES
  private static func dumpRawResponseIfRequested(_ data: Data) {
    guard UserDefaults.standard.bool(forKey: "DumpUsageJSON") else { return }

    let dir = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Logs/Claudius", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let stamp = ISO8601DateFormatter().string(from: Date())
      .replacingOccurrences(of: ":", with: "-")
    let url = dir.appendingPathComponent("usage-\(stamp).json")

    do {
      try data.write(to: url)
      print("Claudius Web: wrote raw usage response to \(url.path)")
    } catch {
      print("Claudius Web: could not write usage dump: \(error)")
    }
  }
}
