//
//  TidbytManager.swift
//  Claudius
//
//  Created by Luke Solomon on 3/10/26.
//

import Foundation

// MARK: - Claude Code JSONL Models

private struct SessionEntry: Decodable {
  let type: String
  let timestamp: String?
  let uuid: String?
  let sessionId: String?
  let requestId: String?
  let message: AssistantMessage?
}

private struct AssistantMessage: Decodable {
  let id: String?
  let model: String?
  let usage: TokenUsage?
}

private struct TokenUsage: Decodable {
  let input_tokens: Int?
  let cache_creation_input_tokens: Int?
  let cache_read_input_tokens: Int?
  let output_tokens: Int?
}

// MARK: - Pricing (per 1M tokens)
// Rates sourced from Anthropic's public pricing page.
// Matches claude-code-usage-monitor's PricingCalculator.FALLBACK_PRICING.
private enum Pricing {
  static let sonnetInput:         Double = 3.00
  static let sonnetCacheCreate:   Double = 3.75
  static let sonnetCacheRead:     Double = 0.30
  static let sonnetOutput:        Double = 15.00

  static let opusInput:           Double = 15.00
  static let opusCacheCreate:     Double = 18.75
  static let opusCacheRead:       Double = 1.50
  static let opusOutput:          Double = 75.00

  static let haikuInput:          Double = 0.25
  static let haikuCacheCreate:    Double = 0.30
  static let haikuCacheRead:      Double = 0.03
  static let haikuOutput:         Double = 1.25

  static func costUSD(for usage: TokenUsage, model: String?) -> Double {
    let modelLower = model?.lowercased() ?? ""
    let isOpus  = modelLower.contains("opus")
    let isHaiku = modelLower.contains("haiku")

    let inputRate:       Double
    let cacheCreateRate: Double
    let cacheReadRate:   Double
    let outputRate:      Double

    if isOpus {
      inputRate       = opusInput
      cacheCreateRate = opusCacheCreate
      cacheReadRate   = opusCacheRead
      outputRate      = opusOutput
    } else if isHaiku {
      inputRate       = haikuInput
      cacheCreateRate = haikuCacheCreate
      cacheReadRate   = haikuCacheRead
      outputRate      = haikuOutput
    } else {
      // Default to Sonnet pricing
      inputRate       = sonnetInput
      cacheCreateRate = sonnetCacheCreate
      cacheReadRate   = sonnetCacheRead
      outputRate      = sonnetOutput
    }

    let inp   = Double(usage.input_tokens ?? 0)
    let cc    = Double(usage.cache_creation_input_tokens ?? 0)
    let cr    = Double(usage.cache_read_input_tokens ?? 0)
    let out   = Double(usage.output_tokens ?? 0)

    return (inp * inputRate + cc * cacheCreateRate + cr * cacheReadRate + out * outputRate) / 1_000_000
  }

  /// Total token count for rate-limit tracking (input + output only).
  /// Matches claude-code-usage-monitor's _create_base_block_dict "totalTokens"
  /// which is input_tokens + output_tokens (cache tokens excluded).
  static func totalTokens(for usage: TokenUsage) -> Int {
    (usage.input_tokens ?? 0)
      + (usage.output_tokens ?? 0)
  }
}

/// Lightweight holder for a parsed JSONL entry before block assignment.
private struct ParsedEntry {
  let date: Date
  let usage: TokenUsage
  let model: String?
  let messageId: String?
  let requestId: String?
  let filePath: String
}

// MARK: - TidbytManager

struct TidbytManager {

  // MARK: Public entry point

  static func push(stats: UsageStats) async -> Bool {
    guard
      let tidbytToken = KeychainHelper.shared.read(service: "ClaudeTidbyt", account: "TidbytToken"),
      let deviceIDString = UserDefaults.standard.string(forKey: "TidbytDeviceID"),
      !tidbytToken.isEmpty, !deviceIDString.isEmpty
    else {
      print("Claudius: missing Tidbyt credentials")
      return false
    }

    let deviceIDs = deviceIDString.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }

    let costLimit  = UserDefaults.standard.double(forKey: "CostLimit")
    let tokenLimit = UserDefaults.standard.integer(forKey: "TokenLimit")

