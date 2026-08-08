import Foundation
import Speech

// Step 0 verification: which locales can SpeechTranscriber handle on this machine?
// The whole plan assumes ja-JP works. If it doesn't, stop and rethink.

@main
struct CheckLocales {
    static func main() async {
        await run()
    }
}

func run() async {
let supported = await SpeechTranscriber.supportedLocales
let installed = await SpeechTranscriber.installedLocales

print("isAvailable: \(SpeechTranscriber.isAvailable)")
print("supported count: \(supported.count)")
print("installed count: \(installed.count)")

print("\n--- supported ---")
for locale in supported.sorted(by: { $0.identifier < $1.identifier }) {
    print(locale.identifier)
}

print("\n--- installed ---")
for locale in installed.sorted(by: { $0.identifier < $1.identifier }) {
    print(locale.identifier)
}

print("\n--- targets ---")
for id in ["ja-JP", "ko-KR", "en-US"] {
    let wanted = Locale(identifier: id)
    let match = await SpeechTranscriber.supportedLocale(equivalentTo: wanted)
    let isInstalled = installed.contains { $0.identifier(.bcp47) == match?.identifier(.bcp47) }
    print("\(id): supported=\(match?.identifier ?? "NO") installed=\(isInstalled)")
}
}
