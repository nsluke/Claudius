import Foundation

struct UsageStats {
  var cost: Double = 0.0
  var tokens: Int = 0
  var messages: Int = 0
  var oldestMessageDate: Date? = nil
  var newestMessageDate: Date? = nil

  /// 30 buckets — each represents 10 minutes of the 5-hour window.
  /// Index 0 is the oldest slot (5h ago), index 29 is the most recent.
  /// Values are total tokens (input + output) during that interval.
  var tokenTimeSeries: [Int] = Array(repeating: 0, count: 30)

  /// Where this data came from — web API or local JSONL parsing.
  var dataSource: UsageDataSource = .local

  // MARK: - Web API fields (from api.anthropic.com/api/oauth/usage)

  /// Every usage window the server reported, in display order: session first,
  /// then the account-wide weekly window, then any model-scoped weekly caps
  /// (Fable and friends). Empty in local-log mode.
  ///
  /// This is the authoritative list. The named fields below are conveniences
  /// derived from it — `fiveHourUtilization != nil` is used app-wide as the
  /// "we have web data" discriminator.
  var buckets: [UsageBucket] = []

  /// 5-hour window utilization percentage (0–100) as reported by claude.ai.
  var fiveHourUtilization: Double? = nil

  /// When the 5-hour window resets.
  var fiveHourResetsAt: Date? = nil

  /// 7-day window utilization percentage (0–100) as reported by claude.ai.
  var sevenDayUtilization: Double? = nil

  /// When the 7-day window resets.
  var sevenDayResetsAt: Date? = nil
}
