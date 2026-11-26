import MeetspikeHRCore
import SwiftUI

/// Ask your data: a chat over POST /api/ask/stream. Ported from public/ask-panel.js.
struct AskScreen: View {
    @EnvironmentObject private var env: AppEnvironment
    @StateObject private var model = AskModel()
    @State private var draft = ""
    @FocusState private var composerFocused: Bool
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        NavigationStack {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.background.ignoresSafeArea())
                .tabBanners(.ask)
                .navigationTitle("Ask")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { MoreButton() }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            draft = ""
                            model.newChat()
                        } label: {
                            Label("New chat", systemImage: "square.and.pencil")
                        }
                        .disabled(model.session.turns.isEmpty && !model.isStreaming)
                    }
                }
        }
        .task {
            model.attach(env)
            await model.open()
        }
        .onChange(of: env.selectedTab) { _, tab in
            // Coming back to the tab re-reads the key and the shown source (More may have changed it) and the range.
            if tab == .ask {
                model.attach(env)
                Task { await model.open() }
            }
        }
        .onChange(of: model.unsent) { _, unsent in
            // The question could not be sent: put it back unless the person has typed something new.
            guard let unsent else { return }
            draft = AskLogic.restoredDraft(question: unsent.question, current: draft)
            model.clearUnsent()
        }
        .onChange(of: env.pendingAskKeyForm) { _, pending in
            if pending { model.consumePendingKeyForm() }
        }
    }

    // MARK: States

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            VStack(spacing: 12) {
                ProgressView()
                Text("Loading\u{2026}").font(.subheadline).foregroundStyle(.secondary)
            }
        case .statusError(let message):
            messageState(message, systemImage: "exclamationmark.triangle") {
                Button("Try again") { Task { await model.loadStatus(force: true) } }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.buttonFill)
            }
        case .unavailable:
            messageState(
                "Ask needs one setting on your Worker first: a secret named AI_KEY_SECRET (any 32 or more random characters). It encrypts your API key. Run this once, then check again:\n\nwrangler secret put AI_KEY_SECRET",
                systemImage: "key.slash"
            ) {
                Button("Check again") { Task { await model.loadStatus(force: true) } }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.buttonFill)
            }
        case .keyForm:
            ScrollView { AskKeyForm(model: model) }
                .scrollDismissesKeyboard(.interactively)
        case .chat:
            chat
        }
    }

    private func messageState<Actions: View>(_ text: String, systemImage: String, @ViewBuilder actions: () -> Actions) -> some View {
        VStack(spacing: 14) {
            Image(systemName: systemImage).font(.largeTitle).foregroundStyle(.secondary).accessibilityHidden(true)
            Text(text).multilineTextAlignment(.center)
            actions()
        }
        .padding(24)
    }

    // MARK: Chat

    private var chat: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    header
                    if model.session.turns.isEmpty {
                        AskEmptyState { question in model.ask(question) }
                    } else {
                        ForEach(model.session.turns) { turn in
                            if turn.role == .user {
                                AskUserBubble(text: turn.content)
                            } else {
                                AskAssistantTurn(
                                    turn: turn, runStart: model.runStart, retry: { model.retry($0) }, today: model.today,
                                    offersAllTime: model.offersAskOverAllTime(turn), askAllTime: { model.askOverAllTime($0) })
                            }
                        }
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(16)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: model.session.turns.count) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
            .onChange(of: model.session.turns.last?.content) { _, _ in
                if model.isStreaming { proxy.scrollTo("end", anchor: .bottom) }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { composer }
        }
    }

    /// What the next question ranks, and the All time pill. With no scope all history is already used: no pill.
    private var header: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 8))
        return layout {
            Text(model.headerText)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            if model.showsAllTimeToggle { allTimePill }
        }
    }

    private var allTimePill: some View {
        let on = model.allTime
        return Button {
            model.setAllTime(!on)
        } label: {
            Text("All time")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(on ? Color.white : Theme.accent)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(on ? Theme.buttonFill : Theme.inset, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("All time, \(on ? "on" : "off")")
        .accessibilityHint("Applies to your next question")
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private var composer: some View {
        VStack(spacing: 6) {
            if let sendError = model.sendError {
                Label(sendError, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(Theme.bad)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField(
                    model.isStreaming ? "Answering\u{2026} you can stop it" : "Ask about your meetings and recovery",
                    text: $draft, axis: .vertical
                )
                .lineLimit(1...(typeSize.isAccessibilitySize ? 3 : 4))
                .focused($composerFocused)
                .submitLabel(.send)
                .onSubmit(send)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Theme.inset, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                if model.isStreaming {
                    Button { model.stop() } label: {
                        Image(systemName: "stop.circle.fill").font(.system(size: 34))
                    }
                    .foregroundStyle(Theme.accent)
                    .accessibilityLabel("Stop answering")
                } else {
                    Button(action: send) {
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 34))
                    }
                    .foregroundStyle(canSend ? Theme.accent : Color.secondary.opacity(0.5))
                    .disabled(!canSend)
                    .accessibilityLabel("Send")
                }
            }
            Text("Sends dates, titles, names and scores. No emails or audio.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(.bar)
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !model.isStreaming
    }

    private func send() {
        guard canSend else { return }
        let text = draft
        draft = ""
        model.ask(text)
    }
}
