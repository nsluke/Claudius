import XCTest
@testable import Claudius

// MARK: - Test Helpers

/// Generates a JSONL line for an assistant message with the given parameters.
/// `messageId` and `requestId` control streaming dedup — entries sharing
/// the same pair are considered duplicates (only the first is counted).
private func makeEntry(
  sessionId: String,
  uuid: String = UUID().uuidString,
  timestamp: Date,
  model: String = "claude-sonnet-4-20250514",
  inputTokens: Int = 1,
  outputTokens: Int = 100,
  cacheCreation: Int = 0,
  cacheRead: Int = 0,
  messageId: String? = nil,
  requestId: String? = nil
) -> String {
  let iso = ISO8601DateFormatter()
  iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  let ts = iso.string(from: timestamp)

  // Build optional fields
  let reqField = requestId.map { ",\"requestId\":\"\($0)\"" } ?? ""
  let msgIdField = messageId.map { "\"id\":\"\($0)\"," } ?? ""

  return """
  {"type":"assistant","timestamp":"\(ts)","uuid":"\(uuid)","sessionId":"\(sessionId)"\(reqField),"message":{\(msgIdField)"model":"\(model)","usage":{"input_tokens":\(inputTokens),"output_tokens":\(outputTokens),"cache_creation_input_tokens":\(cacheCreation),"cache_read_input_tokens":\(cacheRead)}}}
  """
}

/// Creates a temp directory with JSONL fixture files. Returns the directory URL.
/// `files` maps relative file paths to arrays of JSONL lines.
@discardableResult
private func createFixtures(_ files: [String: [String]], in baseDir: URL? = nil) throws -> URL {
  let dir = baseDir ?? FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  let fm = FileManager.default

  for (relativePath, lines) in files {
    let fileURL = dir.appendingPathComponent(relativePath)
    try fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let content = lines.joined(separator: "\n") + "\n"
    try content.write(to: fileURL, atomically: true, encoding: .utf8)
  }

  return dir
}

/// Removes a temp fixture directory.
private func cleanupFixtures(_ dir: URL) {
  try? FileManager.default.removeItem(at: dir)
}

// MARK: - Streaming Dedup Tests

final class StreamingDedupTests: XCTestCase {

  /// Claude Code logs multiple JSONL entries per API call (streaming snapshots).
  /// Entries sharing the same message.id + requestId should only be counted once.
  func testDuplicateStreamingEntriesDeduped() throws {
    let now = Date()
    let dir = try createFixtures([
      "project/session.jsonl": [
        // Same message.id + requestId = streaming snapshots of one API call.
        // First: partial output (10 tokens)
        makeEntry(sessionId: "sess-1", timestamp: now.addingTimeInterval(-60),
                  inputTokens: 3, outputTokens: 10, cacheCreation: 0, cacheRead: 5_000,
                  messageId: "msg_abc123", requestId: "req_xyz789"),
        // Second: still partial (10 tokens)
        makeEntry(sessionId: "sess-1", timestamp: now.addingTimeInterval(-60),
                  inputTokens: 3, outputTokens: 10, cacheCreation: 0, cacheRead: 5_000,
                  messageId: "msg_abc123", requestId: "req_xyz789"),
        // Third: final with full output (332 tokens)
        makeEntry(sessionId: "sess-1", timestamp: now.addingTimeInterval(-60),
                  inputTokens: 3, outputTokens: 332, cacheCreation: 0, cacheRead: 5_000,
                  messageId: "msg_abc123", requestId: "req_xyz789"),
      ]
    ])
    defer { cleanupFixtures(dir) }

    let stats = TidbytManager.readTodayUsage(from: dir)
    // Only first entry counted: input(3) + output(10) = 13
    XCTAssertEqual(stats.tokens, 13,
      "Duplicate streaming entries should be deduped by message.id:requestId")
  }

