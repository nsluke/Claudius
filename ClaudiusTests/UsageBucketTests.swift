import XCTest
@testable import Claudius

/// Coverage for the usage-API decode path.
///
/// The endpoint's response shape is not stable — per-model caps have already
/// migrated from flat `seven_day_<model>` keys into a `limits[]` array, and the
/// top-level key set grows over time. These tests pin the behavior that matters:
/// unknown keys never break decoding, and a model-scoped cap is surfaced no
/// matter which of the two shapes it arrives in.
final class UsageBucketTests: XCTestCase {

  private func decode(_ json: String, file: StaticString = #filePath, line: UInt = #line) throws -> OAuthUsageResponse {
    let data = Data(json.utf8)
    return try JSONDecoder().decode(OAuthUsageResponse.self, from: data)
  }

  private func buckets(_ json: String, file: StaticString = #filePath, line: UInt = #line) throws -> [UsageBucket] {
    UsageBucket.merge(from: try decode(json, file: file, line: line))
  }

  override func setUp() {
    super.setUp()
    UserDefaults.standard.removeObject(forKey: "ScopedBucketPreference")
  }

  // MARK: - Today's shape

  func testFlatTwoBucketResponse() throws {
    let result = try buckets("""
    {
      "five_hour": { "utilization": 45.0, "resets_at": "2026-08-13T20:00:00Z" },
      "seven_day": { "utilization": 70.0, "resets_at": "2026-08-18T00:00:00Z" }
    }
    """)

    XCTAssertEqual(result.count, 2)
    XCTAssertEqual(result[0].role, .session)
    XCTAssertEqual(result[0].utilization, 45.0)
    XCTAssertNotNil(result[0].resetsAt)
    XCTAssertEqual(result[1].role, .weeklyAll)
    XCTAssertEqual(result[1].utilization, 70.0)
  }

  /// Regression test: a present window whose `resets_at` is null used to throw
  /// and take the whole response down, silently zeroing usage.
  func testNullResetsAtDoesNotThrow() throws {
    let result = try buckets("""
    {
      "five_hour": { "utilization": 12.0, "resets_at": null },
      "seven_day": { "utilization": 30.0, "resets_at": "2026-08-18T00:00:00Z" }
    }
    """)

    XCTAssertEqual(result.count, 2)
    XCTAssertEqual(result[0].utilization, 12.0)
    XCTAssertNil(result[0].resetsAt)
  }

  // MARK: - Model-scoped caps

  func testLimitsArrayYieldsScopedFableBucket() throws {
    let result = try buckets("""
    {
      "five_hour": { "utilization": 45.0, "resets_at": "2026-08-13T20:00:00Z" },
      "seven_day": { "utilization": 70.0, "resets_at": "2026-08-18T00:00:00Z" },
      "limits": [
        { "kind": "session", "group": "session", "percent": 45, "severity": "normal",
          "resets_at": "2026-08-13T20:00:00Z", "is_active": false },
        { "kind": "weekly_all", "group": "weekly", "percent": 70, "severity": "warning",
          "resets_at": "2026-08-18T00:00:00Z", "is_active": false },
        { "kind": "weekly_scoped", "group": "weekly", "percent": 71, "severity": "warning",
          "resets_at": "2026-08-18T00:00:00Z", "is_active": true,
          "scope": { "model": { "id": null, "display_name": "Fable" } } }
      ]
    }
    """)

    XCTAssertEqual(result.count, 3)
    let scoped = try XCTUnwrap(result.first { $0.role == .weeklyScoped })
    XCTAssertEqual(scoped.displayName, "Fable")
    XCTAssertEqual(scoped.utilization, 71)
    XCTAssertEqual(scoped.severity, "warning")
    XCTAssertEqual(scoped.id, "weekly:fable")
  }

