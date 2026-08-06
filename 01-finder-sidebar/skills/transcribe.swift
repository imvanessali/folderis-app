// On-device speech-to-text for one audio file via SFSpeechRecognizer.
// Must be COMPILED with an embedded Info.plist (bundle id + usage description):
//   swiftc transcribe.swift -o transcribe \
//     -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker transcribe-Info.plist
// Usage: transcribe <audio-file> [locale]
import Foundation
import Speech

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write(Data("用法：transcribe <audio> [locale]\n".utf8))
    exit(1)
}
let url = URL(fileURLWithPath: args[1])
let localeID = args.count >= 3 ? args[2] : "zh-CN"
let timeoutSeconds = args.count >= 4 ? max(30, Double(args[3]) ?? 120) : 120

func finish(_ code: Int32, _ message: String? = nil) -> Never {
    if let message {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
    exit(code)
}

var authStatus = SFSpeechRecognizer.authorizationStatus()
if authStatus == .notDetermined {
    SFSpeechRecognizer.requestAuthorization { status in
        authStatus = status
        CFRunLoopStop(CFRunLoopGetMain())
    }
    CFRunLoopRun()
}
guard authStatus == .authorized else {
    finish(2, "UNAUTHORIZED")
}

guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeID)),
      recognizer.isAvailable else {
    finish(1, "识别器不可用（locale: \(localeID)）")
}

let request = SFSpeechURLRecognitionRequest(url: url)
request.shouldReportPartialResults = true
if recognizer.supportsOnDeviceRecognition {
    request.requiresOnDeviceRecognition = true
}

var finalText = ""
var lastBest = ""
var failed: String?

recognizer.recognitionTask(with: request) { result, error in
    if let error {
        if finalText.isEmpty && !lastBest.isEmpty {
            finalText = lastBest
        } else if finalText.isEmpty {
            failed = error.localizedDescription
        }
        CFRunLoopStop(CFRunLoopGetMain())
        return
    }
    guard let result else { return }
    lastBest = result.bestTranscription.formattedString
    if result.isFinal {
        finalText = lastBest
        CFRunLoopStop(CFRunLoopGetMain())
    }
}

// Each input is already a short speech segment. Preserve the latest partial
// result if Speech does not deliver a final callback before the watchdog.
DispatchQueue.main.asyncAfter(deadline: .now() + timeoutSeconds) {
    if finalText.isEmpty && !lastBest.isEmpty {
        finalText = lastBest
    } else if finalText.isEmpty {
        failed = "转写超时"
    }
    CFRunLoopStop(CFRunLoopGetMain())
}

CFRunLoopRun()

if let failed {
    finish(1, "转写失败：\(failed)")
}
print(finalText)
