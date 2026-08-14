//
//  UsageBucket.swift
//  Claudius
//
//  The usage-API domain model.
//
//  Anthropic's OAuth usage endpoint used to report exactly two windows
//  (`five_hour` and `seven_day`). It now also reports per-model caps — such as
//  the weekly carve-out that applies to Fable — and the shape it reports them
//  in has already changed once: flat `seven_day_<model>` keys are being
//  superseded by a top-level `limits[]` array whose entries carry their own
//  model scope.
//
//  So nothing here hardcodes a bucket name. The wire types below decode
//  defensively (every field optional, unknown keys tolerated, malformed
//  entries dropped rather than failing the whole response) and `UsageBucket`
//  represents whatever windows the server actually reported. A bucket for a
//  model we've never heard of renders correctly, labelled with the API's own
//  display name; a bucket that disappears simply stops rendering.
//

import Foundation
import SwiftUI

// MARK: - Bucket model

enum BucketRole: String, Equatable {
  /// The rolling 5-hour session window.
  case session
  /// The account-wide weekly window.
  case weeklyAll
  /// A weekly window that applies only to one model (e.g. Fable).
  case weeklyScoped
}

/// One usage window as reported by the server, normalized for display.
struct UsageBucket: Identifiable, Equatable {
  /// Stable across refreshes: "session", "weekly", or "weekly:<name>".
  let id: String
  let role: BucketRole
  /// The API's own display name, verbatim. Never invented locally.
  let displayName: String
  /// ≤5 characters, for the menu bar and the 64px-wide Tidbyt layouts.
  let shortLabel: String
  /// Percentage 0…100 as reported. Never rescaled — see `fraction`.
  let utilization: Double
  let resetsAt: Date?
  /// Opaque passthrough ("normal" / "warning" / "critical" / future values).
  let severity: String?

  /// Display fraction, clamped to 0…1. The raw `utilization` is left alone
  /// because the server may legitimately report over 100.
  var fraction: Double { min(max(utilization / 100.0, 0), 1) }

  var isAlert: Bool { fraction >= 0.9 }
}

// MARK: - Presentation

extension UsageBucket {
  static let sessionHex     = "#4caf50"
  static let weeklyAllHex   = "#d97757"
  static let weeklyScopedHex = "#7c6bd9"
  static let alertHex       = "#ff0000"

  /// Single source of truth for bucket colors. The `.star` Tidbyt layouts
  /// carry their own copies of these hex values — keep them in sync by hand.
  var hexColor: String {
    if isAlert { return Self.alertHex }
    switch role {
    case .session:      return Self.sessionHex
    case .weeklyAll:    return Self.weeklyAllHex
    case .weeklyScoped: return Self.weeklyScopedHex
    }
  }

  var color: Color { isAlert ? .red : Color(hex: hexColor) }

  /// Ordering hint for surfaces that can only show one scoped bucket.
  /// This is a *preference*, never a filter — a model missing from this list
  /// still displays, it just sorts after the ones named here. Overridable via
  /// UserDefaults so a server-side rename can be worked around without a release.
  static var scopedPreference: [String] {
    if let override = UserDefaults.standard.array(forKey: "ScopedBucketPreference") as? [String],
       !override.isEmpty {
      return override
    }
    return ["Fable", "Mythos", "Opus"]
  }

  /// Derives a ≤5-character label from a display name.
  static func shortLabel(for displayName: String) -> String {
    let alnum = displayName.filter { $0.isLetter || $0.isNumber }
    return String(alnum.prefix(5))
  }
}

// MARK: - Wire types

/// A coding key that accepts any string, so we can walk keys we don't know about.
struct AnyCodingKey: CodingKey {
  let stringValue: String
  var intValue: Int? { nil }
  init(_ stringValue: String) { self.stringValue = stringValue }
  init?(stringValue: String) { self.stringValue = stringValue }
  init?(intValue: Int) { return nil }
}

/// Wraps a decode so one malformed element doesn't fail the whole array.
struct FailableDecodable<T: Decodable>: Decodable {
  let value: T?
  init(from decoder: Decoder) throws {
    value = try? T(from: decoder)
  }
}

/// A flat usage window (`five_hour`, `seven_day`, `seven_day_<model>`, …).
///
/// Every field is optional on purpose: `resets_at` has been observed as `null`
/// on real responses, and a non-optional field would throw and take the entire
/// response down with it.
struct UsageWindow: Decodable {
  var utilization: Double?
  var resets_at: String?
  // limit_dollars / used_dollars / remaining_dollars are deliberately ignored:
  // null in every response anyone has published, so the populated shape is unknown.
}