  /// Accounts that can't use a model still get an entry for it, zeroed with no
  /// reset time. That must not become a permanent phantom 0% bar.
  func testPlaceholderScopedEntryIsDropped() throws {
    let result = try buckets("""
    {
      "five_hour": { "utilization": 45.0, "resets_at": "2026-08-13T20:00:00Z" },
      "seven_day": { "utilization": 70.0, "resets_at": "2026-08-18T00:00:00Z" },
      "limits": [
        { "kind": "weekly_scoped", "group": "weekly", "percent": 0,
          "resets_at": null, "is_active": false,
          "scope": { "model": { "id": null, "display_name": "Fable" } } }
      ]
    }
    """)

    XCTAssertEqual(result.count, 2)
    XCTAssertFalse(result.contains { $0.role == .weeklyScoped })
  }

  /// A model nobody has heard of must still render — the preference list is a
  /// sort hint, not an allow-list.
  func testUnknownScopedModelStillRenders() throws {
    let result = try buckets("""
    {
      "five_hour": { "utilization": 10.0, "resets_at": null },
      "limits": [
        { "kind": "weekly_scoped", "group": "weekly", "percent": 33,
          "resets_at": "2026-08-18T00:00:00Z",
          "scope": { "model": { "id": null, "display_name": "Zephyr" } } }
      ]
    }
    """)

    let scoped = try XCTUnwrap(result.first { $0.role == .weeklyScoped })
    XCTAssertEqual(scoped.displayName, "Zephyr")
    XCTAssertEqual(scoped.utilization, 33)
  }

  func testPreferredScopedModelSortsFirst() throws {
    let result = try buckets("""
    {
      "five_hour": { "utilization": 10.0, "resets_at": null },
      "limits": [
        { "kind": "weekly_scoped", "group": "weekly", "percent": 90,
          "resets_at": "2026-08-18T00:00:00Z",
          "scope": { "model": { "display_name": "Zephyr" } } },
        { "kind": "weekly_scoped", "group": "weekly", "percent": 20,
          "resets_at": "2026-08-18T00:00:00Z",
          "scope": { "model": { "display_name": "Fable" } } }
      ]
    }
    """)

    let scoped = result.filter { $0.role == .weeklyScoped }
    XCTAssertEqual(scoped.map(\.displayName), ["Fable", "Zephyr"],
                   "Fable is in the preference list so it sorts ahead of a higher-utilization unknown model")
  }

  /// Legacy shape, for accounts not yet migrated to `limits[]`.
  func testFlatPerModelKeyFallback() throws {
    let result = try buckets("""
    {
      "five_hour": { "utilization": 45.0, "resets_at": null },
      "seven_day": { "utilization": 70.0, "resets_at": null },
      "seven_day_opus": { "utilization": 22.0, "resets_at": "2026-08-18T00:00:00Z" }
    }
    """)

    XCTAssertEqual(result.count, 3)
    let scoped = try XCTUnwrap(result.first { $0.role == .weeklyScoped })
    XCTAssertEqual(scoped.displayName, "Opus")
    XCTAssertEqual(scoped.utilization, 22.0)
  }

  /// `limits[]` wins when both shapes describe the same model.
  func testLimitsWinsOverFlatKeyForSameModel() throws {
    let result = try buckets("""
    {
      "five_hour": { "utilization": 45.0, "resets_at": null },
      "seven_day_fable": { "utilization": 11.0, "resets_at": "2026-08-18T00:00:00Z" },
      "limits": [
        { "kind": "weekly_scoped", "group": "weekly", "percent": 71,
          "resets_at": "2026-08-18T00:00:00Z",
          "scope": { "model": { "display_name": "Fable" } } }
      ]
    }
    """)

    let scoped = result.filter { $0.role == .weeklyScoped }
    XCTAssertEqual(scoped.count, 1)
    XCTAssertEqual(scoped[0].utilization, 71)
  }

  // MARK: - Tolerance

  /// Opaque codename buckets, nulls, and non-object values come and go freely.
  /// None of them may break decoding or produce a visible bucket.
  func testUnknownKeysAndOddTypesAreIgnored() throws {
    let result = try buckets("""
    {
      "five_hour": { "utilization": 45.0, "resets_at": "2026-08-13T20:00:00Z" },
      "seven_day": { "utilization": 70.0, "resets_at": "2026-08-18T00:00:00Z" },
      "member_dashboard_available": true,
      "spend": { "limit_dollars": null, "used_dollars": null },
      "extra_usage": { "anything": 1 },
      "tangelo": null,
      "iguana_necktie": { "utilization": null, "resets_at": null },
      "nimbus_quill": "unexpected string",
      "cinder_cove": 42
    }
    """)

    XCTAssertEqual(result.count, 2, "only the two real windows should surface")
  }

