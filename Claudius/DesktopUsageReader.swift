//
//  DesktopUsageReader.swift
//  Claudius
//
//  Reads the usage snapshot the Claude desktop app already caches on disk.
//
//  Claudius was built around the OAuth token that the Claude Code *CLI* stores
//  in the Keychain (service "Claude Code-credentials"). That premise quietly
//  stopped holding for anyone who runs Claude Code through the desktop app:
//  the desktop app keeps its credentials in its own encrypted store, so the
//  CLI's Keychain item is simply never updated again. Its access token expires
//  within hours and its refresh token dies with it, which surfaces as an
//  unrecoverable HTTP 400 on refresh — the app looks "broken" while the real
//  problem is that it is reading an abandoned credential store.
//
//  The desktop app polls usage itself every ~15 minutes and writes the result
//  to plan-usage-history.json. Reading that file needs no token, no network
//  request, and no Keychain access — so it cannot expire, cannot prompt, and
//  cannot be rate limited. For a desktop-app user it is strictly better than
//  the API path.
//
//  Caveat: this is an undocumented internal file, exactly like the Keychain
//  item it replaces. It is therefore a *preferred* source, not the only one —
//  when it is missing or stale, the API and local-log paths still run.
//

import Foundation

struct DesktopUsageReader {

  /// Where the desktop app caches its usage samples.
  static var defaultPath: String {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/Claude/plan-usage-history.json")
      .path
  }

  /// The desktop app samples every ~15 minutes. Three intervals of slack keeps
  /// a briefly-closed app from dropping us to local estimates, while still
  /// refusing to present genuinely stale numbers as current.
  static let maxSampleAge: TimeInterval = 45 * 60

  /// Samples stamped slightly in the future are benign clock jitter; anything
  /// beyond this is a wrong clock or a garbage timestamp. Without a lower
  /// bound the staleness guard accepts *any* future date, and `max(by:)`
  /// actively prefers the most future sample — so one bad row would win
  /// permanently and pin the display to its values.
  static let maxClockSkew: TimeInterval = 5 * 60

  // MARK: Wire format

  private struct History: Decodable {
    let samples: [Sample]

    struct Sample: Decodable {
      /// Epoch milliseconds.
      let t: Double
      let u: Buckets?

      struct Buckets: Decodable {
        /// Five-hour session utilization, 0...100.
        let fh: Double?
        /// Seven-day utilization, 0...100.
        let sd: Double?
      }
    }
  }

  // MARK: Read

  /// Returns usage from the desktop app's cache, or nil when the file is
  /// absent, unreadable, empty, or too old to trust.
  static func readUsage(
    path: String = defaultPath,
    now: Date = Date(),
    maxAge: TimeInterval = maxSampleAge
  ) -> UsageStats? {
    guard let data = FileManager.default.contents(atPath: path) else { return nil }

    let history: History
    do {
      history = try JSONDecoder().decode(History.self, from: data)
    } catch {
      print("Claudius Desktop: could not decode \(path): \(error)")
      return nil
    }

    // Samples are appended in order, but don't rely on that.
    guard let latest = history.samples.max(by: { $0.t < $1.t }) else { return nil }

    let sampledAt = Date(timeIntervalSince1970: latest.t / 1000)
    let age = now.timeIntervalSince(sampledAt)
    guard age <= maxAge else {
      print("Claudius Desktop: newest sample is \(Int(age / 60))m old (limit \(Int(maxAge / 60))m) — ignoring")
      return nil
    }
    guard age >= -maxClockSkew else {
      print("Claudius Desktop: newest sample is dated \(Int(-age / 60))m in the future — ignoring")
      return nil
    }

    var buckets: [UsageBucket] = []
    if let fiveHour = latest.u?.fh {
      buckets.append(UsageBucket(
        id: "session",
        role: .session,
        displayName: "Session",
        shortLabel: "Sess",
        utilization: fiveHour,
        // The desktop cache carries no reset timestamps, so countdowns are
        // omitted rather than invented.
        resetsAt: nil,
        severity: nil
      ))
    }
    if let sevenDay = latest.u?.sd {
      buckets.append(UsageBucket(
        id: "weekly",
        role: .weeklyAll,
        displayName: "Weekly (all)",
        shortLabel: "Week",
        utilization: sevenDay,
        resetsAt: nil,
        severity: nil
      ))
    }

    guard !buckets.isEmpty else { return nil }

    var stats = UsageStats()
    stats.dataSource = .desktop
    stats.buckets = buckets
    stats.fiveHourUtilization = latest.u?.fh
    stats.sevenDayUtilization = latest.u?.sd

    // Mirror the API path's synthetic token/cost figures so the local-mode UI
    // and Tidbyt local layouts keep working off the same numbers.
    let tokenLimit = UserDefaults.standard.integer(forKey: "TokenLimit")
    let costLimit = UserDefaults.standard.double(forKey: "CostLimit")
    if let fiveHour = latest.u?.fh {
      let fraction = min(max(fiveHour / 100.0, 0), 1)
      if tokenLimit > 0 { stats.tokens = Int(fraction * Double(tokenLimit)) }
      if costLimit > 0 { stats.cost = fraction * costLimit }
    }

    print("Claudius Desktop: usage from cache (\(Int(age / 60))m old) — " +
          buckets.map { "\($0.displayName)=\(Int($0.utilization.rounded()))%" }.joined(separator: ", "))
    return stats
  }
}
