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
}
