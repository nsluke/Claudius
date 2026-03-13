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
}
