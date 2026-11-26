import MeetspikeHRCore
import SwiftUI
import UIKit
import UserNotifications

@main
@MainActor
struct MeetspikeHRApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootTabView(model: appDelegate.model, env: appDelegate.environment)
                // The app is dark only. Info.plist (UIUserInterfaceStyle) covers alerts, the keyboard and the launch screen.
                .preferredColorScheme(.dark)
                .onChange(of: phase, initial: true) {
                    if phase == .active {
                        Crumbs.shared.record(.active)
                        appDelegate.model.becameActive()
                        DiagnosticsService.shared.becameActive()
                    }
                    if phase == .background {
                        Crumbs.shared.record(.background)
                        appDelegate.model.enteredBackground()
                    }
                }
                // meetspike://pair?origin=...&code=... from the setup page's QR code (Camera app or Safari).
                .onOpenURL { url in
                    guard let link = PairingLink(url) else { return }
                    PairingPresenter.present(link, model: appDelegate.model)
                }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    let model = PhoneModel()
    /// Shared state for the tab screens (API, selected day and span, connection banner).
    private(set) lazy var environment = AppEnvironment(model: model)

    func application(
        _ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // First: take the last session's crumbs before this launch writes any, then listen for MetricKit reports.
        let build = Int((Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "") ?? 0
        Crumbs.shared.start(build: build, demo: model.isDemo)
        DiagnosticsService.shared.start(demo: model.isDemo)
        UNUserNotificationCenter.current().delegate = self
        // The Live Activity buttons run in this process, even when the app was not running: they land here.
        LiveAdjustRouter.shared.register { [weak self] kind in
            guard let self else { return }
            await self.environment.choices.liveAdjust(self.model.liveAdjustTarget(), kind)
        }
        if launchOptions?[.bluetoothCentrals] != nil { model.restoreBluetooth() }
        return true
    }

    /// iOS handed over the push token. The Worker uses it to send the broadcast reminders.
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        model.pushTokenArrived(deviceToken)
    }

    /// No token this time. The saved one stays, and the phone keeps its own reminders until the Worker says it pushes.
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        model.pushRegistrationFailed()
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