  /// Entries with DIFFERENT message.id:requestId should all be counted.
  func testDistinctMessagesAllCounted() throws {
    let now = Date()
    let dir = try createFixtures([
      "project/session.jsonl": [
        makeEntry(sessionId: "sess-1", timestamp: now.addingTimeInterval(-120),
                  inputTokens: 5, outputTokens: 100,
                  messageId: "msg_001", requestId: "req_001"),
        makeEntry(sessionId: "sess-1", timestamp: now.addingTimeInterval(-60),
                  inputTokens: 3, outputTokens: 200,
                  messageId: "msg_002", requestId: "req_002"),
      ]
    ])
    defer { cleanupFixtures(dir) }

    let stats = TidbytManager.readTodayUsage(from: dir)
    // Two distinct messages: (5+100) + (3+200) = 308
    XCTAssertEqual(stats.tokens, 308)
  }

  /// Entries WITHOUT message.id or requestId should still be counted
  /// (no dedup possible — legacy entries may lack these fields).
  func testEntriesWithoutHashFieldsStillCounted() throws {
    let now = Date()
    let dir = try createFixtures([
      "project/session.jsonl": [
        // No messageId or requestId (legacy format)
        makeEntry(sessionId: "sess-1", timestamp: now.addingTimeInterval(-120),
                  inputTokens: 5, outputTokens: 100),
        makeEntry(sessionId: "sess-1", timestamp: now.addingTimeInterval(-60),
                  inputTokens: 3, outputTokens: 200),
      ]
    ])
    defer { cleanupFixtures(dir) }

    let stats = TidbytManager.readTodayUsage(from: dir)
    // Both counted: (5+100) + (3+200) = 308
    XCTAssertEqual(stats.tokens, 308)
  }

  /// Mixed: some entries with dedup hashes, some without.
  func testMixedDedupAndNonDedup() throws {
    let now = Date()
    let dir = try createFixtures([
      "project/session.jsonl": [
        // Streaming duplicate pair (same hash)
        makeEntry(sessionId: "sess-1", timestamp: now.addingTimeInterval(-180),
                  inputTokens: 1, outputTokens: 5,
                  messageId: "msg_A", requestId: "req_A"),
        makeEntry(sessionId: "sess-1", timestamp: now.addingTimeInterval(-180),
                  inputTokens: 1, outputTokens: 500,
                  messageId: "msg_A", requestId: "req_A"),
        // No hash (legacy entry)
        makeEntry(sessionId: "sess-1", timestamp: now.addingTimeInterval(-60),
                  inputTokens: 10, outputTokens: 100),
      ]
    ])
    defer { cleanupFixtures(dir) }

    let stats = TidbytManager.readTodayUsage(from: dir)
    // First of dedup pair: (1+5) = 6. Legacy entry: (10+100) = 110. Total = 116
    XCTAssertEqual(stats.tokens, 116)
  }
}

// MARK: - Token Counting Tests

final class TokenCountingTests: XCTestCase {

  /// Token count should be input_tokens + output_tokens only.
  /// Cache tokens (cache_creation, cache_read) are excluded from the token
  /// metric but still contribute to cost.
  /// Matches claude-code-usage-monitor's _create_base_block_dict "totalTokens".
  func testTokensAreInputPlusOutput() throws {
    let now = Date()
    let dir = try createFixtures([
      "project/session.jsonl": [
        makeEntry(
          sessionId: "sess-1",
          timestamp: now.addingTimeInterval(-60),
          inputTokens: 50,
          outputTokens: 200,
          cacheCreation: 500,
          cacheRead: 50_000
        )
      ]
    ])
    defer { cleanupFixtures(dir) }

    let stats = TidbytManager.readTodayUsage(from: dir)
    // Tokens = input + output = 50 + 200 = 250 (cache excluded)
    XCTAssertEqual(stats.tokens, 250, "Token count should be input + output only")
    // Cost should still include all 4 token types
    XCTAssertGreaterThan(stats.cost, 0, "Cost should include all token types")
  }

