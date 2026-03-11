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
  let message: AssistantMessage?
}

private struct AssistantMessage: Decodable {
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
private enum Pricing {
  static let sonnetInput:         Double = 3.00
  static let sonnetCacheCreate:   Double = 3.75
  static let sonnetCacheRead:     Double = 0.30
  static let sonnetOutput:        Double = 15.00

  static let opusInput:           Double = 15.00
  static let opusCacheCreate:     Double = 18.75
  static let opusCacheRead:       Double = 1.50
  static let opusOutput:          Double = 75.00

  static func costUSD(for usage: TokenUsage, model: String?) -> Double {
    let isOpus = model?.contains("opus") ?? false
    let inputRate        = isOpus ? opusInput        : sonnetInput
    let cacheCreateRate  = isOpus ? opusCacheCreate  : sonnetCacheCreate
    let cacheReadRate    = isOpus ? opusCacheRead     : sonnetCacheRead
    let outputRate       = isOpus ? opusOutput       : sonnetOutput

    let inp   = Double(usage.input_tokens ?? 0)
    let cc    = Double(usage.cache_creation_input_tokens ?? 0)
    let cr    = Double(usage.cache_read_input_tokens ?? 0)
    let out   = Double(usage.output_tokens ?? 0)

    return (inp * inputRate + cc * cacheCreateRate + cr * cacheReadRate + out * outputRate) / 1_000_000
  }
}

// MARK: - TidbytManager

struct TidbytManager {

  // MARK: Public entry point

  static func fetchAndPush() async -> UsageStats? {
    guard
      let tidbytToken = KeychainHelper.shared.read(service: "ClaudeTidbyt", account: "TidbytToken"),
      let deviceID    = UserDefaults.standard.string(forKey: "TidbytDeviceID"),
      !tidbytToken.isEmpty, !deviceID.isEmpty
    else {
      print("Claudius: missing Tidbyt credentials")
      return nil
    }

    let stats = readTodayUsage()
    print("Claudius: today = $\(String(format: "%.4f", stats.cost)), \(stats.tokens) tokens, \(stats.messages) messages")

    let costLimit  = UserDefaults.standard.double(forKey: "CostLimit")
    let tokenLimit = UserDefaults.standard.integer(forKey: "TokenLimit")

    let pushed = await runPixlet(usage: stats.cost, tokens: stats.tokens, token: tidbytToken, deviceID: deviceID,
                                 costLimit: costLimit, tokenLimit: tokenLimit)
    guard pushed else { return nil }

    return stats
  }

  // MARK: - Local log parsing

  /// Walks every JSONL file under ~/.claude/projects/, sums token usage
  /// for assistant turns whose timestamp falls on today (local calendar).
  static func readTodayUsage() -> UsageStats {
    let fm = FileManager.default
    let home = fm.homeDirectoryForCurrentUser
    let projectsDir = home.appendingPathComponent(".claude/projects")

    guard let projectEnum = fm.enumerator(
      at: projectsDir,
      includingPropertiesForKeys: [.isRegularFileKey],
      options: []   // do NOT skip hidden files — .claude is a dotfile directory
    ) else {
      print("Claudius: cannot enumerate \(projectsDir.path)")
      return UsageStats()
    }

    let windowStart = Date().addingTimeInterval(-5 * 60 * 60)
    let decoder = JSONDecoder()

    // Must include .withFractionalSeconds — timestamps are e.g. "2026-03-10T20:04:32.253Z"
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

    var stats = UsageStats()
    
    // Group turns by conversation to find the "peak" usage of each active thread.
    // This prevents double-counting the growing history sent in every turn.
    var conversationPeaks: [String: (cost: Double, tokens: Int, date: Date)] = [:]

    for case let fileURL as URL in projectEnum {
      guard fileURL.pathExtension == "jsonl" else { continue }
      guard let lines = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }

      lines.enumerateLines { line, _ in
        guard let data = line.data(using: .utf8),
              let entry = try? decoder.decode(SessionEntry.self, from: data),
              entry.type == "assistant",
              let ts = entry.timestamp,
              let date = iso.date(from: ts),
              date >= windowStart,
              let usage = entry.message?.usage
        else { return }

        // sessionId groups all messages in a single Claude Code conversation.
        let convId = entry.sessionId ?? entry.uuid ?? ts
        
        let currentCost = Pricing.costUSD(for: usage, model: entry.message?.model)
        let currentTokens = (usage.input_tokens ?? 0) 
                          + (usage.output_tokens ?? 0)
                          + (usage.cache_creation_input_tokens ?? 0)

        // For each conversation, we only keep the LATEST (most complete) turn's token count,
        // as that count includes all previous turns in that thread.
        if let existing = conversationPeaks[convId] {
          if date > existing.date {
            conversationPeaks[convId] = (currentCost, currentTokens, date)
          }
        } else {
          conversationPeaks[convId] = (currentCost, currentTokens, date)
          stats.messages += 1 // Count unique threads/starts
        }
        
        if stats.oldestMessageDate == nil || date < stats.oldestMessageDate! {
            stats.oldestMessageDate = date
        }
      }
    }

    // Final sum is the total of all the "peaks" of conversations active in the window.
    for peak in conversationPeaks.values {
      stats.cost += peak.cost
      stats.tokens += peak.tokens
    }

    return stats
  }

  // MARK: - Pixlet rendering & push

  /// Returns true on success. Runs pixlet on a background thread so it
  /// doesn't block the Swift cooperative thread pool with waitUntilExit().
  @discardableResult
  private static func runPixlet(usage: Double, tokens: Int, token: String, deviceID: String,
                                costLimit: Double, tokenLimit: Int) async -> Bool {
    guard let starFilePath = Bundle.main.path(forResource: "claude_usage", ofType: "star") else {
      print("Claudius: claude_usage.star not found in bundle")
      return false
    }

    let outputPath = NSTemporaryDirectory() + "claude_usage.webp"
    let formattedUsage   = String(format: "%.2f", usage)
    let formattedTokens  = tokens >= 1_000
      ? String(format: "%.1fk", Double(tokens) / 1_000)
      : "\(tokens)"

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
            "render", starFilePath,
            "-o", outputPath,
            "usage=\(formattedUsage)",
            "tokens=\(tokens)",
          ]
          // Only pass limits when the user has configured them; otherwise
          // let the .star file fall back to its own defaults.
          if costLimit  > 0 { args.append("cost_limit=\(String(format: "%.2f", costLimit))") }
          if tokenLimit > 0 { args.append("token_limit=\(tokenLimit)") }
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
          if ok { print("Claudius: pushed $\(formattedUsage) / \(formattedTokens) tokens") }
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
