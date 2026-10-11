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

struct LocalizationCoverageTests {
    @Test func allVisibleStringsHaveTranslations() {
        for language in Localization.supportedLanguages {
            for key in L10nKey.allCases {
                #expect(!Localization.string(key, language: language.id).isEmpty)
            }
        }
    }
}