  /// The CLI's control-protocol variant wraps the payload; decoding must be
  /// identical either way.
  func testRateLimitsEnvelopeIsUnwrapped() throws {
    let plain = try buckets("""
    { "five_hour": { "utilization": 45.0, "resets_at": null },
      "seven_day": { "utilization": 70.0, "resets_at": null } }
    """)

    let wrapped = try buckets("""
    { "rate_limits": {
        "five_hour": { "utilization": 45.0, "resets_at": null },
        "seven_day": { "utilization": 70.0, "resets_at": null } } }
    """)

    XCTAssertEqual(plain, wrapped)
  }

  /// Fully migrated account: the flat windows are gone entirely.
  func testMigratedResponseWithNoFlatWindows() throws {
    let result = try buckets("""
    {
      "limits": [
        { "kind": "session", "group": "session", "percent": 33,
          "resets_at": "2026-08-13T20:00:00Z" },
        { "kind": "weekly_all", "group": "weekly", "percent": 55,
          "resets_at": "2026-08-18T00:00:00Z" }
      ]
    }
    """)

    XCTAssertEqual(result.count, 2)
    XCTAssertEqual(result[0].role, .session)
    XCTAssertEqual(result[0].utilization, 33)
    XCTAssertEqual(result[1].role, .weeklyAll)
  }

  /// A single malformed entry must drop only itself.
  func testMalformedLimitEntryDoesNotDropTheRest() throws {
    let result = try buckets("""
    {
      "limits": [
        "this is not an object",
        { "kind": "session", "group": "session", "percent": 33, "resets_at": null }
      ]
    }
    """)

    XCTAssertEqual(result.count, 1)
    XCTAssertEqual(result[0].role, .session)
  }

  /// Per-field fallback: the percentage and the reset time may come from
  /// different sources on a partially-migrated account.
  func testPerFieldFallbackBetweenLimitsAndFlatWindow() throws {
    let result = try buckets("""
    {
      "five_hour": { "utilization": 45.0, "resets_at": "2026-08-13T20:00:00Z" },
      "limits": [
        { "kind": "session", "group": "session", "percent": 47, "resets_at": null }
      ]
    }
    """)

    XCTAssertEqual(result.count, 1)
    XCTAssertEqual(result[0].utilization, 47, "limits[] wins for the value")
    XCTAssertNotNil(result[0].resetsAt, "but the flat window still supplies the reset time")
  }

  func testUtilizationIsNotRescaled() throws {
    let result = try buckets("""
    { "five_hour": { "utilization": 0.7, "resets_at": null } }
    """)

    XCTAssertEqual(result[0].utilization, 0.7, "a genuine 0.7% must not be inflated to 70%")
    XCTAssertEqual(result[0].fraction, 0.007, accuracy: 0.0001)
  }

  func testFractionClampsButUtilizationDoesNot() throws {
    let result = try buckets("""
    { "five_hour": { "utilization": 130.0, "resets_at": null } }
    """)

    XCTAssertEqual(result[0].utilization, 130.0)
    XCTAssertEqual(result[0].fraction, 1.0)
    XCTAssertTrue(result[0].isAlert)
  }

  func testEmptyResponseYieldsNoBuckets() throws {
    XCTAssertTrue(try buckets("{}").isEmpty)
  }

  // MARK: - Downstream contracts