    let layout = UserDefaults.standard.string(forKey: "TidbytLayout") ?? "Default"
    let starFileName = {
        switch layout {
        case "Minimal": return "claude_minimal"
        case "Graph": return "claude_graph"
        default: return "claude_usage"
        }
    }()

    // Build pixlet args based on data source
    var pixletArgs: [String] = []

    if let sessionPct = stats.fiveHourUtilization {
      // Web mode: pass utilization percentages
      pixletArgs.append("session_pct=\(Int(sessionPct))")
      if let weeklyPct = stats.sevenDayUtilization {
        pixletArgs.append("weekly_pct=\(Int(weeklyPct))")
      }
      print("Claudius: pushing session=\(Int(sessionPct))%, weekly=\(Int(stats.sevenDayUtilization ?? 0))%")
    } else {
      // Local mode: pass raw cost/tokens
      pixletArgs.append("usage=\(String(format: "%.2f", stats.cost))")
      pixletArgs.append("tokens=\(stats.tokens)")
      if costLimit  > 0 { pixletArgs.append("cost_limit=\(String(format: "%.2f", costLimit))") }
      if tokenLimit > 0 { pixletArgs.append("token_limit=\(tokenLimit)") }
      print("Claudius: pushing $\(String(format: "%.4f", stats.cost)), \(stats.tokens) tokens")
    }

    var allPushed = true
    for deviceID in deviceIDs {
      let pushed = await runPixlet(extraArgs: pixletArgs, token: tidbytToken, deviceID: deviceID, starFileName: starFileName)
      if !pushed { allPushed = false }
    }

