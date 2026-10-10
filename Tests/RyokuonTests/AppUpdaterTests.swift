import Foundation
import Testing

@testable import Ryokuon

struct AppUpdaterTests {
    @Test func versionsAreComparedNumerically() throws {
        #expect(try #require(AppVersion("v0.1.10")) > #require(AppVersion("0.1.9")))
        #expect(try #require(AppVersion("1.2")) == #require(AppVersion("1.2.0")))
        #expect(AppVersion("v1.2-beta") == nil)
    }

    @Test func releaseMustContainAnExpectedZipWithDigest() throws {
        let json = """
        {"tag_name":"v0.1.3","assets":[
          {"name":"Ryokuon.zip","size":1200000,"digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
           "browser_download_url":"https://github.com/younnieCutler/ryokuon/releases/download/v0.1.3/Ryokuon.zip"}
        ]}
        """
        let release = try JSONDecoder().decode(GitHubRelease.self, from: Data(json.utf8))
        #expect(release.version == "0.1.3")
        #expect(release.installAsset != nil)
        #expect(!GitHubRelease.validDigest("sha256:abcdef"))
        #expect(!GitHubRelease.validDigest("sha256:" + String(repeating: "z", count: 64)))
        #expect(GitHubRelease.validDigest("sha256:" + String(repeating: "A", count: 64)))
        let wrong = json.replacingOccurrences(of: "github.com", with: "example.com")
        #expect(try JSONDecoder().decode(GitHubRelease.self, from: Data(wrong.utf8)).installAsset == nil)
    }
}
