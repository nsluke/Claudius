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

  /// Reads the OAuth access token that Claude Code stores in the macOS Keychain.
  /// Service: "Claude Code-credentials", no specific account.
  /// The stored value is JSON: { "claudeAiOauth": { "accessToken": "...", "expiresAt": ... } }
  func readClaudeOAuthToken() -> String? {
    let query = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: "Claude Code-credentials",
      kSecReturnData: true,
      kSecMatchLimit: kSecMatchLimitOne
    ] as CFDictionary

    var result: AnyObject?
    let status = SecItemCopyMatching(query, &result)

    guard status == errSecSuccess, let data = result as? Data else {
      print("Claudius Keychain: Failed to read Claude Code credentials (status: \(status))")
      return nil
    }

    struct KeychainCredentials: Decodable {
      let claudeAiOauth: OAuthData

      struct OAuthData: Decodable {
        let accessToken: String
        let expiresAt: Double
      }
    }

    do {
      let decoder = JSONDecoder()
      decoder.keyDecodingStrategy = .convertFromSnakeCase
      let creds = try decoder.decode(KeychainCredentials.self, from: data)

      if creds.claudeAiOauth.expiresAt <= Date().timeIntervalSince1970 {
        print("Claudius Keychain: OAuth token has expired")
        return nil
      }

      return creds.claudeAiOauth.accessToken
    } catch {
      print("Claudius Keychain: Failed to decode Claude Code credentials: \(error)")
      return nil
    }
  }
}
