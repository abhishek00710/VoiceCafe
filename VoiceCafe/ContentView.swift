import SwiftUI

struct ContentView: View {
    @ObservedObject var model: DictationViewModel
    @State private var showingRaw = false
    @State private var searchText = ""
    @State private var sessionPendingDelete: DictationSession?
    @FocusState private var transcriptFocused: Bool

    private var filteredSessions: [DictationSession] {
        guard !searchText.isEmpty else { return model.sessions }
        return model.sessions.filter { $0.title.localizedCaseInsensitiveContains(searchText) || $0.cleanedText.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(Color.black.opacity(0.07)).frame(width: 1)
            workspace
            Rectangle().fill(Color.black.opacity(0.07)).frame(width: 1)
            inspector.frame(width: 260)
        }
        .background(Color.canvas)
        .preferredColorScheme(.light)
        .onAppear { if model.activeSession != nil { model.select(model.activeSession!) } }
        .onChange(of: model.activeSessionID) { _, _ in showingRaw = false }
        .alert("Voice Café", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.dismissError() } })) {
            Button("OK") { model.dismissError() }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .confirmationDialog("Delete this dictation?", isPresented: Binding(
            get: { sessionPendingDelete != nil },
            set: { if !$0 { sessionPendingDelete = nil } }
        ), titleVisibility: .visible) {
            Button("Delete Dictation", role: .destructive) {
                if let sessionPendingDelete { model.deleteSession(sessionPendingDelete) }
                sessionPendingDelete = nil
            }
            Button("Cancel", role: .cancel) { sessionPendingDelete = nil }
        } message: {
            Text("This removes the transcript and its audio file from this Mac. This action can’t be undone.")
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12).fill(Color.ink).frame(width: 38, height: 38)
                    Image(systemName: "waveform").font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("voice café").font(.system(size: 16, weight: .bold, design: .rounded)).foregroundStyle(Color.ink)
                    Text("LOCAL DICTATION").font(.system(size: 9, weight: .bold, design: .rounded)).tracking(1.1).foregroundStyle(Color.muted)
                }
                Spacer()
            }
            Button { model.startNewRecording() } label: {
                Label("New dictation", systemImage: "plus")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 42)
                    .foregroundStyle(.white)
                    .background(Color.accent, in: RoundedRectangle(cornerRadius: 12))
            }.buttonStyle(.plain).keyboardShortcut("n", modifiers: .command)

            HStack {
                Text("LIBRARY").font(.system(size: 10, weight: .bold, design: .rounded)).tracking(1).foregroundStyle(Color.muted)
                Spacer()
                Text("\(model.sessions.count)").font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.muted)
            }.padding(.top, 4)
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Color.muted)
                TextField("Find a dictation", text: $searchText).textFieldStyle(.plain).font(.system(size: 12))
            }
            .padding(.horizontal, 10).frame(height: 34)
            .background(Color.white.opacity(0.8), in: RoundedRectangle(cornerRadius: 9))

            ScrollView {
                VStack(spacing: 5) {
                    ForEach(filteredSessions) { session in
                        Button { model.select(session) } label: { SessionRow(session: session, selected: model.activeSessionID == session.id) }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button(role: .destructive) { sessionPendingDelete = session } label: {
                                    Label("Delete Dictation…", systemImage: "trash")
                                }
                                .disabled(model.isRecording || model.isTranscribing)
                            }
                    }
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 7) {
                Image(systemName: "lock.shield.fill").foregroundStyle(Color.greenInk)
                Text("Private by design").foregroundStyle(Color.ink)
            }.font(.system(size: 11, weight: .medium))
            Text("Audio and transcripts stay on this Mac.").font(.system(size: 10)).foregroundStyle(Color.muted)
        }
        .padding(.horizontal, 16).padding(.top, 24).padding(.bottom, 17)
        .frame(width: 238)
        .background(Color.side)
    }

    private var workspace: some View {
        VStack(spacing: 0) {
            topBar
            if let session = model.activeSession {
                transcriptWorkspace(session)
            } else {
                welcome
            }
            recorderBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var topBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.activeSession?.title ?? "Your words, in your flow")
                    .font(.system(size: 19, weight: .semibold, design: .rounded)).foregroundStyle(Color.ink).lineLimit(1)
                Text(model.activeSession.map { $0.createdAt.formatted(date: .abbreviated, time: .shortened) } ?? "A quiet, local space for your thoughts")
                    .font(.system(size: 11)).foregroundStyle(Color.muted)
            }
            Spacer()
            StatusBadge(status: model.status)
            if let session = model.activeSession {
                Button { sessionPendingDelete = session } label: {
                    Image(systemName: "trash").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.accent)
                        .frame(width: 30, height: 30).background(Color.white, in: Circle())
                }
                .buttonStyle(.plain)
                .help("Delete this dictation")
                .disabled(model.isRecording || model.isTranscribing)
            }
            Button { model.endSession() } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.muted)
                    .frame(width: 30, height: 30).background(Color.white, in: Circle())
            }.buttonStyle(.plain).help("End current session")
        }
        .padding(.horizontal, 26).padding(.vertical, 18)
        .background(Color.canvas)
    }

    private func transcriptWorkspace(_ session: DictationSession) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                HStack(spacing: 4) {
                    tabButton("Polished", selected: !showingRaw) { showingRaw = false }
                    tabButton("Raw", selected: showingRaw) { showingRaw = true }
                }
                Spacer()
                if !showingRaw {
                    ShareLink(
                        item: session.cleanedText,
                        subject: Text(session.title),
                        preview: SharePreview(session.title, image: Image(systemName: "waveform"))
                    ) {
                        Label("Share", systemImage: "square.and.arrow.up").font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.ink).padding(.horizontal, 11).padding(.vertical, 7)
                            .background(Color.white, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(session.cleanedText.isEmpty)
                    .help("Share this transcript with compatible apps")
                    .contextMenu {
                        Button { model.copyText() } label: {
                            Label("Copy Transcript", systemImage: "doc.on.doc")
                        }
                        .disabled(session.cleanedText.isEmpty)
                    }
                }
            }.padding(.horizontal, 26).padding(.top, 16).padding(.bottom, 12)
            Rectangle().fill(Color.black.opacity(0.06)).frame(height: 1)
            if showingRaw {
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(session.rawText.isEmpty ? "Your live transcription will appear here…" : session.rawText)
                            .font(.system(size: 17, weight: .regular, design: .rounded)).lineSpacing(8)
                            .foregroundStyle(session.rawText.isEmpty ? Color.muted : Color.ink)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(28).id("bottom")
                    }
                    .onChange(of: session.rawText) { _, _ in withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) } }
                }
            } else if session.cleanedText.isEmpty && model.isRecording {
                VStack(alignment: .leading, spacing: 12) {
                    Text(session.rawText.isEmpty ? "Listening for your words…" : session.rawText)
                        .font(.system(size: 19, weight: .regular, design: .rounded)).lineSpacing(8).foregroundStyle(Color.ink)
                    Text("Live words · On-device model").font(.system(size: 11, weight: .medium)).foregroundStyle(Color.muted)
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(30)
            } else if session.cleanedText.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "text.alignleft").font(.system(size: 24)).foregroundStyle(Color.accent.opacity(0.8))
                    Text("Your polished transcript will appear here").font(.system(size: 13, weight: .medium)).foregroundStyle(Color.muted)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TextEditor(text: Binding(get: { session.cleanedText }, set: { model.updateCleanedText($0) }))
                    .font(.system(size: 17, weight: .regular, design: .rounded))
                    .lineSpacing(8).foregroundStyle(Color.ink).scrollContentBackground(.hidden)
                    .padding(.horizontal, 21).padding(.top, 13)
                    .focused($transcriptFocused)
            }
            HStack(spacing: 6) {
                Image(systemName: "sparkles").foregroundStyle(Color.accent)
                Text(showingRaw ? "Original speech-to-text output" : "Edit freely · Changes save automatically")
                    .foregroundStyle(Color.muted)
                Spacer()
                Text("\(session.cleanedText.split(whereSeparator: \.isWhitespace).count) words")
                    .foregroundStyle(Color.muted)
            }
            .font(.system(size: 10, weight: .medium)).padding(.horizontal, 27).padding(.vertical, 11)
            .background(Color.side.opacity(0.55))
        }
        .background(Color.white.opacity(0.58), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.black.opacity(0.055), lineWidth: 1))
        .padding(.horizontal, 22).padding(.bottom, 14)
    }

    private var welcome: some View {
        VStack(spacing: 0) {
            Spacer()
            ZStack {
                Circle().fill(Color.accent.opacity(0.08)).frame(width: 146, height: 146)
                Circle().fill(Color.accent.opacity(0.12)).frame(width: 104, height: 104)
                Image(systemName: "waveform").font(.system(size: 36, weight: .medium)).foregroundStyle(Color.accent)
            }
            Text("Say it as it comes.").font(.system(size: 30, weight: .semibold, design: .rounded)).foregroundStyle(Color.ink).padding(.top, 22)
            Text("Your voice becomes clear, ready-to-use text.\nEverything is processed right here on your Mac.")
                .font(.system(size: 14)).multilineTextAlignment(.center).lineSpacing(5).foregroundStyle(Color.muted).padding(.top, 9)
            Button { model.startNewRecording() } label: {
                Label("Start your first dictation", systemImage: "mic.fill")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 19).frame(height: 44).background(Color.accent, in: Capsule())
            }.buttonStyle(.plain).padding(.top, 25)
            HStack(spacing: 18) {
                welcomeFeature("sparkles", "Cleaned up")
                welcomeFeature("text.alignleft", "Formatting commands")
                welcomeFeature("lock.fill", "Private & local")
            }.padding(.top, 28)
            Spacer()
        }.frame(maxWidth: .infinity).padding(.horizontal, 20)
    }

    private var recorderBar: some View {
        HStack(spacing: 13) {
            Button { model.toggleRecording() } label: {
                HStack(spacing: 9) {
                    Image(systemName: model.isRecording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 11, weight: .bold))
                    Text(model.isRecording ? "Finish dictation" : "Start dictating")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(.white).padding(.horizontal, 16).frame(height: 40)
                .background(model.isRecording ? Color.ink : Color.accent, in: Capsule())
            }.buttonStyle(.plain).disabled(model.isTranscribing)
            Text(model.formattedDuration).font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundStyle(Color.ink)
            if model.isRecording {
                HStack(spacing: 3) {
                    ForEach(0..<9, id: \.self) { i in
                        let response = max(0.05, CGFloat(model.microphoneLevel) * CGFloat([0.65, 1.1, 0.8, 1.35, 0.95, 1.2, 0.75, 1.05, 0.7][i]))
                        Capsule().fill(model.microphoneLevel > 0.003 ? Color.accent : Color.muted.opacity(0.35))
                            .frame(width: 3, height: min(21, max(4, 21 * response)))
                    }
                }.frame(height: 22).help(String(format: "Microphone signal: %.1f%%", model.microphoneLevel * 100))
                Text(model.microphoneLevel < 0.003 ? "No input signal" : "Mic active")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(model.microphoneLevel < 0.003 ? Color.accent : Color.greenInk)
            }
            Spacer()
            Menu {
                ForEach(model.microphoneInputs) { input in
                    Button {
                        model.selectedMicrophoneID = input.id
                        model.persistPreference()
                    } label: {
                        if model.selectedMicrophoneID == input.id { Label(input.name, systemImage: "checkmark") }
                        else { Text(input.name) }
                    }
                }
                Divider()
                Button("Refresh microphones") { model.refreshMicrophones() }
            } label: {
                HStack(spacing: 6) {
                    Circle().fill(model.microphoneInputs.isEmpty ? Color.red : Color.greenInk).frame(width: 6, height: 6)
                    Text(model.microphoneInputs.first(where: { $0.id == model.selectedMicrophoneID })?.name ?? "No microphone")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(Color.ink).lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(Color.muted)
                }.padding(.horizontal, 10).frame(height: 32).background(Color.white, in: Capsule())
            }.menuStyle(.borderlessButton)
            Menu {
                ForEach(model.speechLanguages, id: \.self) { identifier in
                    Button {
                        model.selectedLanguageID = identifier
                        model.persistPreference()
                    } label: {
                        if model.selectedLanguageID == identifier {
                            Label(Locale.current.localizedString(forIdentifier: identifier) ?? identifier, systemImage: "checkmark")
                        } else {
                            Text(Locale.current.localizedString(forIdentifier: identifier) ?? identifier)
                        }
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "character.bubble").font(.system(size: 10))
                    Text(Locale.current.localizedString(forIdentifier: model.selectedLanguageID) ?? model.selectedLanguageID)
                        .font(.system(size: 10, weight: .medium)).lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                }.foregroundStyle(Color.ink).padding(.horizontal, 8).frame(height: 32).background(Color.white, in: Capsule())
            }.menuStyle(.borderlessButton).help("Choose the language you are speaking")
            Text("⇧⌘R").font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(Color.muted)
        }
        .padding(.horizontal, 25).padding(.vertical, 14)
        .background(Color.side.opacity(0.72))
        .overlay(alignment: .top) { Rectangle().fill(Color.black.opacity(0.06)).frame(height: 1) }
    }

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { Text("SESSION DETAILS").font(.system(size: 10, weight: .bold, design: .rounded)).tracking(1).foregroundStyle(Color.muted); Spacer() }
                .padding(.top, 24).padding(.bottom, 18)
            if let session = model.activeSession {
                VStack(alignment: .leading, spacing: 15) {
                    detailLabel("CREATED", value: session.createdAt.formatted(date: .long, time: .shortened), icon: "calendar")
                    detailLabel("DURATION", value: durationLabel(session.duration > 0 ? session.duration : model.elapsedSeconds), icon: "clock")
                    detailLabel("WORDS", value: "\(session.cleanedText.split(whereSeparator: \.isWhitespace).count)", icon: "text.alignleft")
                    if session.audioFileName != nil {
                        Button { model.playAudio() } label: {
                            HStack(spacing: 9) {
                                Image(systemName: "waveform.circle.fill").font(.system(size: 21)).foregroundStyle(Color.accent)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(model.audioFileName(for: session))
                                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.ink).lineLimit(1)
                                    Text("Open local audio file").font(.system(size: 9)).foregroundStyle(Color.muted)
                                }
                                Spacer()
                                Image(systemName: "arrow.up.right").font(.system(size: 9)).foregroundStyle(Color.muted)
                            }.padding(10).background(Color.white, in: RoundedRectangle(cornerRadius: 10))
                        }.buttonStyle(.plain)
                    }
                    Divider().overlay(Color.black.opacity(0.07)).padding(.vertical, 1)
                    Text("PROCESSING").font(.system(size: 10, weight: .bold, design: .rounded)).tracking(1).foregroundStyle(Color.muted)
                    if session.steps.isEmpty {
                        Text("Steps appear as your dictation is processed.").font(.system(size: 10)).foregroundStyle(Color.muted)
                    }
                    ForEach(session.steps) { step in
                        HStack(alignment: .top, spacing: 9) {
                            Image(systemName: step.success ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                                .font(.system(size: 13)).foregroundStyle(step.success ? Color.greenInk : Color.accent)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(step.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.ink)
                                Text(step.detail).font(.system(size: 10)).lineSpacing(2).foregroundStyle(Color.muted).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    if !session.summary.isEmpty {
                        Divider().overlay(Color.black.opacity(0.07)).padding(.vertical, 1)
                        Text("SESSION SUMMARY").font(.system(size: 10, weight: .bold, design: .rounded)).tracking(1).foregroundStyle(Color.muted)
                        Text(session.summary).font(.system(size: 11)).lineSpacing(3).foregroundStyle(Color.ink)
                    }
                }
            } else {
                Text("Record a thought and you’ll see its audio, transcript, and processing summary here.")
                    .font(.system(size: 12)).lineSpacing(4).foregroundStyle(Color.muted)
            }
            Spacer()
            HStack(spacing: 7) {
                Image(systemName: "cpu").foregroundStyle(Color.accent)
                Text("LOCAL MODEL").foregroundStyle(Color.ink)
            }.font(.system(size: 9, weight: .bold, design: .rounded)).tracking(0.7)
            Text("On-device speech recognition").font(.system(size: 10)).foregroundStyle(Color.muted).padding(.top, 3)
            Text("Audio never leaves your Mac.").font(.system(size: 10)).foregroundStyle(Color.muted).padding(.top, 2)
                .padding(.bottom, 18)
        }.padding(.horizontal, 16).background(Color.side.opacity(0.55))
    }

    private func detailLabel(_ label: String, value: String, icon: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: icon).font(.system(size: 11)).foregroundStyle(Color.muted).frame(width: 15)
            VStack(alignment: .leading, spacing: 3) {
                Text(label).font(.system(size: 9, weight: .bold, design: .rounded)).tracking(0.5).foregroundStyle(Color.muted)
                Text(value).font(.system(size: 11, weight: .medium)).foregroundStyle(Color.ink)
            }
        }
    }

    private func tabButton(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 11, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? Color.ink : Color.muted)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(selected ? Color.white : Color.clear, in: Capsule())
                .overlay(Capsule().stroke(selected ? Color.black.opacity(0.06) : .clear, lineWidth: 1))
        }.buttonStyle(.plain)
    }

    private func welcomeFeature(_ symbol: String, _ label: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).foregroundStyle(Color.accent)
            Text(label).foregroundStyle(Color.muted)
        }.font(.system(size: 10, weight: .medium))
    }

    private func durationLabel(_ duration: TimeInterval) -> String {
        let seconds = Int(duration)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

private struct SessionRow: View {
    let session: DictationSession
    let selected: Bool
    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: session.rawText.isEmpty ? "mic" : "text.quote")
                .font(.system(size: 12)).foregroundStyle(selected ? Color.accent : Color.muted).frame(width: 18)
            VStack(alignment: .leading, spacing: 4) {
                Text(session.title).font(.system(size: 11, weight: selected ? .semibold : .medium)).foregroundStyle(Color.ink).lineLimit(1)
                Text(session.updatedAt.formatted(date: .omitted, time: .shortened) + " · " + String(session.cleanedText.split(whereSeparator: \.isWhitespace).count) + " words")
                    .font(.system(size: 9)).foregroundStyle(Color.muted).lineLimit(1)
            }
            Spacer(minLength: 0)
        }.padding(.horizontal, 9).padding(.vertical, 9)
            .background(selected ? Color.accent.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: 9))
            .contentShape(RoundedRectangle(cornerRadius: 9))
    }
}

private struct StatusBadge: View {
    let status: DictationStatus
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(status.rawValue).font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.ink)
        }.padding(.horizontal, 10).padding(.vertical, 7)
            .background(Color.white, in: Capsule())
    }
    private var color: Color {
        switch status {
        case .recording: Color.accent
        case .transcribing, .processing: Color.orange
        case .completed: Color.greenInk
        case .failed: Color.red
        case .idle: Color.muted.opacity(0.6)
        }
    }
}

private extension Color {
    static let canvas = Color(red: 0.976, green: 0.965, blue: 0.941)
    static let side = Color(red: 0.951, green: 0.936, blue: 0.907)
    static let ink = Color(red: 0.16, green: 0.17, blue: 0.15)
    static let muted = Color(red: 0.49, green: 0.49, blue: 0.45)
    static let accent = Color(red: 0.82, green: 0.32, blue: 0.18)
    static let greenInk = Color(red: 0.26, green: 0.50, blue: 0.37)
}