  func testBuildStatsPopulatesLegacyDiscriminators() throws {
    let response = try decode("""
    {
      "five_hour": { "utilization": 45.0, "resets_at": "2026-08-13T20:00:00Z" },
      "seven_day": { "utilization": 70.0, "resets_at": "2026-08-18T00:00:00Z" }
    }
    """)

    let stats = ClaudeWebUsageService.buildStats(from: response)
    XCTAssertEqual(stats.dataSource, .web)
    XCTAssertEqual(stats.fiveHourUtilization, 45.0)
    XCTAssertEqual(stats.sevenDayUtilization, 70.0)
    XCTAssertEqual(stats.buckets.count, 2)
  }

  /// An absent bucket must produce an absent pixlet key — `scoped1_pct=0` would
  /// be indistinguishable from a genuine 0% in the Starlark layouts.
  func testPixletArgsOmitScopedKeyWhenAbsent() {
    var stats = UsageStats()
    stats.dataSource = .web
    stats.buckets = [
      UsageBucket(id: "session", role: .session, displayName: "Session", shortLabel: "Sess",
                  utilization: 45, resetsAt: nil, severity: nil),
      UsageBucket(id: "weekly", role: .weeklyAll, displayName: "Weekly (all)", shortLabel: "Week",
                  utilization: 70, resetsAt: nil, severity: nil),
    ]

    let args = TidbytManager.pixletArgs(for: stats, costLimit: 0, tokenLimit: 0)
    XCTAssertTrue(args.contains("session_pct=45"))
    XCTAssertTrue(args.contains("weekly_pct=70"))
    XCTAssertFalse(args.contains { $0.hasPrefix("scoped1_pct") })
  }

  func testPixletArgsIncludeScopedLabel() {
    var stats = UsageStats()
    stats.dataSource = .web
    stats.buckets = [
      UsageBucket(id: "session", role: .session, displayName: "Session", shortLabel: "Sess",
                  utilization: 45, resetsAt: nil, severity: nil),
      UsageBucket(id: "weekly:fable", role: .weeklyScoped, displayName: "Fable", shortLabel: "Fable",
                  utilization: 71.6, resetsAt: nil, severity: nil),
    ]

    let args = TidbytManager.pixletArgs(for: stats, costLimit: 0, tokenLimit: 0)
    XCTAssertTrue(args.contains("scoped1_pct=72"), "percentages round rather than truncate")
    XCTAssertTrue(args.contains("scoped1_label=Fable"))
  }

  /// Only one scoped bar fits on a 64px display.
  func testPixletArgsEmitAtMostOneScopedBucket() {
    var stats = UsageStats()
    stats.dataSource = .web
    stats.buckets = [
      UsageBucket(id: "weekly:fable", role: .weeklyScoped, displayName: "Fable", shortLabel: "Fable",
                  utilization: 20, resetsAt: nil, severity: nil),
      UsageBucket(id: "weekly:zephyr", role: .weeklyScoped, displayName: "Zephyr", shortLabel: "Zephy",
                  utilization: 90, resetsAt: nil, severity: nil),
    ]

    let args = TidbytManager.pixletArgs(for: stats, costLimit: 0, tokenLimit: 0)
    XCTAssertEqual(args.filter { $0.hasPrefix("scoped1_pct") }.count, 1)
    XCTAssertTrue(args.contains("scoped1_label=Fable"), "the first (preferred) bucket wins")
  }

  func testPixletArgsFallBackToLocalModeWithoutBuckets() {
    var stats = UsageStats()
    stats.dataSource = .local
    stats.cost = 3.4213
    stats.tokens = 125_000

    let args = TidbytManager.pixletArgs(for: stats, costLimit: 18, tokenLimit: 220_000)
    XCTAssertTrue(args.contains("usage=3.42"))
    XCTAssertTrue(args.contains("tokens=125000"))
    XCTAssertTrue(args.contains("cost_limit=18.00"))
    XCTAssertFalse(args.contains { $0.hasPrefix("session_pct") })
  }

  func testShortLabelIsTruncatedForNarrowDisplays() {
    XCTAssertEqual(UsageBucket.shortLabel(for: "Fable"), "Fable")
    XCTAssertEqual(UsageBucket.shortLabel(for: "Some Very Long Model"), "SomeV")
    XCTAssertEqual(UsageBucket.shortLabel(for: "GPT-4.1"), "GPT41")
  }
}
