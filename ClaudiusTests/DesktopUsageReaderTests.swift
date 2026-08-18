import XCTest
@testable import Claudius

/// The desktop app's usage cache is an undocumented internal file, so these
/// tests pin the behavior that matters: never present stale numbers as
/// current, and never crash on a shape we didn't expect.
final class DesktopUsageReaderTests: XCTestCase {

  private var dir: URL!

  override func setUpWithError() throws {
    dir = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("desktop-usage-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: dir)
  }

  @discardableResult
  private func write(_ json: String, name: String = "plan-usage-history.json") -> String {
    let url = dir.appendingPathComponent(name)
    try? json.write(to: url, atomically: true, encoding: .utf8)
    return url.path
  }

  private func millis(_ date: Date) -> String {
    String(format: "%.0f", date.timeIntervalSince1970 * 1000)
  }

  // MARK: Happy path

  func testReadsNewestSample() throws {
    let now = Date()
    let path = write("""
    { "version": 2, "samples": [
      { "t": \(millis(now.addingTimeInterval(-3600))), "org": "o", "u": { "fh": 10, "sd": 20 } },
      { "t": \(millis(now.addingTimeInterval(-300))),  "org": "o", "u": { "fh": 44, "sd": 76 } }
    ] }
    """)

    let stats = try XCTUnwrap(DesktopUsageReader.readUsage(path: path, now: now))
    XCTAssertEqual(stats.dataSource, .desktop)
    XCTAssertEqual(stats.buckets.count, 2)
    XCTAssertEqual(stats.fiveHourUtilization, 44)
    XCTAssertEqual(stats.sevenDayUtilization, 76)
    XCTAssertEqual(stats.buckets[0].role, .session)
    XCTAssertEqual(stats.buckets[1].role, .weeklyAll)
  }

  /// Ordering is an assumption about someone else's file — don't rely on it.
  func testPicksNewestEvenWhenOutOfOrder() throws {
    let now = Date()
    let path = write("""
    { "samples": [
      { "t": \(millis(now.addingTimeInterval(-120))), "u": { "fh": 99, "sd": 99 } },
      { "t": \(millis(now.addingTimeInterval(-9000))), "u": { "fh": 1, "sd": 2 } }
    ] }
    """)

    let stats = try XCTUnwrap(DesktopUsageReader.readUsage(path: path, now: now))
    XCTAssertEqual(stats.fiveHourUtilization, 99)
  }

  /// No reset timestamps exist in this file, so countdowns must be absent
  /// rather than fabricated.
  func testNoResetTimesAreInvented() throws {
    let now = Date()
    let path = write("""
    { "samples": [ { "t": \(millis(now)), "u": { "fh": 44, "sd": 76 } } ] }
    """)

    let stats = try XCTUnwrap(DesktopUsageReader.readUsage(path: path, now: now))
    XCTAssertTrue(stats.buckets.allSatisfy { $0.resetsAt == nil })
    XCTAssertNil(stats.fiveHourResetsAt)
  }

  // MARK: Staleness

  func testStaleSampleIsRejected() {
    let now = Date()
    let path = write("""
    { "samples": [ { "t": \(millis(now.addingTimeInterval(-60 * 60))), "u": { "fh": 44, "sd": 76 } } ] }
    """)

    XCTAssertNil(DesktopUsageReader.readUsage(path: path, now: now),
                 "a 60m-old sample is past the 45m limit and must not be shown as current")
  }

  func testFreshSampleJustInsideTheLimitIsAccepted() throws {
    let now = Date()
    let path = write("""
    { "samples": [ { "t": \(millis(now.addingTimeInterval(-44 * 60))), "u": { "fh": 44, "sd": 76 } } ] }
    """)

    XCTAssertNotNil(DesktopUsageReader.readUsage(path: path, now: now))
  }

  // MARK: Degradation

  func testMissingFileReturnsNil() {
    XCTAssertNil(DesktopUsageReader.readUsage(
      path: dir.appendingPathComponent("nope.json").path, now: Date()))
  }

  func testMalformedJSONReturnsNil() {
    let path = write("{ not json at all ")
    XCTAssertNil(DesktopUsageReader.readUsage(path: path, now: Date()))
  }

  func testEmptySamplesReturnsNil() {
    let path = write(#"{ "version": 2, "samples": [] }"#)
    XCTAssertNil(DesktopUsageReader.readUsage(path: path, now: Date()))
  }

  func testSampleWithNoUsageObjectReturnsNil() {
    let path = write("""
    { "samples": [ { "t": \(millis(Date())), "org": "o" } ] }
    """)
    XCTAssertNil(DesktopUsageReader.readUsage(path: path, now: Date()))
  }

  /// A future schema that adds keys must not break decoding.
  func testUnknownFieldsAreIgnored() throws {
    let now = Date()
    let path = write("""
    { "version": 3, "extra": {"a": 1}, "samples": [
      { "t": \(millis(now)), "org": "o", "u": { "fh": 44, "sd": 76, "op": 12 }, "future": true }
    ] }
    """)

    let stats = try XCTUnwrap(DesktopUsageReader.readUsage(path: path, now: now))
    XCTAssertEqual(stats.buckets.count, 2)
  }

  /// Partial data is still useful.
  func testSessionOnlySampleYieldsOneBucket() throws {
    let now = Date()
    let path = write("""
    { "samples": [ { "t": \(millis(now)), "u": { "fh": 44 } } ] }
    """)

    let stats = try XCTUnwrap(DesktopUsageReader.readUsage(path: path, now: now))
    XCTAssertEqual(stats.buckets.count, 1)
    XCTAssertEqual(stats.buckets[0].role, .session)
    XCTAssertNil(stats.sevenDayUtilization)
  }
}