/// An entry in the newer top-level `limits[]` array.
struct LimitEntry: Decodable {
  struct Scope: Decodable {
    struct Model: Decodable {
      /// Observed null even for models that have a real cap — never match on this.
      var id: String?
      /// The field to match on.
      var display_name: String?
    }
    var model: Model?
    var surface: String?
  }

  var kind: String?      // "session" | "weekly_all" | "weekly_scoped" | future values
  var group: String?     // "session" | "weekly"
  var percent: Double?   // note: `percent` here, `utilization` on flat windows
  var severity: String?
  var resets_at: String?
  var scope: Scope?
  var is_active: Bool?

  /// True when this entry describes a cap that applies to a single model.
  var isModelScoped: Bool {
    if kind == "weekly_scoped" { return true }
    return group == "weekly" && scope?.model != nil
  }
}

/// The usage endpoint response.
///
/// Decoded by walking every top-level key rather than declaring a fixed set,
/// because the key set demonstrably grows: responses have been published with
/// 8, 16, and 17 top-level keys across a few months, including opaque
/// codenames that come and go.
struct OAuthUsageResponse: Decodable {
  /// Flat window objects, keyed by their top-level name.
  var windows: [String: UsageWindow] = [:]
  var limits: [LimitEntry] = []
  /// Keys that looked like windows but carried no utilization — logged, not shown.
  var unmappedKeys: [String] = []

  /// Top-level keys that are known *not* to be usage windows.
  private static let nonWindowKeys: Set<String> = [
    "limits",
    "model_scoped",
    "extra_usage",
    "spend",
    "member_dashboard_available",
  ]

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: AnyCodingKey.self)

    // The CLI's control-protocol variant of this payload wraps everything in
    // `rate_limits`. Unwrap it transparently so the same decoder works if the
    // HTTP endpoint ever adopts that envelope — but only when the nested object
    // actually carries usage data. A `rate_limits` key holding something else
    // (say, request-rate config) must not swallow the real response.
    if let key = AnyCodingKey(stringValue: "rate_limits"),
       container.contains(key),
       let inner = try? container.decode(OAuthUsageResponse.self, forKey: key),
       !inner.windows.isEmpty || !inner.limits.isEmpty {
      self = inner
      return
    }

    for key in container.allKeys {
      let name = key.stringValue

      if name == "limits" {
        let entries = try? container.decode([FailableDecodable<LimitEntry>].self, forKey: key)
        limits = entries?.compactMap(\.value) ?? []
        continue
      }

      if Self.nonWindowKeys.contains(name) { continue }

      // A null value, a bool, a string, or any other non-object shape throws
      // inside `try?` and is skipped. A genuinely new window type is picked up
      // for free.
      guard let window = try? container.decode(UsageWindow.self, forKey: key) else { continue }

      // Kept even when `utilization` is nil: the window may still carry a
      // `resets_at` that the per-field fallback in merge() needs. Buckets are
      // only *created* from a non-nil utilization.
      windows[name] = window
      if window.utilization == nil {
        unmappedKeys.append(name)
      }
    }
  }
}

// MARK: - Merge

extension UsageBucket {

