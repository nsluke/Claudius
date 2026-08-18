//
//  KeychainHelper.swift
//  Claudius
//
//  Created by Luke Solomon on 3/10/26.
//

import Foundation
import Security

final class KeychainHelper: Sendable {
  static let shared = KeychainHelper()

  func save(_ data: Data, service: String, account: String) {
    let query = [
      kSecValueData: data,
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: service,
      kSecAttrAccount: account,
      kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock
    ] as CFDictionary

    SecItemDelete(query) // Clear existing
    SecItemAdd(query, nil)
  }

  func read(service: String, account: String) -> String? {
    let query = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: service,
      kSecAttrAccount: account,
      kSecReturnData: true
    ] as CFDictionary

    var result: AnyObject?
    SecItemCopyMatching(query, &result)

    guard let data = result as? Data else { return nil }
    return String(data: data, encoding: .utf8)
  }

  func delete(service: String, account: String) {
    let query = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: service,
      kSecAttrAccount: account
    ] as CFDictionary

    SecItemDelete(query)
  }

  // MARK: - Claude Code OAuth Token

  static let claudeCodeService = "Claude Code-credentials"

  struct ClaudeCredentials: Codable, Sendable {
    var claudeAiOauth: OAuthData

    struct OAuthData: Codable, Sendable {
      var accessToken: String
      var refreshToken: String
      var expiresAt: Double
      var scopes: [String]?
      var subscriptionType: String?
      var rateLimitTier: String?
    }
  }

  /// Promptless check that Claude Code's credentials item exists. Asks for
  /// attributes only — never the secret data — so the keychain ACL is not
  /// consulted and no "Always Allow" prompt can appear.
  func claudeCredentialsPresent() -> Bool {
    let query = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: Self.claudeCodeService,
      kSecReturnAttributes: true,
      kSecMatchLimit: kSecMatchLimitOne
    ] as CFDictionary

    var result: AnyObject?
    return SecItemCopyMatching(query, &result) == errSecSuccess
  }

  /// Returns Claude Code's access token if it is currently valid.
  /// Never refreshes — see ClaudeTokenProvider for why.
  /// Pass `force: true` (Sync Now) to retry after a denied keychain prompt.
  func readClaudeOAuthToken(force: Bool = false) async -> String? {
    await ClaudeTokenProvider.shared.validAccessToken(force: force)
  }

  /// User-facing reason the last token acquisition failed, if it did.
  func claudeAuthProblem() async -> String? {
    await ClaudeTokenProvider.shared.lastProblem
  }
}


// MARK: - Claude token provider

