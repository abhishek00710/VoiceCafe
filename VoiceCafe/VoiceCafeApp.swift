import SwiftUI

@main
struct VoiceCafeApp: App {
    @StateObject private var model = DictationViewModel()
    var body: some Scene {
        WindowGroup {
            ContentView(model: model).frame(minWidth: 980, minHeight: 680)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandMenu("Dictation") {
                Button(model.isRecording ? "Stop Recording" : "Start Recording") { model.toggleRecording() }
                    .keyboardShortcut("r", modifiers: [.command, .shift]).disabled(model.isTranscribing)
                Button("Copy cleaned text") { model.copyText() }
                    .keyboardShortcut("c", modifiers: [.command, .option])
                    .disabled(model.activeSession?.cleanedText.isEmpty ?? true)
            }
        }
    }
}
