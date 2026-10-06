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
    case settingsInputDevice, settingsOutputDevice, deviceSystemDefault
    case settingsUpdates, updateCurrentVersion, updateCheck, updateChecking
    case updateUpToDate, updateInstall, updatePreparing
    case sessionNamePlaceholder, sessionPlay, sessionStop
    case gainMe, gainRemote
    case transcribeButton, retranscribeButton, notTranscribedYet
    case transcribeEmptyHint, transcribeRunning, transcribeQueued, transcribeLanguageSection, transcribeHelp
    case transcribeNoSpeechTitle, transcribeNoSpeechHint // hint: %@ = language name
    case importHelp, exportHelp, detailNoSelectionHint
    case startRecordingWithName // %@ = target app name
    case pickAnotherApp, startRecording, noSoundApps
    case recordTargetLabel, recordTargetNone, recordTargetChoose
    case recordingTitle // %@ = target app name
    case recordingStop
    case menuOpenSessions, menuQuit, menuNoSoundApps
    case langAuto, langJa, langKo, langEn
    case progressDetectingLanguage
    case errorRecovered // %d = count
    case errorLastTargetNotRunning // %@ = app name
    case errorPermissionsIncomplete
    case errorStartFailed, errorStopFailed, errorPlayFailed // %@ = error description
    case errorStorageChangeFailed, errorTranscribeFailed // %@ = error description
    case errorMicSwitchFailed // %@ = error description
    case errorOperationBusy, errorMetadataSaveFailed, errorDeleteFailed
    case errorNoAudioFile
    case progressStarting, progressConvertingFLAC
    case progressMeTrack, progressRemoteTrack, progressDownloadingModel // model: %@ = "42%"
    case statusReady, statusRecording, statusProcessing
    case currentMicLabel, currentAppLabel
    case searchPlaceholder
    case libraryRefresh, libraryImportForTranscription, libraryExpanded, libraryCollapsed
    case detailNoSelection
    case editButton, doneButton, deleteButton, renameButton
    case cancelButton, confirmButton
    case deleteConfirmTitle // %d = count
    case deleteConfirmMessage
    case importButton, exportButton, exportTitle
    case exportPreview, exportAll, exportLength // exportLength: %@
    case importingFile, dropHint // importingFile: %@
    case exportQuality, qualityVoice, qualityCompact, qualityStandard
    case exportRangeHint, formatMP3Subtitle, formatMDSubtitle, formatNeedsLame, formatNeedsTranscript
    case formatUtterances // %d
    case exportRunFormats // %@ = "MP3 + MD"
    case exportRun, lameMissing
    case errorImportFailed, errorExportFailed // %@ = error description
}

enum Localization {
    /// BCP-47-ish but just the language subtag — UI doesn't need region
    /// variants the way STT locales do.
    static let supportedLanguages: [(id: String, label: String)] = [
        ("ko", "한국어"), ("ja", "日本語"), ("en", "English"),
    ]

    /// First supported language in the system's preferred list (System
    /// Settings → Language & Region order), else English. Not
    /// `Locale.current`: for an app bundle that resolves through the app's
    /// own localizations and fell back to English even on a Korean system.
    static func defaultLanguage(preferred: [String] = Locale.preferredLanguages) -> String {
        for identifier in preferred {
            let code = Locale(identifier: identifier).language.languageCode?.identifier ?? ""
            if supportedLanguages.contains(where: { $0.id == code }) { return code }
        }
        return "en"
    }

    static func string(_ key: L10nKey, language: String) -> String {
        (table[language] ?? table["ko"]!)[key] ?? (table["ko"]![key] ?? "")
    }