/// Reads Claude Code's OAuth access token. **Read-only, and deliberately does
/// not refresh.**
///
/// Two things were learned the hard way here.
///
/// 1. Claudius must not *write* Claude Code's Keychain item. Writing is a
///    separate Keychain permission from reading, so an "Always Allow" grant
///    never covered it, and every failed write re-prompted — the original
///    prompt-loop bug.
///
/// 2. Claudius must not *refresh* the token either. OAuth refresh tokens here
///    are single-use with rotation: whoever redeems one invalidates the copy
///    everybody else holds. With write-back removed, a refresh by Claudius
///    would rotate the family and leave Claude Code holding a dead refresh
///    token — breaking the login of the tool Claudius depends on. Refreshing
///    is Claude Code's job.
///
/// So the contract is: read the access token, use it while it is valid, and
/// when it expires simply wait for Claude Code to refresh it. Callers fall
/// back to the desktop cache or local logs in the meantime.
actor ClaudeTokenProvider {
  static let shared = ClaudeTokenProvider()

  /// An item this stale means nothing is maintaining it any more — the usual
  /// cause is that Claude Code is being run through the desktop app, which
  /// keeps credentials in its own store and never touches this one again.
  private static let abandonedAfter: TimeInterval = 2 * 24 * 60 * 60

  private var cachedCreds: KeychainHelper.ClaudeCredentials?
  private var inFlight: Task<String?, Never>?
  private var claudeCodeReadDenied = false
  private var cleanedUpLegacyItem = false
  private(set) var lastProblem: String?

  func validAccessToken(force: Bool) async -> String? {
    if force { claudeCodeReadDenied = false }

    // Fast path: in-memory token still valid (60s buffer) — no Keychain access.
    if let creds = cachedCreds, Self.isUsable(creds) {
      lastProblem = nil
      return creds.claudeAiOauth.accessToken
    }

    // Single-flight so concurrent polls can't stack Keychain prompts.
    if let inFlight { return await inFlight.value }

    let task = Task { self.acquireToken() }
    inFlight = task
    let token = await task.value
    inFlight = nil
    return token
  }

  // MARK: Acquisition

  private func acquireToken() -> String? {
    lastProblem = nil
    cleanUpLegacyItemOnce()

    if claudeCodeReadDenied {
      lastProblem = "Keychain access denied — use Sync Now to retry"
      return nil
    }

    switch readClaudeCodeItem() {
    case .found(let creds):
      cachedCreds = creds
      if Self.isUsable(creds) {
        return creds.claudeAiOauth.accessToken
      }
      // Expired. Claude Code will refresh it the next time it runs; we just
      // wait. Say so precisely, because a token that never gets refreshed
      // means nothing is maintaining this item any more.
      lastProblem = expiredTokenExplanation()
      return nil

    case .notFound:
      lastProblem = "Claude Code token not found — sign in with `claude` first"
      return nil

    case .denied(let status):
      claudeCodeReadDenied = true
      lastProblem = "Keychain access denied — use Sync Now to retry"
      print("Claudius Keychain: read denied (status: \(status)); pausing until Sync Now")
      return nil
    }
  }

  /// Distinguishes "expired, will be refreshed shortly" from "nobody has
  /// touched this item in days, so it is never going to be refreshed".
  private func expiredTokenExplanation() -> String {
    guard let modified = claudeCodeItemModifiedAt() else {
      return "Claude Code token expired — open Claude Code to refresh it"
    }

    let age = Date().timeIntervalSince(modified)
    guard age > Self.abandonedAfter else {
      return "Claude Code token expired — open Claude Code to refresh it"
    }

    let days = Int(age / 86_400)
    print("Claudius Keychain: Claude Code has not updated its credentials in \(days) day(s) " +
          "— if you run Claude Code via the desktop app, that item is no longer maintained")
    return "Claude Code's Keychain token is \(days)d stale — using the Claude app's usage cache"
  }

  private static func isUsable(_ creds: KeychainHelper.ClaudeCredentials) -> Bool {
    creds.claudeAiOauth.expiresAt / 1000 > Date().timeIntervalSince1970 + 60
  }

  /// Claudius 3.0.2 kept its own copy of the credentials so it could refresh
  /// independently. That design is gone; remove the leftover item so a stale
  /// refresh token isn't sitting in the user's Keychain forever.
  private func cleanUpLegacyItemOnce() {
    guard !cleanedUpLegacyItem else { return }
    cleanedUpLegacyItem = true
    KeychainHelper.shared.delete(service: "Claudius", account: "ClaudeOAuthCredentials")
  }

  // MARK: Claude Code's Keychain item (strictly read-only)

  private enum ClaudeCodeReadResult {
    case found(KeychainHelper.ClaudeCredentials)
    case notFound
    case denied(OSStatus)
  }

  private func readClaudeCodeItem() -> ClaudeCodeReadResult {
    let query = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: KeychainHelper.claudeCodeService,
      kSecReturnData: true,
      kSecMatchLimit: kSecMatchLimitOne
    ] as CFDictionary

    var result: AnyObject?
    let status = SecItemCopyMatching(query, &result)

    guard status == errSecSuccess else {
      if status == errSecItemNotFound {
        print("Claudius Keychain: No Claude Code credentials item found")
        return .notFound
      }
      return .denied(status)
    }

    guard let data = result as? Data else { return .notFound }

    do {
      return .found(try JSONDecoder().decode(KeychainHelper.ClaudeCredentials.self, from: data))
    } catch {
      print("Claudius Keychain: Failed to decode Claude Code credentials: \(error)")
      return .notFound
    }
  }

  /// Attributes-only query — reads the item's modification date without
  /// decrypting it, so this can never trigger a prompt.
  private func claudeCodeItemModifiedAt() -> Date? {
    let query = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: KeychainHelper.claudeCodeService,
      kSecReturnAttributes: true,
      kSecMatchLimit: kSecMatchLimitOne
    ] as CFDictionary

    var result: AnyObject?
    guard SecItemCopyMatching(query, &result) == errSecSuccess,
          let attrs = result as? [String: Any] else { return nil }
    return attrs[kSecAttrModificationDate as String] as? Date
  }
}
