import Testing

@testable import Ryokuon

struct LocalizationTests {
    @Test func followsSystemPreferredLanguageOrder() {
        #expect(Localization.defaultLanguage(preferred: ["ko-KR", "ja-KR"]) == "ko")
        #expect(Localization.defaultLanguage(preferred: ["ja-JP", "ko-KR"]) == "ja")
        #expect(Localization.defaultLanguage(preferred: ["fr-FR", "en-US"]) == "en")
        #expect(Localization.defaultLanguage(preferred: ["zh-Hans-CN"]) == "en") // unsupported -> English
    }
}
