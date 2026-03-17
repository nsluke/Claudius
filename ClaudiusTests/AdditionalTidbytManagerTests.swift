import XCTest
@testable import Claudius

// MARK: - Test Helpers Re-use

private func makeEntry(
  sessionId: String,
  uuid: String = UUID().uuidString,
  timestamp: String, // Use string to test raw date formats
  model: String = "claude-sonnet-4-20250514",
  inputTokens: Int = 1,
  outputTokens: Int = 100,
  cacheCreation: Int = 0,
  cacheRead: Int = 0,
  messageId: String? = nil,
  requestId: String? = nil
) -> String {
  // Build optional fields
  let reqField = requestId.map { ",\"requestId\":\"\($0)\"" } ?? ""
  let msgIdField = messageId.map { "\"id\":\"\($0)\"," } ?? ""

  return """
  {"type":"assistant","timestamp":"\(timestamp)","uuid":"\(uuid)","sessionId":"\(sessionId)"\(reqField),"message":{\(msgIdField)"model":"\(model)","usage":{"input_tokens":\(inputTokens),"output_tokens":\(outputTokens),"cache_creation_input_tokens":\(cacheCreation),"cache_read_input_tokens":\(cacheRead)}}}
  """
}

private func createFixtures(_ files: [String: [String]]) throws -> URL {
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  let fm = FileManager.default

  for (relativePath, lines) in files {
    let fileURL = dir.appendingPathComponent(relativePath)
    try fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let content = lines.joined(separator: "\n") + "\n"
    try content.write(to: fileURL, atomically: true, encoding: .utf8)
  }

  return dir
}

private func cleanupFixtures(_ dir: URL) {
  try? FileManager.default.removeItem(at: dir)
}

// MARK: - Additional Tests

final class AdditionalPricingTests: XCTestCase {

  /// Unknown models should default to Sonnet pricing.
  func testUnknownModelDefaultsToSonnet() throws {
    let now = Date()
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let ts = iso.string(from: now.addingTimeInterval(-60))

    let dir = try createFixtures([
      "project/session.jsonl": [
        makeEntry(sessionId: "s1", timestamp: ts, model: "claude-future-ultra",
                  inputTokens: 1_000_000, outputTokens: 0)
      ]
    ])
    defer { cleanupFixtures(dir) }

    let stats = TidbytManager.readTodayUsage(from: dir)
    // Sonnet input is $3.00/1M.
    XCTAssertEqual(stats.cost, 3.00, accuracy: 0.001)
  }

  /// Model matching should be case-insensitive.
  func testModelMatchingIsCaseInsensitive() throws {
    let now = Date()
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let ts = iso.string(from: now.addingTimeInterval(-60))

    let dir = try createFixtures([
      "project/session.jsonl": [
        makeEntry(sessionId: "s1", timestamp: ts, model: "CLAUDE-3-OPUS",
                  inputTokens: 1_000_000, outputTokens: 0)
      ]
    ])
    defer { cleanupFixtures(dir) }

    let stats = TidbytManager.readTodayUsage(from: dir)
    // Opus input is $15.00/1M.
    XCTAssertEqual(stats.cost, 15.00, accuracy: 0.001)
  }
}

final class RobustDateParsingTests: XCTestCase {

  /// TidbytManager uses a specific DateFormatter for milliseconds and fallback for standard ISO8601.
  func testHandlesVariousDateFormats() throws {
    let now = Date()
    
    // Use UTC for consistent formatting in tests
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX"
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    let tsRecent1 = formatter.string(from: now.addingTimeInterval(-600))
    
    let iso = ISO8601DateFormatter()
    iso.timeZone = TimeZone(secondsFromGMT: 0)
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let tsRecent2 = iso.string(from: now.addingTimeInterval(-300))

    let dirRecent = try createFixtures([
      "project/session.jsonl": [
        makeEntry(sessionId: "s1", timestamp: tsRecent1, inputTokens: 10, outputTokens: 10),
        makeEntry(sessionId: "s1", timestamp: tsRecent2, inputTokens: 20, outputTokens: 20),
      ]
    ])
    defer { cleanupFixtures(dirRecent) }

    let stats = TidbytManager.readTodayUsage(from: dirRecent)
    XCTAssertEqual(stats.tokens, 60) // (10+10) + (20+20)
  }
}

final class TimeSeriesBoundaryTests: XCTestCase {

  func testTimeSeriesBoundaryBuckets() throws {
    let now = Date()
    
    // Match TidbytManager's UTC rounding logic
    var utcCal = Calendar(identifier: .gregorian)
    utcCal.timeZone = TimeZone(secondsFromGMT: 0)!
    
    let roundedNow = utcCal.dateInterval(of: .hour, for: now.addingTimeInterval(-4 * 3600))?.start ?? now
    let blockStart = roundedNow
    
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX"
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    
    let tsStart = formatter.string(from: blockStart)
    let tsMiddle = formatter.string(from: blockStart.addingTimeInterval(150 * 60)) // 2.5 hours in (index 15)
    let tsEnd = formatter.string(from: blockStart.addingTimeInterval(299 * 60)) // Just before 5h (index 29)
    let tsOver = formatter.string(from: blockStart.addingTimeInterval(301 * 60)) // Just after 5h

    let dir = try createFixtures([
      "project/session.jsonl": [
        makeEntry(sessionId: "s1", timestamp: tsStart, inputTokens: 1, outputTokens: 0),
        makeEntry(sessionId: "s1", timestamp: tsMiddle, inputTokens: 2, outputTokens: 0),
        makeEntry(sessionId: "s1", timestamp: tsEnd, inputTokens: 4, outputTokens: 0),
        makeEntry(sessionId: "s1", timestamp: tsOver, inputTokens: 8, outputTokens: 0),
      ]
    ])
    defer { cleanupFixtures(dir) }

    let stats = TidbytManager.readTodayUsage(from: dir)
    
    // If the active block is the first one, we expect 1, 2, 4.
    // If the active block is the one starting at tsOver, we expect only 8.
    // Since tsOver is 301 mins (5h 1m) after blockStart, it starts a new block.
    // That new block's end will be 5h after roundToHour(tsOver).
    // The previous block's end was blockStart + 5h.
    // Since tsOver > previous block's end, it's definitely a new block.
    // TidbytManager picks the *most recent* active block.
    
    XCTAssertEqual(stats.tokens, 8, "Should only count the active (most recent) block")
    XCTAssertEqual(stats.tokenTimeSeries[0], 8, "Index 0 of the NEW block should be the 8 tokens")
  }
}
