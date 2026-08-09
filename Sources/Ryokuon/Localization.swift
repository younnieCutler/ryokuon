import Foundation

/// App UI language — separate from the STT transcription language
/// (`AppState.language`, Q7). The two are independent on purpose: this
/// session's own test case is a Korean speaker (UI language) recording and
/// transcribing in Japanese (STT language) by default.
///
/// A plain dictionary instead of `.lproj`/`Localizable.strings`: three
/// languages, ~50 short strings, no plurals/pluralization rules needed.
/// The standard Foundation localization path also doesn't switch live
/// without a Bundle-swap hack (`NSApp` reads `AppleLanguages` once at
/// launch) — reading straight from `AppState.appLanguage` (an `@Observable`
/// property) means every label just re-renders when the setting changes,
/// no restart required.
enum L10nKey {
    case onboardingTitle, onboardingSubtitle
    case permMicTitle, permMicExplanation
    case permCaptureTitle, permCaptureExplanation
    case permFolderTitle, permFolderExplanation // %@ = folder path
    case permRequestButton
    case statusGranted, statusDenied, statusNotDetermined
    case emptyTitle, emptySubtitle
    case recoveredBadge
    case settingsTitle
    case settingsTranscriptionLanguage, settingsTranscriptionLanguageNote
    case settingsAppLanguage, settingsAppLanguageNote
    case settingsStorageFolder, settingsChangeFolder, settingsClose
    case sessionNamePlaceholder, sessionPlay, sessionStop
    case gainMe, gainRemote
    case transcribeButton, retranscribeButton, notTranscribedYet
    case startRecordingWithName // %@ = target app name
    case pickAnotherApp, startRecording, noSoundApps
    case recordingTitle // %@ = target app name
    case recordingStop
    case menuOpenSessions, menuQuit, menuNoSoundApps
    case langJa, langKo, langEn
    case errorRecovered // %d = count
    case errorLastTargetNotRunning // %@ = app name
    case errorPermissionsIncomplete
    case errorStartFailed, errorStopFailed, errorPlayFailed // %@ = error description
    case errorStorageChangeFailed, errorTranscribeFailed // %@ = error description
    case errorNoAudioFile
    case progressStarting, progressConvertingFLAC
    case statusReady, statusRecording, statusProcessing
    case currentMicLabel, currentAppLabel
    case searchPlaceholder
    case detailNoSelection
    case editButton, doneButton, deleteButton, renameButton
    case cancelButton, confirmButton
    case deleteConfirmTitle // %d = count
    case deleteConfirmMessage
}

enum Localization {
    /// BCP-47-ish but just the language subtag — UI doesn't need region
    /// variants the way STT locales do.
    static let supportedLanguages: [(id: String, label: String)] = [
        ("ko", "한국어"), ("ja", "日本語"), ("en", "English"),
    ]

    static func defaultLanguage() -> String {
        let code = Locale.current.language.languageCode?.identifier ?? "ko"
        return supportedLanguages.contains { $0.id == code } ? code : "ko"
    }

    static func string(_ key: L10nKey, language: String) -> String {
        (table[language] ?? table["ko"]!)[key] ?? (table["ko"]![key] ?? "")
    }

