//
//  KeychainHelper.swift
//  Claudius
//
//  Created by Luke Solomon on 3/10/26.
//

import Foundation
import Security

class KeychainHelper {
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

  // MARK: - Claude Code OAuth Token

  private static let credentialsService = "Claude Code-credentials"
  private static let refreshEndpoint = "https://platform.claude.com/v1/oauth/token"
  private static let oauthClientId = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

  // Claudius's own copy of the OAuth credentials.
  //
  // The `Claude Code-credentials` item is owned and frequently rewritten by
  // Claude Code, so its Keychain ACL doesn't durably retain Claudius — reading
  // it on every sync re-triggers the "Claudius wants to access…" prompt no
  // matter how often you click "Always Allow". We mirror the credentials into
  // an item Claudius owns: reads of our own item never prompt, so routine
  // syncs stay silent. Claude Code's item is only read to (re)seed this cache
  // when our copy is missing or its access token has expired.
  private static let cacheService = "comm.claudius.app"
  private static let cacheAccount = "ClaudeOAuthCache"

  struct ClaudeCredentials: Codable {
    var claudeAiOauth: OAuthData

    struct OAuthData: Codable {
      var accessToken: String
      var refreshToken: String
      var expiresAt: Double
      var scopes: [String]?
      var subscriptionType: String?
      var rateLimitTier: String?
    }
  }

  /// Reads the full credentials blob from the Keychain.
  func readClaudeCredentials() -> (data: ClaudeCredentials, raw: Data)? {
    let query = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: Self.credentialsService,
      kSecReturnData: true,
      kSecMatchLimit: kSecMatchLimitOne
    ] as CFDictionary

    var result: AnyObject?
    let status = SecItemCopyMatching(query, &result)

    guard status == errSecSuccess, let data = result as? Data else {
      print("Claudius Keychain: Failed to read Claude Code credentials (status: \(status))")
      return nil
    }

    do {
      let creds = try JSONDecoder().decode(ClaudeCredentials.self, from: data)
      return (creds, data)
    } catch {
      print("Claudius Keychain: Failed to decode Claude Code credentials: \(error)")
      return nil
    }
  }

  /// Writes updated credentials back to the Keychain.
  private func writeClaudeCredentials(_ creds: ClaudeCredentials) {
    guard let data = try? JSONEncoder().encode(creds) else { return }

    let query = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: Self.credentialsService
    ] as CFDictionary

    let update = [kSecValueData: data] as CFDictionary
    let status = SecItemUpdate(query, update)

    if status == errSecItemNotFound {
      let addQuery = [
        kSecClass: kSecClassGenericPassword,
        kSecAttrService: Self.credentialsService,
        kSecValueData: data
      ] as CFDictionary
      SecItemAdd(addQuery, nil)
    }
  }

  /// Reads Claudius's own cached credentials. Reading an item Claudius owns
  /// never prompts, so this is the steady-state path.
  private func readCachedCredentials() -> ClaudeCredentials? {
    guard let json = read(service: Self.cacheService, account: Self.cacheAccount),
          let data = json.data(using: .utf8),
          let creds = try? JSONDecoder().decode(ClaudeCredentials.self, from: data)
    else { return nil }
    return creds
  }

  /// Mirrors credentials into Claudius's own Keychain item.
  private func writeCachedCredentials(_ creds: ClaudeCredentials) {
    guard let data = try? JSONEncoder().encode(creds) else { return }
    save(data, service: Self.cacheService, account: Self.cacheAccount)
  }

  /// Refresh this far ahead of expiry. Claude Code's access token lives ~8h
  /// and both Claude Code and Claudius refresh it. If Claude Code refreshes
  /// first, it rewrites its Keychain item and resets the item's ACL, evicting
  /// Claudius's "Always Allow" grant — so Claudius's next read prompts again.
  /// By refreshing proactively (well before expiry) from our OWN cached refresh
  /// token, Claudius becomes the refresh driver: it never needs to read Claude
  /// Code's item after the initial seed, and it writes the fresh token back so
  /// Claude Code stays supplied and never has to refresh/reset the ACL itself.
  private static let refreshLeadTime: TimeInterval = 30 * 60

  /// Returns a valid access token, refreshing proactively when needed.
  ///
  /// Designed so that, after a one-time seed, Claudius never reads Claude
  /// Code's shared Keychain item again (that read is what re-triggers the
  /// "Always Allow" prompt — see `cacheService`):
  ///   1. Cached token with comfortable runway → use it. Never prompts.
  ///   2. Cached token expiring soon → refresh from the cached refresh token,
  ///      writing the result to both Claude Code's item and our cache. No read
  ///      of Claude Code's item, so no prompt.
  ///   3. No cache, or self-refresh failed (Claude Code rotated the refresh
  ///      token while we were not running) → re-seed from Claude Code's item.
  ///      This is the only path that can prompt, and only in that edge case.
  func readClaudeOAuthToken() async -> String? {
    let now = Date().timeIntervalSince1970

    if let cached = readCachedCredentials() {
      let expiresAtSec = cached.claudeAiOauth.expiresAt / 1000

      // 1. Comfortable runway — use the cached token as-is.
      if expiresAtSec > now + Self.refreshLeadTime {
        return cached.claudeAiOauth.accessToken
      }

      // 2. Expiring soon (or expired) — refresh from our own cached refresh
      //    token, without touching Claude Code's item.
      print("Claudius Keychain: Cached token near expiry, refreshing proactively...")
      if let token = await refreshToken(creds: cached) {
        return token
      }
      // Self-refresh failed — fall through to re-seed from Claude Code's item.
      print("Claudius Keychain: Self-refresh failed, re-seeding from Claude Code's item")
    }

    // 3. Seed/fallback: read Claude Code's item (the only read that can prompt).
    guard let (creds, _) = readClaudeCredentials() else { return nil }

    if creds.claudeAiOauth.expiresAt / 1000 > now + 60 {
      writeCachedCredentials(creds)
      return creds.claudeAiOauth.accessToken
    }

    print("Claudius Keychain: Access token expired, refreshing...")
    return await refreshToken(creds: creds)
  }

  /// Uses the refresh token to obtain a new access token.
  private func refreshToken(creds: ClaudeCredentials) async -> String? {
    guard let url = URL(string: Self.refreshEndpoint) else { return nil }

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

        guard httpResponse.statusCode == 200 else {
          print("Claudius Keychain: Token refresh failed (HTTP \(httpResponse.statusCode))")
          return nil
        }

        struct RefreshResponse: Decodable {
          let access_token: String
          let refresh_token: String
          let expires_in: Double
        }

        let refreshed = try JSONDecoder().decode(RefreshResponse.self, from: data)

        // Update the credentials in the Keychain
        var updated = creds
        updated.claudeAiOauth.accessToken = refreshed.access_token
        updated.claudeAiOauth.refreshToken = refreshed.refresh_token
        updated.claudeAiOauth.expiresAt = (Date().timeIntervalSince1970 + refreshed.expires_in) * 1000
        writeClaudeCredentials(updated)   // keep Claude Code's item in sync
        writeCachedCredentials(updated)   // and refresh Claudius's own cache

        print("Claudius Keychain: Token refreshed successfully")
        return refreshed.access_token
      } catch {
        print("Claudius Keychain: Token refresh error: \(error)")
        return nil
      }
    }

    print("Claudius Keychain: Token refresh failed after retries")
    return nil
  }
}