  /// cache_read_input_tokens must NOT inflate the token count,
  /// but MUST contribute to cost calculation.
  func testCacheReadAffectsCostNotTokens() throws {
    let now = Date()

    // Two identical entries except one has 100k cache_read
    let dirNoCR = try createFixtures([
      "project/session.jsonl": [
        makeEntry(sessionId: "s1", timestamp: now.addingTimeInterval(-60),
                  inputTokens: 100, outputTokens: 500, cacheCreation: 0, cacheRead: 0),
      ]
    ])
    defer { cleanupFixtures(dirNoCR) }

    let dirWithCR = try createFixtures([
      "project/session.jsonl": [
        makeEntry(sessionId: "s1", timestamp: now.addingTimeInterval(-60),
                  inputTokens: 100, outputTokens: 500, cacheCreation: 0, cacheRead: 100_000),
      ]
    ])
    defer { cleanupFixtures(dirWithCR) }

    let statsNoCR = TidbytManager.readTodayUsage(from: dirNoCR)
    let statsWithCR = TidbytManager.readTodayUsage(from: dirWithCR)

    // Tokens should be the same (input + output only)
    XCTAssertEqual(statsNoCR.tokens, statsWithCR.tokens,
      "cache_read should not affect token count")
    XCTAssertEqual(statsNoCR.tokens, 600) // 100 + 500

    // Cost should be higher with cache_read
    XCTAssertGreaterThan(statsWithCR.cost, statsNoCR.cost,
      "cache_read should increase cost")
  }

  /// cache_creation_input_tokens must NOT inflate the token count,
  /// but MUST contribute to cost calculation.
  func testCacheCreationAffectsCostNotTokens() throws {
    let now = Date()

    let dirNoCC = try createFixtures([
      "project/session.jsonl": [
        makeEntry(sessionId: "s1", timestamp: now.addingTimeInterval(-60),
                  inputTokens: 100, outputTokens: 500, cacheCreation: 0, cacheRead: 0),
      ]
    ])
    defer { cleanupFixtures(dirNoCC) }

    let dirWithCC = try createFixtures([
      "project/session.jsonl": [
        makeEntry(sessionId: "s1", timestamp: now.addingTimeInterval(-60),
                  inputTokens: 100, outputTokens: 500, cacheCreation: 50_000, cacheRead: 0),
      ]
    ])
    defer { cleanupFixtures(dirWithCC) }

    let statsNoCC = TidbytManager.readTodayUsage(from: dirNoCC)
    let statsWithCC = TidbytManager.readTodayUsage(from: dirWithCC)

    // Tokens should be the same (input + output only)
    XCTAssertEqual(statsNoCC.tokens, statsWithCC.tokens,
      "cache_creation should not affect token count")
    XCTAssertEqual(statsNoCC.tokens, 600) // 100 + 500

    // Cost should be higher with cache_creation
    XCTAssertGreaterThan(statsWithCC.cost, statsNoCC.cost,
      "cache_creation should increase cost")
  }
}

// MARK: - Token Summation Tests

final class TokenSummationTests: XCTestCase {

  /// All turns in a conversation should have their input+output tokens summed.
  func testAllTurnsTokensSummed() throws {
    let now = Date()
    let dir = try createFixtures([
      "project/session.jsonl": [
        makeEntry(sessionId: "sess-1", timestamp: now.addingTimeInterval(-300),
                  inputTokens: 10, outputTokens: 100, cacheCreation: 500, cacheRead: 10_000),
        makeEntry(sessionId: "sess-1", timestamp: now.addingTimeInterval(-200),
                  inputTokens: 5, outputTokens: 200, cacheCreation: 300, cacheRead: 11_000),
        makeEntry(sessionId: "sess-1", timestamp: now.addingTimeInterval(-100),
                  inputTokens: 1, outputTokens: 150, cacheCreation: 200, cacheRead: 12_000),
      ]
    ])
    defer { cleanupFixtures(dir) }

    let stats = TidbytManager.readTodayUsage(from: dir)
    // Sum of input+output: (10+100) + (5+200) + (1+150) = 466
    XCTAssertEqual(stats.tokens, 466, "All turns' input+output tokens should be summed")
    XCTAssertEqual(stats.messages, 1, "Three turns in one file = 1 conversation")
  }