    private static let table: [String: [L10nKey: String]] = [
        "ko": [
            .statusReady: "준비됨",
            .statusRecording: "녹음 중",
            .statusProcessing: "처리 중",
            .currentMicLabel: "마이크",
            .currentAppLabel: "캡처 대상",
            .searchPlaceholder: "검색",
            .detailNoSelection: "세션을 선택하세요",
            .onboardingTitle: "Ryokuon 시작하기",
            .onboardingSubtitle: "녹음을 시작하기 전에 세 가지 권한이 필요해요.",
            .permMicTitle: "마이크",
            .permMicExplanation: "내 목소리를 녹음하기 위해 마이크를 사용합니다.",
            .permCaptureTitle: "오디오 캡처",
            .permCaptureExplanation: "상대방 목소리를 녹음하기 위해 선택한 앱의 소리를 가져옵니다.",
            .permFolderTitle: "저장 폴더",
            .permFolderExplanation: "녹음 파일을 %@에 저장합니다.",
            .permRequestButton: "허용 요청",
            .statusGranted: "허용됨",
            .statusDenied: "거부됨",
            .statusNotDetermined: "대기중",
            .emptyTitle: "아직 녹음이 없어요",
            .emptySubtitle: "위에서 녹음을 시작해보세요",
            .recoveredBadge: "복구됨",
            .settingsTitle: "설정",
            .settingsTranscriptionLanguage: "전사 언어",
            .settingsTranscriptionLanguageNote: "새 녹음부터 적용됩니다",
            .settingsAppLanguage: "앱 언어",
            .settingsAppLanguageNote: "즉시 적용됩니다",
            .settingsStorageFolder: "저장 폴더",
            .settingsChangeFolder: "폴더 변경",
            .settingsClose: "닫기",
            .sessionNamePlaceholder: "세션 이름",
            .sessionPlay: "재생",
            .sessionStop: "정지",
            .gainMe: "나",
            .gainRemote: "상대",
            .transcribeButton: "전사하기",
            .retranscribeButton: "다시 전사하기",
            .notTranscribedYet: "아직 전사되지 않음",
            .startRecordingWithName: "녹음 시작 — %@",
            .pickAnotherApp: "다른 앱 선택",
            .startRecording: "녹음 시작",
            .noSoundApps: "소리 내는 앱이 없음 — 녹음할 앱에서 소리를 먼저 재생해줘",
            .recordingTitle: "녹음 중 — %@",
            .recordingStop: "종료",
            .menuOpenSessions: "세션 목록 열기",
            .menuQuit: "종료",
            .menuNoSoundApps: "지금 소리 내는 앱 없음",
            .langJa: "일본어", .langKo: "한국어", .langEn: "영어",
            .errorRecovered: "이전 실행이 비정상 종료됨 — %d개 녹음 복구됨",
            .errorLastTargetNotRunning: "마지막으로 녹음한 앱(%@)이 지금 실행 중이 아님 — 다른 앱 선택 필요",
            .errorPermissionsIncomplete: "권한 설정을 먼저 끝내야 함",
            .errorStartFailed: "녹음 시작 실패: %@",
            .errorStopFailed: "녹음 종료 중 오류: %@",
            .errorPlayFailed: "재생 실패: %@",
            .errorStorageChangeFailed: "저장 폴더 변경 실패: %@",
            .errorTranscribeFailed: "전사 실패: %@",
            .errorNoAudioFile: "재생할 오디오 파일 없음",
            .progressStarting: "시작",
            .progressConvertingFLAC: "FLAC 변환 중",
            .editButton: "편집",
            .doneButton: "완료",
            .deleteButton: "삭제",
            .renameButton: "이름 변경",
            .cancelButton: "취소",
            .confirmButton: "확인",
            .deleteConfirmTitle: "%d개 세션을 삭제할까요?",
            .deleteConfirmMessage: "삭제한 녹음은 복구할 수 없습니다.",
        ],
        "ja": [
            .statusReady: "準備完了",
            .statusRecording: "録音中",
            .statusProcessing: "処理中",
            .currentMicLabel: "マイク",
            .currentAppLabel: "キャプチャ対象",
            .searchPlaceholder: "検索",
            .detailNoSelection: "セッションを選択してください",
            .onboardingTitle: "Ryokuon を始める",
            .onboardingSubtitle: "録音を始める前に3つの権限が必要です。",
            .permMicTitle: "マイク",
            .permMicExplanation: "自分の声を録音するためにマイクを使用します。",
            .permCaptureTitle: "オーディオキャプチャ",
            .permCaptureExplanation: "相手の声を録音するために、選択したアプリの音声を取得します。",
            .permFolderTitle: "保存フォルダ",
            .permFolderExplanation: "録音ファイルを%@に保存します。",
            .permRequestButton: "許可をリクエスト",
            .statusGranted: "許可済み",
            .statusDenied: "拒否済み",
            .statusNotDetermined: "未確認",
            .emptyTitle: "まだ録音がありません",
            .emptySubtitle: "上のボタンから録音を始めましょう",
            .recoveredBadge: "復旧済み",
            .settingsTitle: "設定",
            .settingsTranscriptionLanguage: "文字起こし言語",
            .settingsTranscriptionLanguageNote: "次の録音から適用されます",
            .settingsAppLanguage: "アプリの言語",
            .settingsAppLanguageNote: "すぐに適用されます",
            .settingsStorageFolder: "保存フォルダ",
            .settingsChangeFolder: "フォルダを変更",
            .settingsClose: "閉じる",
            .sessionNamePlaceholder: "セッション名",
            .sessionPlay: "再生",
            .sessionStop: "停止",
            .gainMe: "自分",
            .gainRemote: "相手",
            .transcribeButton: "文字起こしする",
            .retranscribeButton: "再文字起こし",
            .notTranscribedYet: "まだ文字起こしされていません",
            .startRecordingWithName: "録音開始 — %@",
            .pickAnotherApp: "他のアプリを選択",
            .startRecording: "録音開始",
            .noSoundApps: "音を出しているアプリがありません — 録音したいアプリで先に音を再生してください",
            .recordingTitle: "録音中 — %@",
            .recordingStop: "終了",
            .menuOpenSessions: "セッション一覧を開く",
            .menuQuit: "終了",
            .menuNoSoundApps: "音を出しているアプリがありません",
            .langJa: "日本語", .langKo: "韓国語", .langEn: "英語",
            .errorRecovered: "前回異常終了しました — %d件の録音を復旧しました",
            .errorLastTargetNotRunning: "最後に録音したアプリ（%@）が実行されていません — 他のアプリを選択してください",
            .errorPermissionsIncomplete: "先に権限設定を完了してください",
            .errorStartFailed: "録音開始に失敗: %@",
            .errorStopFailed: "録音終了時にエラー: %@",
            .errorPlayFailed: "再生に失敗: %@",
            .errorStorageChangeFailed: "保存フォルダの変更に失敗: %@",
            .errorTranscribeFailed: "文字起こしに失敗: %@",
            .errorNoAudioFile: "再生できる音声ファイルがありません",
            .progressStarting: "開始",
            .progressConvertingFLAC: "FLAC変換中",
            .editButton: "編集",
            .doneButton: "完了",
            .deleteButton: "削除",
            .renameButton: "名前を変更",
            .cancelButton: "キャンセル",
            .confirmButton: "確認",
            .deleteConfirmTitle: "%d件のセッションを削除しますか？",
            .deleteConfirmMessage: "削除した録音は復元できません。",
        ],
        "en": [
            .statusReady: "Ready",
            .statusRecording: "Recording",
            .statusProcessing: "Processing",
            .currentMicLabel: "Microphone",
            .currentAppLabel: "Capturing",
            .searchPlaceholder: "Search",
            .detailNoSelection: "Select a session",
            .onboardingTitle: "Get Started with Ryokuon",
            .onboardingSubtitle: "Three permissions are needed before you can start recording.",
            .permMicTitle: "Microphone",
            .permMicExplanation: "Uses the microphone to record your voice.",
            .permCaptureTitle: "Audio Capture",
            .permCaptureExplanation: "Captures audio from the app you choose, to record the other side's voice.",
            .permFolderTitle: "Storage Folder",
            .permFolderExplanation: "Saves recordings to %@.",
            .permRequestButton: "Request Access",
            .statusGranted: "Granted",
            .statusDenied: "Denied",
            .statusNotDetermined: "Not Determined",
            .emptyTitle: "No recordings yet",
            .emptySubtitle: "Start a recording above",
            .recoveredBadge: "Recovered",
            .settingsTitle: "Settings",
            .settingsTranscriptionLanguage: "Transcription Language",
            .settingsTranscriptionLanguageNote: "Applies to new recordings",
            .settingsAppLanguage: "App Language",
            .settingsAppLanguageNote: "Applies immediately",
            .settingsStorageFolder: "Storage Folder",
            .settingsChangeFolder: "Change Folder",
            .settingsClose: "Close",
            .sessionNamePlaceholder: "Session Name",
            .sessionPlay: "Play",
            .sessionStop: "Stop",
            .gainMe: "Me",
            .gainRemote: "Remote",
            .transcribeButton: "Transcribe",
            .retranscribeButton: "Re-transcribe",
            .notTranscribedYet: "Not transcribed yet",
            .startRecordingWithName: "Start Recording — %@",
            .pickAnotherApp: "Choose Another App",
            .startRecording: "Start Recording",
            .noSoundApps: "No app is making sound — play something in the app you want to record first",
            .recordingTitle: "Recording — %@",
            .recordingStop: "Stop",
            .menuOpenSessions: "Open Session List",
            .menuQuit: "Quit",
            .menuNoSoundApps: "No app is making sound right now",
            .langJa: "Japanese", .langKo: "Korean", .langEn: "English",
            .errorRecovered: "Previous run ended unexpectedly — recovered %d recording(s)",
            .errorLastTargetNotRunning: "The last recorded app (%@) isn't running — choose another app",
            .errorPermissionsIncomplete: "Finish setting up permissions first",
            .errorStartFailed: "Failed to start recording: %@",
            .errorStopFailed: "Error while stopping recording: %@",
            .errorPlayFailed: "Playback failed: %@",
            .errorStorageChangeFailed: "Failed to change storage folder: %@",
            .errorTranscribeFailed: "Transcription failed: %@",
            .errorNoAudioFile: "No audio file to play",
            .progressStarting: "Starting",
            .progressConvertingFLAC: "Converting to FLAC",
            .editButton: "Edit",
            .doneButton: "Done",
            .deleteButton: "Delete",
            .renameButton: "Rename",
            .cancelButton: "Cancel",
            .confirmButton: "OK",
            .deleteConfirmTitle: "Delete %d session(s)?",
            .deleteConfirmMessage: "Deleted recordings cannot be recovered.",
        ],
    ]
}
