import Foundation
import Testing

@testable import hearsay

struct UpdaterTests {
    @Test func versionOrderingUsesNumbers() {
        #expect(AppVersion("0.3.9")! < AppVersion("0.3.10")!)
        #expect(AppVersion("0.99.99")! < AppVersion("1.0.0")!)
        #expect(AppVersion("v0.3.0") == AppVersion("0.3.0"))
    }

    @Test func rejectsInvalidVersions() {
        for input in ["", "0.3", "0..3", "0.3.0-beta", "-1.0.0", "1.0.0.0", "1.0. 0", "99999999999999999999999.0.0"] {
            #expect(AppVersion(input) == nil, "\(input)")
        }
    }

    @Test func selectsMacOSAssetAmongPlatformDownloads() throws {
        let release = try AppRelease.parse(response())
        #expect(release.version == AppVersion("0.3.0"))
        #expect(release.downloadURL.lastPathComponent == "hearsay-0.3.0.zip")
    }

    @Test func rejectsUntrustedOrIncompleteRelease() {
        #expect(throws: UpdateFailure.self) { try AppRelease.parse(response(assetURL: "https://example.com/hearsay-0.3.0.zip")) }
        #expect(throws: UpdateFailure.self) { try AppRelease.parse(response(pageURL: "https://github.com/other/repo/releases/tag/v0.3.0")) }
        #expect(throws: UpdateFailure.self) { try AppRelease.parse(response(assetName: "hearsay-rs-linux-x86_64.zip")) }
        #expect(throws: UpdateFailure.self) { try AppRelease.parse(response(prerelease: true)) }
        #expect(throws: UpdateFailure.self) { try AppRelease.parse(response(draft: true)) }
    }

    private func response(
        assetName: String = "hearsay-0.3.0.zip",
        assetURL: String = "https://github.com/note89/hearsay/releases/download/v0.3.0/hearsay-0.3.0.zip",
        pageURL: String = "https://github.com/note89/hearsay/releases/tag/v0.3.0",
        prerelease: Bool = false,
        draft: Bool = false
    ) -> Data {
        let payload: [String: Any] = [
            "tag_name": "v0.3.0", "html_url": pageURL, "draft": draft, "prerelease": prerelease,
            "assets": [
                [
                    "name": "hearsay-rs-windows-x86_64.zip",
                    "browser_download_url": "https://github.com/note89/hearsay/releases/download/v0.3.0/hearsay-rs-windows-x86_64.zip",
                ],
                ["name": assetName, "browser_download_url": assetURL],
            ],
        ]
        return try! JSONSerialization.data(withJSONObject: payload)
    }
}