  /// Multiple conversations should sum all their input+output tokens.
  func testMultipleConversationsSumTokens() throws {
    let now = Date()
    let dir = try createFixtures([
      "project-a/sess-1.jsonl": [
        makeEntry(sessionId: "sess-1", timestamp: now.addingTimeInterval(-120),
                  inputTokens: 10, outputTokens: 100, cacheCreation: 0, cacheRead: 10_000),
      ],
      "project-b/sess-2.jsonl": [
        makeEntry(sessionId: "sess-2", timestamp: now.addingTimeInterval(-60),
                  inputTokens: 20, outputTokens: 200, cacheCreation: 0, cacheRead: 20_000),
      ],
    ])
    defer { cleanupFixtures(dir) }

    let stats = TidbytManager.readTodayUsage(from: dir)
    // (10+100) + (20+200) = 330
    XCTAssertEqual(stats.tokens, 330)
    XCTAssertEqual(stats.messages, 2)
  }
}

// MARK: - Subagent Tests

final class SubagentTests: XCTestCase {

  /// Subagent tokens should be counted alongside parent tokens.
  func testSubagentTokensSummedWithParent() throws {
    let now = Date()
    let dir = try createFixtures([
      "project/sess-1.jsonl": [
        makeEntry(sessionId: "sess-1", timestamp: now.addingTimeInterval(-120),
                  inputTokens: 10, outputTokens: 500, cacheCreation: 1000, cacheRead: 100_000),
      ],
      "project/sess-1/subagents/agent-abc.jsonl": [
        makeEntry(sessionId: "sess-1", timestamp: now.addingTimeInterval(-60),
                  inputTokens: 5, outputTokens: 200, cacheCreation: 500, cacheRead: 5_000),
      ],
    ])
    defer { cleanupFixtures(dir) }

    let stats = TidbytManager.readTodayUsage(from: dir)
    // (10+500) + (5+200) = 715
    XCTAssertEqual(stats.tokens, 715,
      "Parent and subagent input+output tokens should be summed")
    XCTAssertEqual(stats.messages, 2, "Parent and subagent are separate conversations")
  }

  /// Multiple subagents should each contribute their tokens.
  func testMultipleSubagentsAllCounted() throws {
    let now = Date()
    let dir = try createFixtures([
      "project/sess-1.jsonl": [
        makeEntry(sessionId: "sess-1", timestamp: now.addingTimeInterval(-300),
                  inputTokens: 10, outputTokens: 300, cacheCreation: 0, cacheRead: 80_000),
      ],
      "project/sess-1/subagents/agent-a.jsonl": [
        makeEntry(sessionId: "sess-1", timestamp: now.addingTimeInterval(-200),
                  inputTokens: 5, outputTokens: 100, cacheCreation: 0, cacheRead: 3_000),
      ],
      "project/sess-1/subagents/agent-b.jsonl": [
        makeEntry(sessionId: "sess-1", timestamp: now.addingTimeInterval(-100),
                  inputTokens: 3, outputTokens: 150, cacheCreation: 0, cacheRead: 4_000),
      ],
    ])
    defer { cleanupFixtures(dir) }

    let stats = TidbytManager.readTodayUsage(from: dir)
    // (10+300) + (5+100) + (3+150) = 568
    XCTAssertEqual(stats.tokens, 568)
    XCTAssertEqual(stats.messages, 3)
  }
}

// MARK: - Window Filtering Tests

final class WindowFilteringTests: XCTestCase {

  /// Entries older than 5 hours should be excluded entirely.
  func testOldEntriesExcluded() throws {
    let now = Date()
    let dir = try createFixtures([
      "project/session.jsonl": [
        // 6 hours ago — outside window
        makeEntry(sessionId: "sess-old", timestamp: now.addingTimeInterval(-6 * 3600),
                  inputTokens: 50, outputTokens: 100, cacheCreation: 0, cacheRead: 50_000),
        // 1 hour ago — inside window
        makeEntry(sessionId: "sess-new", timestamp: now.addingTimeInterval(-3600),
                  inputTokens: 10, outputTokens: 100, cacheCreation: 0, cacheRead: 10_000),
      ]
    ])
    defer { cleanupFixtures(dir) }

    let stats = TidbytManager.readTodayUsage(from: dir)
    // Only in-window message: input+output = 10+100 = 110
    XCTAssertEqual(stats.tokens, 110)
    XCTAssertEqual(stats.messages, 1)
  }