    private static let table: [String: [L10nKey: String]] = [
        "ko": [
            .errorOperationBusy: "작업이 끝난 뒤 다시 시도해 주세요.",
            .errorMetadataSaveFailed: "변경 내용을 저장하지 못했습니다: %@",
            .errorDeleteFailed: "삭제하지 못했습니다: %@",

            .statusReady: "준비됨",
            .statusRecording: "녹음 중",
            .statusProcessing: "처리 중",
            .currentMicLabel: "마이크",
            .currentAppLabel: "캡처 대상",
            .searchPlaceholder: "검색",
            .detailNoSelection: "녹음을 선택하세요",
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
            .emptyTitle: "아직 음원이 없어요",
            .libraryRefresh: "폴더 새로고침",
            .libraryImportForTranscription: "전사할 녹음으로 가져오기",
            .libraryExpanded: "펼쳐짐",
            .libraryCollapsed: "접힘",
            .settingsUpdates: "앱 업데이트",
            .updateCurrentVersion: "현재 버전",
            .updateCheck: "GitHub에서 새 버전 확인",
            .updateChecking: "새 버전 확인 중…",
            .updateUpToDate: "최신 버전입니다 (%@)",
            .updateInstall: "버전 %@ 설치 및 재실행",
            .updatePreparing: "다운로드하고 검증하는 중…",
            .emptySubtitle: "아래에서 녹음을 시작하거나 오디오 파일을 끌어다 놓으세요",
            .recoveredBadge: "복구됨",
            .settingsTitle: "설정",
            .settingsTranscriptionLanguage: "텍스트 변환 언어",
            .settingsTranscriptionLanguageNote: "새 녹음부터 적용됩니다",
            .settingsAppLanguage: "앱 언어",
            .settingsAppLanguageNote: "즉시 적용됩니다",
            .settingsStorageFolder: "저장 폴더",
            .settingsChangeFolder: "폴더 변경",
            .settingsClose: "닫기",
            .settingsInputDevice: "입력 장치 (마이크)",
            .settingsOutputDevice: "출력 장치 (재생)",
            .deviceSystemDefault: "시스템 기본값",
            .sessionNamePlaceholder: "세션 이름",
            .sessionPlay: "재생",
            .sessionStop: "정지",
            .gainMe: "나",
            .gainRemote: "상대",
            .transcribeButton: "텍스트로 변환",
            .retranscribeButton: "다시 변환",
            .transcribeEmptyHint: "한국어 · 일본어 · 영어는 자동으로 감지해요.",
            .transcribeRunning: "텍스트로 변환하는 중",
            .transcribeQueued: "대기 중 — 앞의 변환이 끝나면 시작해요",
            .transcribeLanguageSection: "녹음 언어",
            .transcribeHelp: "클릭하면 변환, ▾에서 다른 언어로 변환",
            .transcribeNoSpeechTitle: "말소리를 찾지 못했어요",
            .transcribeNoSpeechHint: "지금 설정된 녹음 언어: %@. 실제 녹음이 다른 언어였다면 아래에서 바꾼 뒤 다시 변환해 보세요.",
            .importHelp: "m4a · mp3 · wav 파일을 불러와 텍스트로 변환",
            .exportHelp: "MP3 · MD 파일로 내보내기",
            .detailNoSelectionHint: "왼쪽에서 녹음을 고르거나, 오디오 파일을 불러오세요.",
            .notTranscribedYet: "아직 텍스트가 없어요",
            .startRecordingWithName: "녹음 시작 — %@",
            .pickAnotherApp: "다른 앱 선택",
            .startRecording: "녹음 시작",
            .recordTargetLabel: "녹음할 앱",
            .recordTargetNone: "없음",
            .recordTargetChoose: "선택",
            .noSoundApps: "녹음할 앱(Zoom, Chrome 등)에서 소리를 먼저 재생하면 여기에 나타나요.",
            .recordingTitle: "녹음 중 — %@",
            .recordingStop: "종료",
            .menuOpenSessions: "세션 목록 열기",
            .menuQuit: "종료",
            .menuNoSoundApps: "지금 소리 내는 앱 없음",
            .langJa: "일본어", .langKo: "한국어", .langEn: "영어",
            .langAuto: "자동 감지 (한·일·영)",
            .progressDetectingLanguage: "언어 감지 중",
            .errorRecovered: "이전 실행이 비정상 종료됨 — %d개 녹음 복구됨",
            .errorLastTargetNotRunning: "마지막으로 녹음한 앱(%@)이 지금 실행 중이 아님 — 다른 앱 선택 필요",
            .errorPermissionsIncomplete: "권한 설정을 먼저 끝내야 함",
            .errorStartFailed: "녹음 시작 실패: %@",
            .errorStopFailed: "녹음 종료 중 오류: %@",
            .errorPlayFailed: "재생 실패: %@",
            .errorStorageChangeFailed: "저장 폴더 변경 실패: %@",
            .errorTranscribeFailed: "텍스트 변환 실패: %@",
            .errorMicSwitchFailed: "마이크 전환 실패: %@",
            .errorNoAudioFile: "재생할 오디오 파일 없음",
            .progressStarting: "시작",
            .progressConvertingFLAC: "저장 공간 줄이는 중 (FLAC)",
            .progressMeTrack: "내 목소리 변환 중",
            .progressRemoteTrack: "상대 목소리 변환 중",
            .progressDownloadingModel: "음성 인식 모델 내려받는 중 · %@",
            .editButton: "편집",
            .doneButton: "완료",
            .deleteButton: "삭제",
            .renameButton: "이름 변경",
            .cancelButton: "취소",
            .confirmButton: "확인",
            .deleteConfirmTitle: "%d개 세션을 삭제할까요?",
            .deleteConfirmMessage: "삭제한 녹음은 복구할 수 없습니다.",
            .importButton: "불러오기",
            .exportButton: "내보내기",
            .exportTitle: "MP3 · MD 내보내기",
            .exportPreview: "구간 듣기",
            .exportAll: "전체",
            .exportLength: "길이 %@",
            .importingFile: "불러오는 중 — %@",
            .dropHint: "놓으면 불러와서 텍스트로 변환합니다",
            .exportQuality: "음질",
            .qualityVoice: "음성 64k 모노",
            .qualityCompact: "절약 96k 모노",
            .qualityStandard: "일반 128k",
            .exportRun: "내보내기",
            .exportRangeHint: "파형을 끌어서 내보낼 구간을 고르세요",
            .formatMP3Subtitle: "음성 파일",
            .formatMDSubtitle: "분석용 텍스트",
            .formatNeedsLame: "lame 설치 필요",
            .formatNeedsTranscript: "텍스트 변환 후 사용 가능",
            .formatUtterances: "발화 %d개",
            .exportRunFormats: "%@ 내보내기",
            .lameMissing: "MP3 변환에 lame이 필요함 — 터미널에서 brew install lame",
            .errorImportFailed: "불러오기 실패: %@",
            .errorExportFailed: "내보내기 실패: %@",
        ],
        "ja": [
            .errorOperationBusy: "処理が完了してから再試行してください。",
            .errorMetadataSaveFailed: "変更を保存できませんでした: %@",
            .errorDeleteFailed: "削除できませんでした: %@",

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
            .emptyTitle: "音声ファイルがありません",
            .libraryRefresh: "フォルダを更新",
            .libraryImportForTranscription: "文字起こし用に読み込む",
            .libraryExpanded: "展開中",
            .libraryCollapsed: "折りたたみ中",
            .settingsUpdates: "アプリのアップデート",
            .updateCurrentVersion: "現在のバージョン",
            .updateCheck: "GitHubで新しいバージョンを確認",
            .updateChecking: "確認中…",
            .updateUpToDate: "最新バージョンです (%@)",
            .updateInstall: "バージョン%@をインストールして再起動",
            .updatePreparing: "ダウンロードと検証中…",
            .emptySubtitle: "下から録音を始めるか、音声ファイルをドロップしてください",
            .recoveredBadge: "復旧済み",
            .settingsTitle: "設定",
            .settingsTranscriptionLanguage: "文字起こし言語",
            .settingsTranscriptionLanguageNote: "次の録音から適用されます",
            .settingsAppLanguage: "アプリの言語",
            .settingsAppLanguageNote: "すぐに適用されます",
            .settingsStorageFolder: "保存フォルダ",
            .settingsChangeFolder: "フォルダを変更",
            .settingsClose: "閉じる",
            .settingsInputDevice: "入力デバイス（マイク）",
            .settingsOutputDevice: "出力デバイス（再生）",
            .deviceSystemDefault: "システムのデフォルト",
            .sessionNamePlaceholder: "セッション名",
            .sessionPlay: "再生",
            .sessionStop: "停止",
            .gainMe: "自分",
            .gainRemote: "相手",
            .transcribeButton: "文字起こしする",
            .retranscribeButton: "再文字起こし",
            .transcribeEmptyHint: "日本語・韓国語・英語は自動で検出します。",
            .transcribeRunning: "文字起こし中",
            .transcribeQueued: "待機中 — 前の文字起こしが終わると始まります",
            .transcribeLanguageSection: "録音の言語",
            .transcribeHelp: "クリックで文字起こし、▾で別の言語を選択",
            .transcribeNoSpeechTitle: "話し声が見つかりませんでした",
            .transcribeNoSpeechHint: "録音の言語が%@に設定されています。別の言語なら切り替えてもう一度お試しください。",
            .importHelp: "m4a · mp3 · wav を読み込んで文字起こし",
            .exportHelp: "MP3 · MD ファイルに書き出す",
            .detailNoSelectionHint: "左から録音を選ぶか、音声ファイルを読み込んでください。",
            .notTranscribedYet: "まだ文字起こしされていません",
            .startRecordingWithName: "録音開始 — %@",
            .pickAnotherApp: "他のアプリを選択",
            .startRecording: "録音開始",
            .recordTargetLabel: "録音するアプリ",
            .recordTargetNone: "なし",
            .recordTargetChoose: "選択",
            .noSoundApps: "録音したいアプリ（Zoom、Chromeなど）で音を再生すると、ここに表示されます。",
            .recordingTitle: "録音中 — %@",
            .recordingStop: "終了",
            .menuOpenSessions: "セッション一覧を開く",
            .menuQuit: "終了",
            .menuNoSoundApps: "音を出しているアプリがありません",
            .langJa: "日本語", .langKo: "韓国語", .langEn: "英語",
            .langAuto: "自動検出（日・韓・英）",
            .progressDetectingLanguage: "言語を検出中",
            .errorRecovered: "前回異常終了しました — %d件の録音を復旧しました",
            .errorLastTargetNotRunning: "最後に録音したアプリ（%@）が実行されていません — 他のアプリを選択してください",
            .errorPermissionsIncomplete: "先に権限設定を完了してください",
            .errorStartFailed: "録音開始に失敗: %@",
            .errorStopFailed: "録音終了時にエラー: %@",
            .errorPlayFailed: "再生に失敗: %@",
            .errorStorageChangeFailed: "保存フォルダの変更に失敗: %@",
            .errorTranscribeFailed: "文字起こしに失敗: %@",
            .errorMicSwitchFailed: "マイクの切り替えに失敗: %@",
            .errorNoAudioFile: "再生できる音声ファイルがありません",
            .progressStarting: "開始",
            .progressConvertingFLAC: "FLAC変換中",
            .progressMeTrack: "自分の音声を文字起こし中",
            .progressRemoteTrack: "相手の音声を文字起こし中",
            .progressDownloadingModel: "音声認識モデルをダウンロード中 · %@",
            .editButton: "編集",
            .doneButton: "完了",
            .deleteButton: "削除",
            .renameButton: "名前を変更",
            .cancelButton: "キャンセル",
            .confirmButton: "確認",
            .deleteConfirmTitle: "%d件のセッションを削除しますか？",
            .deleteConfirmMessage: "削除した録音は復元できません。",
            .importButton: "読み込む",
            .exportButton: "書き出す",
            .exportTitle: "MP3 · MD 書き出し",
            .exportPreview: "区間を再生",
            .exportAll: "全体",
            .exportLength: "長さ %@",
            .importingFile: "読み込み中 — %@",
            .dropHint: "ドロップで読み込み・文字起こし",
            .exportQuality: "音質",
            .qualityVoice: "音声 64k モノラル",
            .qualityCompact: "節約 96k モノラル",
            .qualityStandard: "標準 128k",
            .exportRun: "書き出す",
            .exportRangeHint: "波形をドラッグして書き出す区間を選択",
            .formatMP3Subtitle: "音声ファイル",
            .formatMDSubtitle: "分析用テキスト",
            .formatNeedsLame: "lameのインストールが必要",
            .formatNeedsTranscript: "文字起こし後に利用可能",
            .formatUtterances: "発話 %d件",
            .exportRunFormats: "%@ を書き出す",
            .lameMissing: "MP3変換にはlameが必要 — ターミナルで brew install lame",
            .errorImportFailed: "読み込み失敗: %@",
            .errorExportFailed: "書き出し失敗: %@",
        ],
        "en": [
            .errorOperationBusy: "Wait for the active operation to finish, then try again.",
            .errorMetadataSaveFailed: "Could not save changes: %@",
            .errorDeleteFailed: "Could not delete: %@",

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
            .emptyTitle: "No audio files yet",
            .libraryRefresh: "Refresh Folder",
            .libraryImportForTranscription: "Import for Transcription",
            .libraryExpanded: "Expanded",
            .libraryCollapsed: "Collapsed",
            .settingsUpdates: "App Updates",
            .updateCurrentVersion: "Current Version",
            .updateCheck: "Check GitHub for Updates",
            .updateChecking: "Checking for updates…",
            .updateUpToDate: "Up to date (%@)",
            .updateInstall: "Install Version %@ and Relaunch",
            .updatePreparing: "Downloading and verifying…",
            .emptySubtitle: "Start a recording below, or drop an audio file here",
            .recoveredBadge: "Recovered",
            .settingsTitle: "Settings",
            .settingsTranscriptionLanguage: "Transcription Language",
            .settingsTranscriptionLanguageNote: "Applies to new recordings",
            .settingsAppLanguage: "App Language",
            .settingsAppLanguageNote: "Applies immediately",
            .settingsStorageFolder: "Storage Folder",
            .settingsChangeFolder: "Change Folder",
            .settingsClose: "Close",
            .settingsInputDevice: "Input Device (Microphone)",
            .settingsOutputDevice: "Output Device (Playback)",
            .deviceSystemDefault: "System Default",
            .sessionNamePlaceholder: "Session Name",
            .sessionPlay: "Play",
            .sessionStop: "Stop",
            .gainMe: "Me",
            .gainRemote: "Remote",
            .transcribeButton: "Transcribe",
            .retranscribeButton: "Re-transcribe",
            .transcribeEmptyHint: "Japanese, Korean and English are detected automatically.",
            .transcribeRunning: "Transcribing",
            .transcribeQueued: "Queued — starts after the current transcription",
            .transcribeLanguageSection: "Recording language",
            .transcribeHelp: "Click to transcribe, or pick another language from ▾",
            .transcribeNoSpeechTitle: "No speech found",
            .transcribeNoSpeechHint: "The recording language is set to %@. If it was another language, switch and try again.",
            .importHelp: "Import m4a · mp3 · wav and transcribe",
            .exportHelp: "Export as MP3 · MD",
            .detailNoSelectionHint: "Pick a recording on the left, or import an audio file.",
            .notTranscribedYet: "Not transcribed yet",
            .startRecordingWithName: "Start Recording — %@",
            .pickAnotherApp: "Choose Another App",
            .startRecording: "Start Recording",
            .recordTargetLabel: "App to record",
            .recordTargetNone: "None",
            .recordTargetChoose: "Choose",
            .noSoundApps: "Play sound in the app you want to record (Zoom, Chrome…) and it shows up here.",
            .recordingTitle: "Recording — %@",
            .recordingStop: "Stop",
            .menuOpenSessions: "Open Session List",
            .menuQuit: "Quit",
            .menuNoSoundApps: "No app is making sound right now",
            .langJa: "Japanese", .langKo: "Korean", .langEn: "English",
            .langAuto: "Auto-detect (JA · KO · EN)",
            .progressDetectingLanguage: "Detecting language",
            .errorRecovered: "Previous run ended unexpectedly — recovered %d recording(s)",
            .errorLastTargetNotRunning: "The last recorded app (%@) isn't running — choose another app",
            .errorPermissionsIncomplete: "Finish setting up permissions first",
            .errorStartFailed: "Failed to start recording: %@",
            .errorStopFailed: "Error while stopping recording: %@",
            .errorPlayFailed: "Playback failed: %@",
            .errorStorageChangeFailed: "Failed to change storage folder: %@",
            .errorTranscribeFailed: "Transcription failed: %@",
            .errorMicSwitchFailed: "Failed to switch microphone: %@",
            .errorNoAudioFile: "No audio file to play",
            .progressStarting: "Starting",
            .progressConvertingFLAC: "Converting to FLAC",
            .progressMeTrack: "Transcribing your track",
            .progressRemoteTrack: "Transcribing the other side",
            .progressDownloadingModel: "Downloading speech model · %@",
            .editButton: "Edit",
            .doneButton: "Done",
            .deleteButton: "Delete",
            .renameButton: "Rename",
            .cancelButton: "Cancel",
            .confirmButton: "OK",
            .deleteConfirmTitle: "Delete %d session(s)?",
            .deleteConfirmMessage: "Deleted recordings cannot be recovered.",
            .importButton: "Import",
            .exportButton: "Export",
            .exportTitle: "Export MP3 · MD",
            .exportPreview: "Preview range",
            .exportAll: "All",
            .exportLength: "Length %@",
            .importingFile: "Importing — %@",
            .dropHint: "Drop to import and transcribe",
            .exportQuality: "Quality",
            .qualityVoice: "Voice 64k mono",
            .qualityCompact: "Compact 96k mono",
            .qualityStandard: "Standard 128k",
            .exportRun: "Export",
            .exportRangeHint: "Drag on the waveform to pick the range to export",
            .formatMP3Subtitle: "Audio file",
            .formatMDSubtitle: "Text for analysis",
            .formatNeedsLame: "Needs lame installed",
            .formatNeedsTranscript: "Available after transcription",
            .formatUtterances: "%d utterances",
            .exportRunFormats: "Export %@",
            .lameMissing: "MP3 export needs lame — run brew install lame in Terminal",
            .errorImportFailed: "Import failed: %@",
            .errorExportFailed: "Export failed: %@",
        ],
    ]
}