    return allPushed
  }

  // MARK: - Local log parsing

  /// Walks every JSONL file under ~/.claude/projects/, detects discrete
  /// 5-hour session blocks (matching claude-code-usage-monitor's
  /// SessionAnalyzer.transform_to_blocks), and sums token usage for
  /// assistant turns in the currently-active block only.
  static func readTodayUsage(from directory: URL? = nil) -> UsageStats {
    let fm = FileManager.default
    let projectsDir = directory ?? fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")

    guard let projectEnum = fm.enumerator(
      at: projectsDir,
      includingPropertiesForKeys: [.isRegularFileKey],
      options: []   // do NOT skip hidden files — .claude is a dotfile directory
    ) else {
      print("Claudius: cannot enumerate \(projectsDir.path)")
      return UsageStats()
    }

    // Look back 10h to capture block boundaries before the active session.
    let lookbackStart = Date().addingTimeInterval(-10 * 3600)
    let decoder = JSONDecoder()

    // Use a more robust date parsing strategy. ISO8601DateFormatter can be
    // picky about fractional second length.
    let dateFormatter = DateFormatter()
    dateFormatter.calendar = Calendar(identifier: .iso8601)
    dateFormatter.locale = Locale(identifier: "en_US_POSIX")
    dateFormatter.timeZone = TimeZone(secondsFromGMT: 0)
    dateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX"

    // Pre-allocate fallback formatter outside the loop — these are expensive.
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

    // ── Phase 1: Collect all assistant entries within lookback window ──

    var rawEntries: [ParsedEntry] = []
    var filesProcessed = 0
    var dateParseFailures = 0

    for case let fileURL as URL in projectEnum {
      filesProcessed += 1
      guard fileURL.pathExtension == "jsonl" else { continue }
      guard let lines = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }

      lines.enumerateLines { line, _ in
        guard let data = line.data(using: .utf8),
              let entry = try? decoder.decode(SessionEntry.self, from: data),
              entry.type == "assistant",
              let ts = entry.timestamp
        else { return }

        let date = dateFormatter.date(from: ts) ?? iso.date(from: ts)
        guard let validDate = date else {
          dateParseFailures += 1
          return
        }
        guard validDate >= lookbackStart else { return }
        guard let usage = entry.message?.usage else { return }

        rawEntries.append(ParsedEntry(
          date: validDate,
          usage: usage,
          model: entry.message?.model,
          messageId: entry.message?.id,
          requestId: entry.requestId,
          filePath: fileURL.path
        ))
      }
    }

    guard !rawEntries.isEmpty else {
      print("Claudius: No assistant entries found in lookback window")
      return UsageStats()
    }

    // ── Phase 2: Sort chronologically and detect session blocks ──
    // Matches claude-code-usage-monitor's SessionAnalyzer.transform_to_blocks:
    // • Block start = hour-rounded timestamp of first entry in block (UTC)
    // • Block end   = block start + 5 hours
    // • New block when entry.date >= blockEnd OR gap between entries >= 5h

    rawEntries.sort { $0.date < $1.date }

    let sessionDuration: TimeInterval = 5 * 3600
    var utcCal = Calendar(identifier: .gregorian)
    utcCal.timeZone = TimeZone(secondsFromGMT: 0)!

    func roundToHour(_ date: Date) -> Date {
      utcCal.dateInterval(of: .hour, for: date)?.start ?? date
    }

    struct BlockBounds {
      let start: Date
      let end: Date
    }

    var blockStart = roundToHour(rawEntries[0].date)
    var blockEnd = blockStart.addingTimeInterval(sessionDuration)
    var previousDate = rawEntries[0].date

    var blocks: [BlockBounds] = [BlockBounds(start: blockStart, end: blockEnd)]
    var entryBlockIndex: [Int] = [0]

    for i in 1..<rawEntries.count {
      let entryDate = rawEntries[i].date
      let needsNewBlock = entryDate >= blockEnd
        || entryDate.timeIntervalSince(previousDate) >= sessionDuration

      if needsNewBlock {
        blockStart = roundToHour(entryDate)
        blockEnd = blockStart.addingTimeInterval(sessionDuration)
        blocks.append(BlockBounds(start: blockStart, end: blockEnd))
      }

      entryBlockIndex.append(blocks.count - 1)
      previousDate = entryDate
    }

    // ── Phase 3: Find active block ──
    // Active block = most recent block whose end > now.
    // If no block is currently active, fall back to the most recent block.

    let now = Date()
    var activeIdx = blocks.count - 1
    for i in stride(from: blocks.count - 1, through: 0, by: -1) {
      if blocks[i].end > now {
        activeIdx = i
        break
      }
    }

    let activeBlock = blocks[activeIdx]

    // ── Phase 4: Sum entries in the active block with streaming dedup ──

    var stats = UsageStats()
    var seenFiles = Set<String>()

    // Deduplicate streaming entries: each API call produces multiple JSONL
    // lines (streaming snapshots) sharing the same message.id + requestId.
    // Matches claude-code-usage-monitor's _create_unique_hash dedup.
    var seenMessageHashes = Set<String>()
    var assistantLinesParsed = 0
    var dedupSkipped = 0

    for i in 0..<rawEntries.count {
      guard entryBlockIndex[i] == activeIdx else { continue }
      let entry = rawEntries[i]

      // Dedup: skip streaming duplicates. Claude Code logs multiple
      // JSONL entries per API call (streaming snapshots → final).
      // Keep only the first occurrence per message.id:requestId hash.
      if let msgId = entry.messageId, let reqId = entry.requestId,
         !msgId.isEmpty, !reqId.isEmpty {
        let hash = "\(msgId):\(reqId)"
        guard seenMessageHashes.insert(hash).inserted else {
          dedupSkipped += 1
          continue
        }
      }

      assistantLinesParsed += 1

      // Cost: sum every API call's cost (all 4 token types with pricing).
      stats.cost += Pricing.costUSD(for: entry.usage, model: entry.model)

      // Tokens: sum input_tokens + output_tokens (cache tokens excluded).
      // Matches claude-code-usage-monitor's _create_base_block_dict "totalTokens".
      let turnTotal = Pricing.totalTokens(for: entry.usage)
      stats.tokens += turnTotal

      // Count unique JSONL files as separate conversations/threads.
      if seenFiles.insert(entry.filePath).inserted {
        stats.messages += 1
      }

      // Bucket total tokens into 10-minute time series slots
      // relative to the active block's start.
      let bucketIndex = Int(entry.date.timeIntervalSince(activeBlock.start) / 600)
      if bucketIndex >= 0 && bucketIndex < 30 {
        stats.tokenTimeSeries[bucketIndex] += turnTotal
      }

      if stats.oldestMessageDate == nil || entry.date < stats.oldestMessageDate! {
        stats.oldestMessageDate = entry.date
      }
      if stats.newestMessageDate == nil || entry.date > stats.newestMessageDate! {
        stats.newestMessageDate = entry.date
      }
    }

    print("Claudius: Scanned \(filesProcessed) files, \(rawEntries.count) entries in lookback. " +
          "Active block \(activeIdx + 1)/\(blocks.count): \(assistantLinesParsed) unique messages " +
          "(dedup skipped \(dedupSkipped), date parse failures \(dateParseFailures))")
    print("Claudius: Active conversations: \(seenFiles.count)")

    return stats
  }

  // MARK: - Pixlet rendering & push

  /// Returns true on success. Runs pixlet on a background thread so it
  /// doesn't block the Swift cooperative thread pool with waitUntilExit().
  @discardableResult
  private static func runPixlet(extraArgs: [String], token: String, deviceID: String,
                                starFileName: String) async -> Bool {
    guard let starFilePath = Bundle.main.path(forResource: starFileName, ofType: "star") else {
      print("Claudius Error: \(starFileName).star not found in bundle resources")
      return false
    }

    if !FileManager.default.fileExists(atPath: starFilePath) {
      print("Claudius Error: Bundle path found but file does not exist at: \(starFilePath)")
      return false
    }

    // Pixlet scans the directory for ALL .star files and tries to
    // compile them together. When multiple star layouts live in the
    // same Resources folder, this causes "file does not exist" errors.
    // Fix: copy the needed star file to an isolated temp directory.
    let isolatedDir = NSTemporaryDirectory() + "claudius_pixlet/"
    let isolatedStarPath = isolatedDir + "\(starFileName).star"
    let fm_pixlet = FileManager.default
    try? fm_pixlet.createDirectory(atPath: isolatedDir, withIntermediateDirectories: true)
    // Remove any stale star files from previous renders
    if let contents = try? fm_pixlet.contentsOfDirectory(atPath: isolatedDir) {
      for file in contents where file.hasSuffix(".star") {
        try? fm_pixlet.removeItem(atPath: isolatedDir + file)
      }
    }
    try? fm_pixlet.copyItem(atPath: starFilePath, toPath: isolatedStarPath)

    print("Claudius: Executing pixlet render with \(isolatedStarPath)")

    let outputPath = NSTemporaryDirectory() + "claude_usage.webp"

    // Resolve pixlet from common install locations at runtime.
    let pixletCandidates = [
      "/opt/homebrew/bin/pixlet",       // Homebrew Apple Silicon
      "/usr/local/bin/pixlet",          // Homebrew Intel
      "\(FileManager.default.homeDirectoryForCurrentUser.path)/go/bin/pixlet",
      "\(FileManager.default.homeDirectoryForCurrentUser.path)/.local/bin/pixlet",
    ]
    guard let pixletPath = pixletCandidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
      print("Claudius: pixlet not found — install via https://github.com/tidbyt/pixlet")
      return false
    }

    return await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .utility).async {
        do {
          let render = Process()
          render.executableURL = URL(fileURLWithPath: pixletPath)
          var args = [
            "render", isolatedStarPath,
            "-o", outputPath,
          ]
          args.append(contentsOf: extraArgs)
          render.arguments = args
          try render.run()
          render.waitUntilExit()

          guard render.terminationStatus == 0 else {
            print("Claudius: pixlet render failed (exit \(render.terminationStatus))")
            continuation.resume(returning: false)
            return
          }

          let push = Process()
          push.executableURL = URL(fileURLWithPath: pixletPath)
          push.arguments = ["push", "--api-token", token, "--installation-id", "claudius", deviceID, outputPath]
          try push.run()
          push.waitUntilExit()

          let ok = push.terminationStatus == 0
          if ok { print("Claudius: pushed to Tidbyt device \(deviceID)") }
          else  { print("Claudius: pixlet push failed (exit \(push.terminationStatus))") }
          continuation.resume(returning: ok)
        } catch {
          print("Claudius: pixlet error: \(error)")
          continuation.resume(returning: false)
        }
      }
    }
  }
}