  /// An empty directory should return zero stats without crashing.
  func testEmptyDirectory() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { cleanupFixtures(dir) }

    let stats = TidbytManager.readTodayUsage(from: dir)
    XCTAssertEqual(stats.tokens, 0)
    XCTAssertEqual(stats.cost, 0)
    XCTAssertEqual(stats.messages, 0)
  }
}

// MARK: - Date Tracking Tests

final class DateTrackingTests: XCTestCase {

  func testOldestAndNewestDatesTracked() throws {
    let now = Date()
    let oldest = now.addingTimeInterval(-3600) // 1h ago
    let newest = now.addingTimeInterval(-60)   // 1m ago

    let dir = try createFixtures([
      "project/session.jsonl": [
        makeEntry(sessionId: "sess-1", timestamp: oldest,
                  inputTokens: 1, outputTokens: 100, cacheCreation: 0, cacheRead: 5_000),
        makeEntry(sessionId: "sess-1", timestamp: now.addingTimeInterval(-1800),
                  inputTokens: 1, outputTokens: 100, cacheCreation: 0, cacheRead: 6_000),
        makeEntry(sessionId: "sess-1", timestamp: newest,
                  inputTokens: 1, outputTokens: 100, cacheCreation: 0, cacheRead: 7_000),
      ]
    ])
    defer { cleanupFixtures(dir) }

    let stats = TidbytManager.readTodayUsage(from: dir)

    // Dates should be within 1 second tolerance (formatting round-trip)
    XCTAssertNotNil(stats.oldestMessageDate)
    XCTAssertNotNil(stats.newestMessageDate)
    XCTAssertEqual(stats.oldestMessageDate!.timeIntervalSince1970, oldest.timeIntervalSince1970, accuracy: 1.0)
    XCTAssertEqual(stats.newestMessageDate!.timeIntervalSince1970, newest.timeIntervalSince1970, accuracy: 1.0)
  }
}

// MARK: - Time Series Tests

final class TimeSeriesTests: XCTestCase {

  /// Tokens should be bucketed into 10-minute slots relative to the
  /// session block start. Entries far apart should land in different buckets.
  func testTokensBucketedCorrectly() throws {
    let now = Date()

    // Place entries 3h apart — both within the same 5h block.
    let dir = try createFixtures([
      "project/session.jsonl": [
        makeEntry(sessionId: "sess-1", timestamp: now.addingTimeInterval(-3 * 3600),
                  inputTokens: 10, outputTokens: 100, cacheCreation: 0, cacheRead: 5_000),
        makeEntry(sessionId: "sess-1", timestamp: now.addingTimeInterval(-60),
                  inputTokens: 20, outputTokens: 200, cacheCreation: 0, cacheRead: 10_000),
      ]
    ])
    defer { cleanupFixtures(dir) }

    let stats = TidbytManager.readTodayUsage(from: dir)

    XCTAssertEqual(stats.tokenTimeSeries.count, 30)

    // Sum of all buckets should equal total tokens
    let bucketSum = stats.tokenTimeSeries.reduce(0, +)
    XCTAssertEqual(bucketSum, stats.tokens, "Sum of all buckets should equal total tokens")
    XCTAssertEqual(bucketSum, 330, "Total: (10+100)+(20+200)=330")

    // Entries 3h apart should land in different 10-minute buckets
    let nonZeroBuckets = stats.tokenTimeSeries.filter { $0 > 0 }
    XCTAssertEqual(nonZeroBuckets.count, 2, "Two entries 3h apart should be in different buckets")
  }

