import Foundation

struct UsageStats {
  var cost: Double = 0.0
  var tokens: Int = 0
  var messages: Int = 0
  var oldestMessageDate: Date? = nil
}
