import Testing
@testable import Claudius

/// pixlet is required for every Tidbyt push — cloud and Tronbyt alike — so the
/// lookup order and the "not installed" signal are worth pinning. The filesystem
/// check is injected so these don't depend on whether the machine running them
/// happens to have pixlet installed.
@Suite("pixlet discovery")
struct PixletDiscoveryTests {

  private static let candidates = [
    "/opt/homebrew/bin/pixlet",
    "/usr/local/bin/pixlet",
    "/Users/test/go/bin/pixlet",
    "/Users/test/.local/bin/pixlet",
  ]

  @Test("resolves the first candidate that exists")
  func resolvesFirstExisting() {
    let path = TidbytManager.resolvePixletPath(candidates: Self.candidates) {
      $0 == "/usr/local/bin/pixlet" || $0 == "/Users/test/go/bin/pixlet"
    }
    #expect(path == "/usr/local/bin/pixlet", "earlier candidates win")
  }

  @Test("returns nil when pixlet is installed nowhere")
  func nilWhenAbsent() {
    #expect(TidbytManager.resolvePixletPath(candidates: Self.candidates) { _ in false } == nil)
  }

  /// Each install location must be reachable on its own — a typo in any one
  /// entry would otherwise only show up for users who install that way.
  @Test("finds pixlet at each supported location", arguments: candidates)
  func findsEachLocation(installed: String) {
    #expect(TidbytManager.resolvePixletPath(candidates: Self.candidates) { $0 == installed } == installed)
  }

  @Test("an empty candidate list resolves to nil rather than trapping")
  func emptyCandidates() {
    #expect(TidbytManager.resolvePixletPath(candidates: []) { _ in true } == nil)
  }

  @Test("the shipped candidate list is non-empty and absolute")
  func shippedCandidatesAreSane() {
    #expect(!TidbytManager.pixletCandidates.isEmpty)
    #expect(TidbytManager.pixletCandidates.allSatisfy { $0.hasPrefix("/") })
  }
}