  /// Multiple entries close together should be bucketed and their tokens summed.
  func testMultipleEntriesInSameBucket() throws {
    let now = Date()
    let dir = try createFixtures([
      "project/session.jsonl": [
        makeEntry(sessionId: "sess-1", timestamp: now.addingTimeInterval(-120),
                  inputTokens: 10, outputTokens: 150, cacheCreation: 0, cacheRead: 5_000),
        makeEntry(sessionId: "sess-1", timestamp: now.addingTimeInterval(-60),
                  inputTokens: 5, outputTokens: 250, cacheCreation: 0, cacheRead: 6_000),
      ]
    ])
    defer { cleanupFixtures(dir) }

    let stats = TidbytManager.readTodayUsage(from: dir)

    // All tokens should appear in the time series
    let bucketSum = stats.tokenTimeSeries.reduce(0, +)
    XCTAssertEqual(bucketSum, 415, "Total: (10+150)+(5+250)=415")
    XCTAssertEqual(bucketSum, stats.tokens, "Sum of all buckets should equal total tokens")
  }
}

// MARK: - Session Block Tests

final class SessionBlockTests: XCTestCase {

  /// Entries separated by a gap >= 5h should be in different blocks.
  /// Only the active block (containing the most recent entries) is counted.
  func testLargeGapCreatesNewBlock() throws {
    let now = Date()
    let dir = try createFixtures([
      "project/session.jsonl": [
        // Old block: 7h ago (gap to next entry > 5h → separate block)
        makeEntry(sessionId: "sess-old", timestamp: now.addingTimeInterval(-7 * 3600),
                  inputTokens: 500, outputTokens: 5000, cacheCreation: 0, cacheRead: 0),
        // Active block: 30min ago
        makeEntry(sessionId: "sess-new", timestamp: now.addingTimeInterval(-1800),
                  inputTokens: 10, outputTokens: 100, cacheCreation: 0, cacheRead: 0),
      ]
    ])
    defer { cleanupFixtures(dir) }

    let stats = TidbytManager.readTodayUsage(from: dir)
    // Only the active block entry: 10 + 100 = 110
    XCTAssertEqual(stats.tokens, 110,
      "Only the active block's tokens should be counted")
    XCTAssertEqual(stats.messages, 1)
  }

  /// Entries past the block's 5h end boundary should start a new block.
  /// Block end = roundToHour(first_entry) + 5h.
  func testBlockEndBoundaryCreatesNewBlock() throws {
    let now = Date()
    // Create an entry ~4h55m ago. Its block starts at the rounded hour,
    // so block end is ~5h after the rounded hour. An entry just now should
    // be close to or past that boundary, creating a separate block —
    // OR they could be in the same block depending on timing.
    // Use a 6h gap to guarantee separate blocks.
    let dir = try createFixtures([
      "project/session.jsonl": [
        makeEntry(sessionId: "sess-1", timestamp: now.addingTimeInterval(-8 * 3600),
                  inputTokens: 999, outputTokens: 999, cacheCreation: 0, cacheRead: 0),
        makeEntry(sessionId: "sess-1", timestamp: now.addingTimeInterval(-2 * 3600),
                  inputTokens: 20, outputTokens: 200, cacheCreation: 0, cacheRead: 0),
        makeEntry(sessionId: "sess-1", timestamp: now.addingTimeInterval(-60),
                  inputTokens: 5, outputTokens: 50, cacheCreation: 0, cacheRead: 0),
      ]
    ])
    defer { cleanupFixtures(dir) }

    let stats = TidbytManager.readTodayUsage(from: dir)
    // 8h-ago entry is in a separate old block.
    // 2h-ago and 1min-ago are in the same active block: (20+200) + (5+50) = 275
    XCTAssertEqual(stats.tokens, 275,
      "Only entries in the active block should be counted")
  }

  /// All entries within a 5h block should be counted together.
  func testEntriesWithinSameBlockAllCounted() throws {
    let now = Date()
    let dir = try createFixtures([
      "project/session.jsonl": [
        makeEntry(sessionId: "sess-1", timestamp: now.addingTimeInterval(-4 * 3600),
                  inputTokens: 10, outputTokens: 100, cacheCreation: 0, cacheRead: 0),
        makeEntry(sessionId: "sess-1", timestamp: now.addingTimeInterval(-2 * 3600),
                  inputTokens: 20, outputTokens: 200, cacheCreation: 0, cacheRead: 0),
        makeEntry(sessionId: "sess-1", timestamp: now.addingTimeInterval(-60),
                  inputTokens: 5, outputTokens: 50, cacheCreation: 0, cacheRead: 0),
      ]
    ])
    defer { cleanupFixtures(dir) }

    let stats = TidbytManager.readTodayUsage(from: dir)
    // All three entries are within the same block: (10+100)+(20+200)+(5+50) = 385
    XCTAssertEqual(stats.tokens, 385,
      "All entries within the same 5h block should be summed")
  }