  /// Builds the ordered bucket list from a decoded response.
  ///
  /// `limits[]` is authoritative where it overlaps the flat windows, but the
  /// fallback is per-field rather than per-bucket: on partially-migrated
  /// accounts a percentage and its reset time can come from different sources.
  static func merge(from response: OAuthUsageResponse) -> [UsageBucket] {
    var buckets: [UsageBucket] = []

    // --- Session -----------------------------------------------------------
    let sessionLimit = response.limits.first { $0.kind == "session" }
    let sessionWindow = response.windows["five_hour"]
    if let pct = sessionLimit?.percent ?? sessionWindow?.utilization {
      buckets.append(UsageBucket(
        id: "session",
        role: .session,
        displayName: "Session",
        shortLabel: "Sess",
        utilization: pct,
        resetsAt: parseISO8601(sessionLimit?.resets_at) ?? parseISO8601(sessionWindow?.resets_at),
        severity: sessionLimit?.severity
      ))
    }

    // --- Account-wide weekly ----------------------------------------------
    let weeklyLimit = response.limits.first { $0.kind == "weekly_all" }
    let weeklyWindow = response.windows["seven_day"]
    if let pct = weeklyLimit?.percent ?? weeklyWindow?.utilization {
      buckets.append(UsageBucket(
        id: "weekly",
        role: .weeklyAll,
        displayName: "Weekly (all)",
        shortLabel: "Week",
        utilization: pct,
        resetsAt: parseISO8601(weeklyLimit?.resets_at) ?? parseISO8601(weeklyWindow?.resets_at),
        severity: weeklyLimit?.severity
      ))
    }

    // --- Model-scoped weekly caps (Fable et al.) ---------------------------
    var scoped: [UsageBucket] = []
    var seen = Set<String>()

    for entry in response.limits where entry.isModelScoped {
      guard let rawName = entry.scope?.model?.display_name?
              .trimmingCharacters(in: .whitespacesAndNewlines),
            !rawName.isEmpty,
            let pct = entry.percent
      else { continue }

      let key = rawName.lowercased()

      // Per-field fallback, same as the session and weekly windows get: a
      // migrating account can carry the percentage in limits[] and the reset
      // time only on the matching flat key.
      let flatKey = "seven_day_" + key.replacingOccurrences(of: " ", with: "_")
      let resetsAt = parseISO8601(entry.resets_at)
        ?? parseISO8601(response.windows[flatKey]?.resets_at)

      // Accounts that aren't eligible for a model still get an entry for it,
      // zeroed with no reset time. Showing that as a real 0% bar is noise.
      if pct == 0 && resetsAt == nil { continue }

      guard !seen.contains(key) else { continue }
      seen.insert(key)

      scoped.append(UsageBucket(
        id: "weekly:\(key)",
        role: .weeklyScoped,
        displayName: rawName,
        shortLabel: shortLabel(for: rawName),
        utilization: pct,
        resetsAt: resetsAt,
        severity: entry.severity
      ))
    }

    // Legacy fallback: flat `seven_day_<model>` keys, for accounts that haven't
    // been migrated to `limits[]`. Skipped entirely once the server speaks
    // `limits[]`, which is authoritative — otherwise a non-model window such as
    // `seven_day_oauth_apps` would be promoted to a phantom "Oauth Apps" cap.
    // Sorted for deterministic ordering.
    for name in response.limits.isEmpty ? response.windows.keys.sorted() : []
    where name.hasPrefix("seven_day_") {
      guard let window = response.windows[name], let pct = window.utilization else { continue }

      let display = titleCased(String(name.dropFirst("seven_day_".count)))
      let key = display.lowercased()
      // A bare "seven_day_" key would otherwise yield a blank-labelled bucket.
      guard !key.isEmpty, !seen.contains(key) else { continue }

      let resetsAt = parseISO8601(window.resets_at)
      if pct == 0 && resetsAt == nil { continue }
      seen.insert(key)

      scoped.append(UsageBucket(
        id: "weekly:\(key)",
        role: .weeklyScoped,
        displayName: display,
        shortLabel: shortLabel(for: display),
        utilization: pct,
        resetsAt: resetsAt,
        severity: nil
      ))
    }

    // Preferred models first, then by descending utilization.
    let preference = scopedPreference.map { $0.lowercased() }
    // Matched by containment so a full product name ("Claude Fable 4.5") still
    // ranks against the short name in the preference list.
    func rank(_ displayName: String) -> Int {
      let lower = displayName.lowercased()
      return preference.firstIndex { lower.contains($0) } ?? Int.max
    }
    scoped.sort { a, b in
      let ra = rank(a.displayName)
      let rb = rank(b.displayName)
      if ra != rb { return ra < rb }
      if a.utilization != b.utilization { return a.utilization > b.utilization }
      return a.displayName < b.displayName
    }

    buckets.append(contentsOf: scoped)
    return buckets
  }

  /// "opus" → "Opus", "some_model" → "Some Model".
  private static func titleCased(_ raw: String) -> String {
    raw.split(separator: "_")
      .map { $0.prefix(1).uppercased() + $0.dropFirst() }
      .joined(separator: " ")
  }
}

// MARK: - Helpers

/// Parses an ISO 8601 timestamp with or without fractional seconds.
func parseISO8601(_ string: String?) -> Date? {
  guard let string, !string.isEmpty else { return nil }
  let withFraction = ISO8601DateFormatter()
  withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  return withFraction.date(from: string) ?? ISO8601DateFormatter().date(from: string)
}

extension Color {
  init(hex: String) {
    let h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
    var rgb: UInt64 = 0
    Scanner(string: h).scanHexInt64(&rgb)
    self.init(
      red:   Double((rgb >> 16) & 0xFF) / 255,
      green: Double((rgb >> 8)  & 0xFF) / 255,
      blue:  Double( rgb        & 0xFF) / 255
    )
  }
}
