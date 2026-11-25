import Foundation
import Testing
@testable import RobustaCore

/// Carrega uma fixture de `Fixtures/` como texto.
func fixture(_ name: String) throws -> String {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "Fixtures"))
    return try String(contentsOf: url, encoding: .utf8)
}

@Test func realFixtureIsAvailable() throws {
    let text = try fixture("sched-real-2026-11-24")
    #expect(text.contains("Repeating power events:"))
    #expect(text.contains("Scheduled power events:"))
}

/// O repositório é público: fixture só pode ter owner do sistema ou do app.
@Test func fixturesHaveOnlyPublishableOwners() throws {
    let urls = try #require(Bundle.module.urls(forResourcesWithExtension: "txt", subdirectory: "Fixtures"))
    #expect(urls.count >= 6)
    let ownerPattern = /by '([^']*)'/
    for url in urls {
        let text = try String(contentsOf: url, encoding: .utf8)
        for match in text.matches(of: ownerPattern) {
            let owner = String(match.1)
            let allowed = owner.hasPrefix("com.apple.") || owner == "robusta" || owner.hasPrefix("robusta.")
            #expect(allowed, "owner não publicável '\(owner)' em \(url.lastPathComponent)")
        }
    }
}

@Test func ownersAreDistinct() {
    #expect(Robusta.OwnerID.manual != Robusta.OwnerID.agenda)
}
