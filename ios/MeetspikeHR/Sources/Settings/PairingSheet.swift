import AVFoundation
import MeetspikeHRCore
import SwiftUI
import UIKit
import VisionKit

/// Pair this iPhone from the setup page's QR code: scan (or open the link),
/// confirm the server, trade the one-time code for the keys, then test them.
@MainActor
struct PairingSheet: View {
    enum Start: Equatable {
        case scan
        case link(PairingLink)
    }

    enum Step: Equatable {
        case checkingCamera
        case scanning
        case scannerUnavailable(cameraDenied: Bool)
        case confirm(PairingLink)
        case working(PairingLink)
        case done(PairingLink, ConnectionCheck)
        case failed(String)
    }

    @ObservedObject var model: PhoneModel
    let start: Start
    var onClose: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var step: Step
    @State private var notACode = false

    init(model: PhoneModel, start: Start, initialStep: Step? = nil, onClose: (() -> Void)? = nil) {
        self.model = model
        self.start = start
        self.onClose = onClose
        switch start {
        case .scan: _step = State(initialValue: initialStep ?? .checkingCamera)
        case .link(let link): _step = State(initialValue: initialStep ?? .confirm(link))
        }
    }

    var body: some View {
        NavigationStack {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.background.ignoresSafeArea())
                .navigationTitle("Connect iPhone")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        // Hidden while the code is being traded: closing would not stop the request.
                        if !isFinished && !isWorking { Button("Cancel", action: close) }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        if isFinished { Button("Done", action: close) }
                    }
                }
        }
        .tint(Theme.accent)
        .task { await prepareScanner() }
    }

    private var isFinished: Bool {
        if case .done = step { return true }
        return false
    }

    private var isWorking: Bool {
        if case .working = step { return true }
        return false
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .checkingCamera:
            ProgressView()
        case .scanning:
            scanner
        case .scannerUnavailable(let denied):
            unavailable(cameraDenied: denied)
        case .confirm(let link):
            confirm(link)
        case .working(let link):
            message(symbol: nil, color: .secondary, title: "Connecting to \(link.host)...", detail: nil) { EmptyView() }
        case .done(let link, let check):
            if check.isConnected {
                message(symbol: "checkmark.circle.fill", color: Theme.good, title: "Connected",
                        detail: "Heart rate will sync to \(link.host).") { EmptyView() }
            } else {
                message(symbol: "exclamationmark.triangle.fill", color: Theme.warn, title: "Keys saved. \(check.title)",
                        detail: check.detail) { EmptyView() }
            }
        case .failed(let text):
            message(symbol: "xmark.octagon.fill", color: Theme.bad, title: "Couldn't connect", detail: text) {
                if start == .scan {
                    primaryButton("Scan again") {
                        notACode = false
                        step = .scanning
                    }
                }
            }
        }
    }

    private var scanner: some View {
        ZStack(alignment: .bottom) {
            SetupCodeScanner { payload in
                if let link = PairingLink(string: payload) {
                    step = .confirm(link)
                } else {
                    notACode = true
                }
            }
            .ignoresSafeArea(edges: .bottom)
            Text(notACode ? "That is not a Meetspike setup code." : "Point at the code on the Meetspike setup page.")
                .font(.callout.weight(.semibold))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(20)
        }
    }

    private func unavailable(cameraDenied: Bool) -> some View {
        message(
            symbol: "camera.metering.unknown", color: .secondary, title: "Can't scan here",
            detail: cameraDenied
                ? "Camera access is off for Meetspike. Turn it on in iOS Settings, or point the iPhone Camera app at the code."
                : "This iPhone can't scan codes inside the app. Point the iPhone Camera app at the code instead, or enter the details in Settings."
        ) {
            if cameraDenied {
                primaryButton("Open iOS Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
            }
        }
    }

    private func confirm(_ link: PairingLink) -> some View {
        message(symbol: "link.circle.fill", color: Theme.accent, title: "Connect to \(link.host)?",
                detail: "Meetspike will get its sync keys from this server and send your heart rate there. Only connect to your own server.") {
            primaryButton("Connect") { Task { await redeem(link) } }
        }
    }

    private func message<Actions: View>(
        symbol: String?, color: Color, title: String, detail: String?, @ViewBuilder actions: () -> Actions
    ) -> some View {
        ScrollView {
            VStack(spacing: 14) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 52))
                        .foregroundStyle(color)
                        .accessibilityHidden(true)
                } else {
                    ProgressView().controlSize(.large)
                }
                Text(title)
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
                if let detail {
                    Text(detail)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                actions()
            }
            .frame(maxWidth: .infinity)
            .padding(24)
            .padding(.top, 24)
        }
    }

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(Theme.buttonFill)
        .controlSize(.large)
        .padding(.top, 6)
    }

    private func close() {
        if let onClose { onClose() } else { dismiss() }
    }

    private func prepareScanner() async {
        guard step == .checkingCamera else { return }
        #if DEBUG
        if model.isDemo {
            step = .scannerUnavailable(cameraDenied: false)
            return
        }
        #endif
        guard DataScannerViewController.isSupported else {
            step = .scannerUnavailable(cameraDenied: false)
            return
        }
        if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .video)
        }
        step = DataScannerViewController.isAvailable ? .scanning : .scannerUnavailable(cameraDenied: true)
    }

    private func redeem(_ link: PairingLink) async {
        // A double tap on Connect must not spend the code twice: the second try
        // would fail as "already used" and hide the first one's success.
        guard step == .confirm(link) else { return }
        step = .working(link)
        do {
            let check = try await model.pair(link)
            step = .done(link, check)
        } catch let error as PairingError {
            step = .failed(error.message)
        } catch {
            step = .failed(error.localizedDescription)
        }
    }
}

/// VisionKit's live scanner, reading QR codes only.
struct SetupCodeScanner: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        context.coordinator.onCode = onCode
        if !scanner.isScanning { try? scanner.startScanning() }
    }

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        scanner.stopScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var onCode: (String) -> Void
        private var last: String?

        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            for item in addedItems { report(item) }
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didTapOn item: RecognizedItem) {
            last = nil
            report(item)
        }

        private func report(_ item: RecognizedItem) {
            guard case .barcode(let barcode) = item, let payload = barcode.payloadStringValue, payload != last else { return }
            last = payload
            onCode(payload)
        }
    }
}

/// Opens the pairing sheet over whatever is on screen, for a meetspike://pair link
/// opened from the Camera app or Safari. UIKit presentation reaches the top even
/// when Settings, Menu or onboarding is already up.
@MainActor
enum PairingPresenter {
    static func present(_ link: PairingLink, model: PhoneModel) {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        guard var top = scene?.windows.first(where: \.isKeyWindow)?.rootViewController
            ?? scene?.windows.first?.rootViewController else { return }
        while let next = top.presentedViewController, !next.isBeingDismissed { top = next }
        let host = UIHostingController(rootView: AnyView(EmptyView()))
        host.rootView = AnyView(PairingSheet(model: model, start: .link(link)) { [weak host] in
            host?.dismiss(animated: true)
        })
        host.isModalInPresentation = true
        top.present(host, animated: true)
    }
}