  /// Dedup should work correctly within the active block.
  func testDedupWithinActiveBlock() throws {
    let now = Date()
    let dir = try createFixtures([
      "project/session.jsonl": [
        // Old block (7h ago) — should be excluded
        makeEntry(sessionId: "sess-old", timestamp: now.addingTimeInterval(-7 * 3600),
                  inputTokens: 999, outputTokens: 999,
                  messageId: "msg_old", requestId: "req_old"),
        // Active block with streaming duplicates
        makeEntry(sessionId: "sess-new", timestamp: now.addingTimeInterval(-120),
                  inputTokens: 10, outputTokens: 50,
                  messageId: "msg_A", requestId: "req_A"),
        makeEntry(sessionId: "sess-new", timestamp: now.addingTimeInterval(-120),
                  inputTokens: 10, outputTokens: 500,
                  messageId: "msg_A", requestId: "req_A"),
        // Different message in active block
        makeEntry(sessionId: "sess-new", timestamp: now.addingTimeInterval(-60),
                  inputTokens: 5, outputTokens: 100,
                  messageId: "msg_B", requestId: "req_B"),
      ]
    ])
    defer { cleanupFixtures(dir) }

    let stats = TidbytManager.readTodayUsage(from: dir)
    // Active block: first of dedup pair (10+50) + msg_B (5+100) = 165
    XCTAssertEqual(stats.tokens, 165,
      "Dedup and block filtering should work together")
    XCTAssertEqual(stats.messages, 1, "One file in active block")
  }
}

// MARK: - Cost Calculation Tests

final class CostCalculationTests: XCTestCase {

  /// Cost should sum ALL messages and use all 4 token types for pricing.
  func testCostSumsAllMessages() throws {
    let now = Date()
    let dir = try createFixtures([
      "project/session.jsonl": [
        makeEntry(sessionId: "sess-1", timestamp: now.addingTimeInterval(-120),
                  model: "claude-sonnet-4-20250514",
                  inputTokens: 100, outputTokens: 50, cacheCreation: 0, cacheRead: 10_000),
        makeEntry(sessionId: "sess-1", timestamp: now.addingTimeInterval(-60),
                  model: "claude-sonnet-4-20250514",
                  inputTokens: 100, outputTokens: 50, cacheCreation: 0, cacheRead: 12_000),
      ]
    ])
    defer { cleanupFixtures(dir) }

    let stats = TidbytManager.readTodayUsage(from: dir)

    // Turn 1: (100 * 3.00 + 50 * 15.00 + 0 + 10000 * 0.30) / 1M = (300 + 750 + 3000) / 1M = 0.00405
    // Turn 2: (100 * 3.00 + 50 * 15.00 + 0 + 12000 * 0.30) / 1M = (300 + 750 + 3600) / 1M = 0.00465
    // Total: 0.0087
    XCTAssertEqual(stats.cost, 0.0087, accuracy: 0.0001,
      "Cost should sum all messages")

    // Token count = input+output only: (100+50) + (100+50) = 300
    XCTAssertEqual(stats.tokens, 300)
  }

  /// Sonnet pricing should use the standard rates.
  func testSonnetPricing() throws {
    let now = Date()
    let dir = try createFixtures([
      "project/session.jsonl": [
        makeEntry(sessionId: "sess-1", timestamp: now.addingTimeInterval(-60),
                  model: "claude-sonnet-4-20250514",
                  inputTokens: 1_000_000, outputTokens: 0, cacheCreation: 0, cacheRead: 0),
      ]
    ])
    defer { cleanupFixtures(dir) }

    let stats = TidbytManager.readTodayUsage(from: dir)
    // Sonnet input: $3.00 per 1M tokens. 1M tokens = $3.00
    XCTAssertEqual(stats.cost, 3.00, accuracy: 0.001)
  }

