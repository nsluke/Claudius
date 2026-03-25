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

  /// Returns a valid access token, refreshing automatically if expired.
  func readClaudeOAuthToken() async -> String? {
    guard let (creds, _) = readClaudeCredentials() else { return nil }

    let expiresAtSec = creds.claudeAiOauth.expiresAt / 1000
    let now = Date().timeIntervalSince1970

    // If the token is still valid (with 60s buffer), return it
    if expiresAtSec > now + 60 {
      return creds.claudeAiOauth.accessToken
    }

    // Token expired or about to expire — refresh it
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
        writeClaudeCredentials(updated)

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
