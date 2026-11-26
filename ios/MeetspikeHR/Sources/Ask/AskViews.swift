import MeetspikeHRCore
import SwiftUI

// Pieces the Ask screen is built from: the answer text, the step list, one chat turn, the empty state, the key form.

/// Mini Markdown from `AskMarkdown`: paragraphs, bullets, pipe tables, bold.
struct AskAnswerText: View {
    let text: String

    var body: some View {
        let blocks = AskMarkdown.blocks(text)
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .paragraph(let runs):
                    Text(Self.attributed(runs)).fixedSize(horizontal: false, vertical: true)
                case .bullets(let items):
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("\u{2022}").accessibilityHidden(true)
                                Text(Self.attributed(item)).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                case .table(let header, let rows):
                    AskTableView(header: header, rows: rows)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    static func attributed(_ runs: [AskInline]) -> AttributedString {
        var out = AttributedString()
        for run in runs {
            switch run {
            case .text(let s):
                out.append(AttributedString(s))
            case .bold(let s):
                var bold = AttributedString(s)
                bold.inlinePresentationIntent = .stronglyEmphasized
                out.append(bold)
            case .lineBreak:
                out.append(AttributedString("\n"))
            }
        }
        return out
    }
}

/// A pipe table in an answer. Up to 3 columns share the width and wrap (no sideways scrolling); wider tables, and any
/// accessibility text size, become one card per row with the label above the value (`AskTableLayout` decides).
struct AskTableView: View {
    let header: [[AskInline]]
    let rows: [[[AskInline]]]
    @Environment(\.dynamicTypeSize) private var typeSize

    private var columns: Int { max(header.count, rows.map(\.count).max() ?? 0) }