  /// Opus pricing should use the higher rates.
  func testOpusPricing() throws {
    let now = Date()
    let dir = try createFixtures([
      "project/session.jsonl": [
        makeEntry(sessionId: "sess-1", timestamp: now.addingTimeInterval(-60),
                  model: "claude-opus-4-20250514",
                  inputTokens: 1_000_000, outputTokens: 0, cacheCreation: 0, cacheRead: 0),
      ]
    ])
    defer { cleanupFixtures(dir) }

    let stats = TidbytManager.readTodayUsage(from: dir)
    // Opus input: $15.00 per 1M tokens. 1M tokens = $15.00
    XCTAssertEqual(stats.cost, 15.00, accuracy: 0.001)
  }

  /// Haiku pricing should use the lower rates.
  func testHaikuPricing() throws {
    let now = Date()
    let dir = try createFixtures([
      "project/session.jsonl": [
        makeEntry(sessionId: "sess-1", timestamp: now.addingTimeInterval(-60),
                  model: "claude-3-5-haiku-20241022",
                  inputTokens: 1_000_000, outputTokens: 0, cacheCreation: 0, cacheRead: 0),
      ]
    ])
    defer { cleanupFixtures(dir) }

    let stats = TidbytManager.readTodayUsage(from: dir)
    // Haiku input: $0.25 per 1M tokens. 1M tokens = $0.25
    XCTAssertEqual(stats.cost, 0.25, accuracy: 0.001)
  }
}

// MARK: - Edge Case Tests

final class EdgeCaseTests: XCTestCase {

  /// Non-assistant entries (type: "human", "system") should be ignored.
  func testNonAssistantEntriesIgnored() throws {
    let now = Date()
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let ts = iso.string(from: now.addingTimeInterval(-60))

    let humanLine = """
    {"type":"human","timestamp":"\(ts)","uuid":"uuid-h","sessionId":"sess-1","message":{"model":"claude-sonnet-4-20250514","usage":{"input_tokens":99999,"output_tokens":99999,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
    """

    let dir = try createFixtures([
      "project/session.jsonl": [
        humanLine,
        makeEntry(sessionId: "sess-1", timestamp: now.addingTimeInterval(-30),
                  inputTokens: 10, outputTokens: 100, cacheCreation: 0, cacheRead: 5_000),
      ]
    ])
    defer { cleanupFixtures(dir) }

    let stats = TidbytManager.readTodayUsage(from: dir)
    // Only the assistant entry's tokens: 10 + 100 = 110
    XCTAssertEqual(stats.tokens, 110)
  }

  /// Entries with missing usage fields should be skipped gracefully.
  func testMissingUsageSkipped() throws {
    let now = Date()
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let ts = iso.string(from: now.addingTimeInterval(-60))

    let noUsageLine = """
    {"type":"assistant","timestamp":"\(ts)","uuid":"uuid-x","sessionId":"sess-1","message":{"model":"claude-sonnet-4-20250514"}}
    """

    let dir = try createFixtures([
      "project/session.jsonl": [
        noUsageLine,
        makeEntry(sessionId: "sess-1", timestamp: now.addingTimeInterval(-30),
                  inputTokens: 10, outputTokens: 100, cacheCreation: 0, cacheRead: 5_000),
      ]
    ])
    defer { cleanupFixtures(dir) }

    let stats = TidbytManager.readTodayUsage(from: dir)
    // 10 + 100 = 110
    XCTAssertEqual(stats.tokens, 110)
  }

  /// Files that aren't .jsonl should be ignored.
  func testNonJsonlFilesIgnored() throws {
    let dir = try createFixtures([
      "project/notes.txt": ["this is not jsonl"],
      "project/session.jsonl": [
        makeEntry(sessionId: "sess-1", timestamp: Date().addingTimeInterval(-60),
                  inputTokens: 10, outputTokens: 100, cacheCreation: 0, cacheRead: 5_000),
      ]
    ])
    defer { cleanupFixtures(dir) }

    let stats = TidbytManager.readTodayUsage(from: dir)
    // 10 + 100 = 110
    XCTAssertEqual(stats.tokens, 110)
  }
}
