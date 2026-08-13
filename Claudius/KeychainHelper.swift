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

  /// Returns a valid access token, refreshing automatically if expired.
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

/// Owns all access to Claude OAuth credentials.
///
/// Claude Code's keychain item ("Claude Code-credentials") is treated as
/// read-only bootstrap material: decrypting another app's item is what raises
/// the macOS "Always Allow" prompt, and Claude Code resets the item's ACL
/// whenever it rewrites the item, so any grant is eventually lost. This actor
/// therefore reads that item as rarely as possible — it keeps its own copy of
/// the credentials in a Claudius-owned keychain item (which never prompts) and
/// refreshes that copy independently. It goes back to Claude Code's item only
/// when its own refresh lineage is rejected (e.g. after a Claude Code
/// re-login).
///
/// Acquisition is single-flighted so concurrent polls can't stack prompts, and
/// after a denied prompt the actor stops touching Claude Code's item until the
/// user explicitly retries via Sync Now.
actor ClaudeTokenProvider {
  static let shared = ClaudeTokenProvider()

  private static let refreshEndpoint = "https://platform.claude.com/v1/oauth/token"
  private static let oauthClientId = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
  private static let ownService = "Claudius"
  private static let ownAccount = "ClaudeOAuthCredentials"

  private var cachedCreds: KeychainHelper.ClaudeCredentials?
  private var inFlight: Task<String?, Never>?
  private var claudeCodeReadDenied = false
  private(set) var lastProblem: String?

  func validAccessToken(force: Bool) async -> String? {
    if force { claudeCodeReadDenied = false }

    // Fast path: in-memory token still valid (60s buffer) — no keychain, no network.
    if let creds = cachedCreds, Self.isUsable(creds) {
      lastProblem = nil
      return creds.claudeAiOauth.accessToken
    }

    // Single-flight: piggyback on an acquisition already in progress.
    if let inFlight { return await inFlight.value }

    let task = Task { await self.acquireToken() }
    inFlight = task
    let token = await task.value
    inFlight = nil
    return token
  }

  // MARK: Acquisition

  private func acquireToken() async -> String? {
    lastProblem = nil

    // 1. Our own persisted copy — Claudius owns this item, so reading it never prompts.
    if let own = loadOwnCredentials() {
      if Self.isUsable(own) {
        cachedCreds = own
        return own.claudeAiOauth.accessToken
      }

      switch await refresh(creds: own) {
      case .success(let updated):
        store(updated)
        return updated.claudeAiOauth.accessToken
      case .invalidGrant:
        // Our lineage is dead (e.g. Claude Code re-login rotated the family).
        // Discard it and bootstrap fresh from Claude Code's item below.
        print("Claudius Keychain: Own refresh token rejected, re-bootstrapping from Claude Code")
        cachedCreds = nil
        KeychainHelper.shared.delete(service: Self.ownService, account: Self.ownAccount)
      case .transient(let message):
        lastProblem = message
        return nil
      }
    }

    // 2. Bootstrap from Claude Code's item — the only read that can prompt.
    if claudeCodeReadDenied {
      lastProblem = "Keychain access denied — use Sync Now to retry"
      return nil
    }

    switch readClaudeCodeItem() {
    case .found(let creds):
      store(creds)
      if Self.isUsable(creds) {
        return creds.claudeAiOauth.accessToken
      }

      switch await refresh(creds: creds) {
      case .success(let updated):
        store(updated)
        return updated.claudeAiOauth.accessToken
      case .invalidGrant:
        cachedCreds = nil
        KeychainHelper.shared.delete(service: Self.ownService, account: Self.ownAccount)
        lastProblem = "Claude Code login expired — run `claude` and sign in"
        return nil
      case .transient(let message):
        lastProblem = message
        return nil
      }

    case .notFound:
      lastProblem = "Claude Code token not found — sign in with `claude` first"
      return nil

    case .denied(let status):
      claudeCodeReadDenied = true
      lastProblem = "Keychain access denied — use Sync Now to retry"
      print("Claudius Keychain: Claude Code credentials read denied (status: \(status)); pausing keychain reads until Sync Now")
      return nil
    }
  }

  private static func isUsable(_ creds: KeychainHelper.ClaudeCredentials) -> Bool {
    creds.claudeAiOauth.expiresAt / 1000 > Date().timeIntervalSince1970 + 60
  }

  private func store(_ creds: KeychainHelper.ClaudeCredentials) {
    cachedCreds = creds
    if let data = try? JSONEncoder().encode(creds) {
      KeychainHelper.shared.save(data, service: Self.ownService, account: Self.ownAccount)
    }
  }

  private func loadOwnCredentials() -> KeychainHelper.ClaudeCredentials? {
    guard let json = KeychainHelper.shared.read(service: Self.ownService, account: Self.ownAccount),
          let data = json.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode(KeychainHelper.ClaudeCredentials.self, from: data)
  }

  // MARK: Claude Code's keychain item (strictly read-only)

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
      // errSecAuthFailed / errSecUserCanceled: the user declined (or never
      // answered) the "Always Allow" prompt.
      return .denied(status)
    }

    guard let data = result as? Data else { return .notFound }

    do {
      let creds = try JSONDecoder().decode(KeychainHelper.ClaudeCredentials.self, from: data)
      return .found(creds)
    } catch {
      print("Claudius Keychain: Failed to decode Claude Code credentials: \(error)")
      return .notFound
    }
  }

  // MARK: Refresh

  private enum RefreshOutcome {
    case success(KeychainHelper.ClaudeCredentials)
    case invalidGrant
    case transient(String)
  }

  /// Uses the refresh token to obtain a new access token. The result is kept
  /// in Claudius's own keychain item; "Claude Code-credentials" is never
  /// written (rewriting it would reset its ACL and race Claude Code's own
  /// refreshes — the cause of the original repeating prompt loop).
  private func refresh(creds: KeychainHelper.ClaudeCredentials) async -> RefreshOutcome {
    guard let url = URL(string: Self.refreshEndpoint) else {
      return .transient("Token refresh failed (bad endpoint URL)")
    }

    let defaultScopes = ["user:profile", "user:inference", "user:sessions:claude_code", "user:mcp_servers", "user:file_upload"]
    let scopes = (creds.claudeAiOauth.scopes?.isEmpty == false) ? creds.claudeAiOauth.scopes! : defaultScopes

    let body: [String: String] = [
      "grant_type": "refresh_token",
      "refresh_token": creds.claudeAiOauth.refreshToken,
      "client_id": Self.oauthClientId,
      "scope": scopes.joined(separator: " ")
    ]

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try? JSONEncoder().encode(body)

    // Retry up to 3 times with backoff for rate limiting
    for attempt in 0..<3 {
      if attempt > 0 {
        let delay = UInt64(pow(2.0, Double(attempt))) * 1_000_000_000
        try? await Task.sleep(nanoseconds: delay)
      }

      do {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { continue }

        if httpResponse.statusCode == 429 {
          print("Claudius Keychain: Token refresh rate limited, retrying (attempt \(attempt + 1)/3)...")
          continue
        }

        // 400/401/403 mean the refresh token itself was rejected (rotated away
        // or revoked) — retrying won't help; the lineage must be replaced.
        if [400, 401, 403].contains(httpResponse.statusCode) {
          print("Claudius Keychain: Refresh token rejected (HTTP \(httpResponse.statusCode))")
          return .invalidGrant
        }

        guard httpResponse.statusCode == 200 else {
          print("Claudius Keychain: Token refresh failed (HTTP \(httpResponse.statusCode))")
          return .transient("Token refresh failed (HTTP \(httpResponse.statusCode))")
        }

        struct RefreshResponse: Decodable {
          let access_token: String
          let refresh_token: String
          let expires_in: Double
        }

        let refreshed = try JSONDecoder().decode(RefreshResponse.self, from: data)

        var updated = creds
        updated.claudeAiOauth.accessToken = refreshed.access_token
        updated.claudeAiOauth.refreshToken = refreshed.refresh_token
        updated.claudeAiOauth.expiresAt = (Date().timeIntervalSince1970 + refreshed.expires_in) * 1000

        print("Claudius Keychain: Token refreshed successfully")
        return .success(updated)
      } catch {
        print("Claudius Keychain: Token refresh error: \(error)")
        return .transient("Token refresh failed: \(error.localizedDescription)")
      }
    }

    print("Claudius Keychain: Token refresh failed after retries")
    return .transient("Token refresh rate limited — will retry")
  }
}