    var body: some View {
        Group {
            switch AskTableLayout.style(columns: columns, rows: rows.count, accessibilitySize: typeSize.isAccessibilitySize) {
            case .grid: grid
            case .stacked: stacked
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var grid: some View {
        AskColumnsLayout(columns: columns) {
            ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                Text(AskAnswerText.attributed(cell)).fontWeight(.semibold).fixedSize(horizontal: false, vertical: true)
            }
            // A short header or row still takes its columns, so the cells stay in their places.
            ForEach(0..<max(0, columns - header.count), id: \.self) { _ in Color.clear.frame(height: 1) }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                    Text(AskAnswerText.attributed(cell)).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(0..<max(0, columns - row.count), id: \.self) { _ in Color.clear.frame(height: 1) }
            }
        }
        .padding(12)
        .background(Theme.inset, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var stacked: some View {
        let cards = AskTableLayout.stacked(header: header, rows: rows)
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(cards.enumerated()), id: \.offset) { _, card in
                if !card.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(card.enumerated()), id: \.offset) { _, pair in
                            VStack(alignment: .leading, spacing: 1) {
                                if !pair.label.isEmpty {
                                    Text(AskAnswerText.attributed(pair.label))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Text(AskAnswerText.attributed(pair.value)).fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityElement(children: .combine)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.inset, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
        }
    }
}

/// Lays cells out in `columns` columns that share the width: the first gets 40% (or an equal share when that is
/// more) and the rest split what is left. Cells wrap at their column width, so nothing runs past the edge.
private struct AskColumnsLayout: Layout {
    let columns: Int
    private let spacing: CGFloat = 12
    private let rowSpacing: CGFloat = 8

    private func widths(_ total: CGFloat) -> [CGFloat] {
        guard columns > 0 else { return [] }
        let usable = max(0, total - spacing * CGFloat(columns - 1))
        if columns == 1 { return [usable] }
        let first = usable * max(0.4, 1 / CGFloat(columns))
        let rest = (usable - first) / CGFloat(columns - 1)
        return [first] + Array(repeating: rest, count: columns - 1)
    }

    private func rowHeights(_ subviews: Subviews, widths: [CGFloat]) -> [CGFloat] {
        guard columns > 0 else { return [] }
        return stride(from: 0, to: subviews.count, by: columns).map { first in
            (0..<columns).compactMap { column -> CGFloat? in
                let index = first + column
                guard index < subviews.count else { return nil }
                return subviews[index].sizeThatFits(ProposedViewSize(width: widths[column], height: nil)).height
            }.max() ?? 0
        }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let total = proposal.width ?? 280
        let heights = rowHeights(subviews, widths: widths(total))
        return CGSize(width: total, height: heights.reduce(0, +) + rowSpacing * CGFloat(max(0, heights.count - 1)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let columnWidths = widths(bounds.width)
        let heights = rowHeights(subviews, widths: columnWidths)
        var y = bounds.minY
        for (row, height) in heights.enumerated() {
            var x = bounds.minX
            for column in 0..<columns {
                let index = row * columns + column
                if index < subviews.count {
                    subviews[index].place(
                        at: CGPoint(x: x, y: y), anchor: .topLeading,
                        proposal: ProposedViewSize(width: columnWidths[column], height: nil))
                }
                x += columnWidths[column] + spacing
            }
            y += height + rowSpacing
        }
    }
}

/// The real steps the Worker reports ("Reading your calendar"), live or settled.
struct AskStepList: View {
    let steps: [AskStep]
    let live: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(steps) { step in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if step.status == .done {
                        Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(Theme.good)
                    } else {
                        Circle()
                            .fill(live ? Theme.accent : Color.secondary.opacity(0.5))
                            .frame(width: 7, height: 7)
                            .opacity(live && !reduceMotion ? 0.9 : 1)
                    }
                    Text(step.label)
                        .font(.footnote)
                        .foregroundStyle(step.status == .done ? .secondary : .primary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(step.label), \(step.status == .done ? "done" : "working")")
            }
        }
    }
}

/// One answer: the thinking ticker while it starts, the settled "Thought for Ns" row, the text, and how it ended.
struct AskAssistantTurn: View {
    let turn: AskChatTurn
    let runStart: Date?
    let retry: (AskChatTurn) -> Void
    /// The day the phone calls today, for the range line.
    var today = ""
    /// Show "Ask over all time" under this answer.
    var offersAllTime = false
    var askAllTime: (AskChatTurn) -> Void = { _ in }
    @State private var stepsOpen = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var thinking: Bool { turn.isStreaming && turn.content.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if thinking {
                thinkingRow
                if !turn.steps.isEmpty { AskStepList(steps: turn.steps, live: true) }
            } else if !turn.steps.isEmpty || turn.thought != nil {
                thoughtRow
                if stepsOpen { AskStepList(steps: turn.steps, live: false) }
            }
            if !turn.content.isEmpty { AskAnswerText(text: turn.content) }
            if let error = turn.error {
                Text(error).font(.subheadline).foregroundStyle(Theme.bad)
                    .accessibilityAddTraits(.isStaticText)
            }
            if let range = turn.range {
                Text(AskCopy.rangeLine(range, today: today.isEmpty ? range.baselineEnd : today))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if offersAllTime { allTimeButton }
            ending
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var thinkingRow: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            let ms = Int(max(0, context.date.timeIntervalSince(runStart ?? context.date)) * 1000)
            HStack(spacing: 8) {
                SparkSpinner(spinning: !reduceMotion)
                Text("\(AskCopy.verb(atMilliseconds: ms))\u{2026}").font(.subheadline.weight(.medium))
                Text("\(ms / 1000)s").font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Working on your answer")
        }
    }

    private var thoughtRow: some View {
        Button {
            stepsOpen.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "sparkle").font(.caption).foregroundStyle(Theme.accent)
                Text(AskCopy.thoughtLabel(seconds: turn.thought ?? 1, stoppedEarly: turn.stoppedEarly))
                    .font(.footnote.weight(.medium))
                if !turn.steps.isEmpty {
                    Image(systemName: stepsOpen ? "chevron.up" : "chevron.down").font(.caption2)
                }
            }
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .disabled(turn.steps.isEmpty)
        .accessibilityHint(turn.steps.isEmpty ? "" : (stepsOpen ? "Hides the steps" : "Shows the steps"))
    }

    @ViewBuilder
    private var ending: some View {
        let again = turn.question != nil
        if turn.stopped {
            HStack {
                chip(turn.stoppedEarly ? "You stopped it before it answered" : "You stopped the answer here", systemImage: "stop.fill")
                if again { retryButton }
            }
        } else if turn.interrupted && !turn.isStreaming {
            HStack {
                chip(
                    turn.content.isEmpty
                        ? "The connection dropped before it answered"
                        : "The connection dropped, so this answer is incomplete",
                    systemImage: "stop.fill")
                if again { retryButton }
            }
        } else if turn.truncated {
            Text("The answer was cut short.").font(.footnote).foregroundStyle(.secondary)
        } else if turn.refused {
            Text("Claude declined to answer that.").font(.footnote).foregroundStyle(.secondary)
        }
        if turn.error != nil && again { retryButton }
    }

    private func chip(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Theme.inset, in: Capsule())
    }

    private var allTimeButton: some View {
        Button {
            askAllTime(turn)
        } label: {
            Label("Ask over all time", systemImage: "clock.arrow.circlepath")
                .font(.footnote.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Theme.inset, in: Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.accent)
        .accessibilityHint("Asks the same question again over all your history")
    }

    private var retryButton: some View {
        Button {
            retry(turn)
        } label: {
            Label("Try again", systemImage: "arrow.clockwise")
                .font(.footnote.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Theme.inset, in: Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.accent)
    }
}

private struct SparkSpinner: View {
    let spinning: Bool
    @State private var angle = 0.0

    var body: some View {
        Image(systemName: "sparkle")
            .foregroundStyle(Theme.accent)
            .rotationEffect(.degrees(angle))
            .onAppear {
                guard spinning else { return }
                withAnimation(.linear(duration: 2).repeatForever(autoreverses: false)) { angle = 360 }
            }
            .accessibilityHidden(true)
    }
}

struct AskUserBubble: View {
    let text: String

    var body: some View {
        Text(text)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .foregroundStyle(.white)
            .background(Theme.buttonFill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.leading, 40)
            .accessibilityLabel("You asked: \(text)")
    }
}

/// Before the first question: the heading and the three suggestions.
struct AskEmptyState: View {
    let pick: (String) -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles").font(.largeTitle).foregroundStyle(Theme.accent).accessibilityHidden(true)
            Text("What do you want to know about your meetings and recovery?")
                .font(.headline)
                .multilineTextAlignment(.center)
            ForEach(AskCopy.suggestions, id: \.self) { question in
                Button {
                    pick(question)
                } label: {
                    Text(question)
                        .font(.subheadline)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 24)
    }
}

/// Add, change or replace the Claude key.
struct AskKeyForm: View {
    @ObservedObject var model: AskModel
    @State private var key = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Ask things like \"which meetings cost me the most this month\". Add your own Claude API key: you pay Anthropic directly for what you use.")
            VStack(alignment: .leading, spacing: 6) {
                Text("Claude API key").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                SecureField("sk-ant-...", text: $key)
                    // Not a password field to iOS: it must never offer to save this key in Passwords.
                    .textContentType(nil)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .focused($focused)
                    .submitLabel(.go)
                    .onSubmit(submit)
                    .padding(12)
                    .background(Theme.inset, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .disabled(model.keyBusy)
                Text("Get one at console.anthropic.com, under API keys.").font(.footnote).foregroundStyle(.secondary)
            }
            Button(action: submit) {
                HStack {
                    if model.keyBusy { ProgressView().tint(.white) }
                    Text(model.keyBusy ? "Checking\u{2026}" : "Check and save").fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .foregroundStyle(.white)
                .background(Theme.buttonFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .disabled(model.keyBusy || key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .opacity(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.5 : 1)
            if let error = model.keyError {
                Text(error).font(.subheadline).foregroundStyle(Theme.bad)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("What is shared").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                Text("Your key is stored encrypted in your own Cloudflare Worker, never on this phone.").font(.footnote)
                Text("Each question sends Anthropic the days it needs: dates, meeting titles and times, who attended, and your scores. No email addresses, transcripts or audio.")
                    .font(.footnote)
            }
            .card()
            if model.hasSavedKey {
                Button("Keep the current key") {
                    key = ""
                    model.cancelReplaceKey()
                }
                .font(.subheadline.weight(.semibold))
            }
        }
        .padding(16)
        .onChange(of: model.hasSavedKey) { _, saved in if saved { key = "" } }
    }

    private func submit() {
        let value = key
        Task {
            await model.saveKey(value)
            if model.keyError == nil { key = "" }
        }
    }
}
