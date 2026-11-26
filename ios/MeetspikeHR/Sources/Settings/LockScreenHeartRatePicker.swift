import MeetspikeHRCore
import SwiftUI

/// The three-way choice for when the Lock Screen heart rate shows. Reached from Menu (This iPhone), Phone settings
/// (Meetings) and the small line on the Live tab. The choice applies at once.
struct LockScreenHeartRatePicker: View {
    @ObservedObject var model: PhoneModel

    var body: some View {
        Form {
            Section {
                Picker("Lock Screen heart rate", selection: Binding(
                    get: { model.liveActivityMode },
                    set: { model.setLiveActivityMode($0) }
                )) {
                    ForEach(LiveActivityMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } footer: {
                Text(LiveActivityMode.footer)
            }
        }
        .navigationTitle("Lock Screen heart rate")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The picker in its own sheet, for the Live tab.
struct LockScreenHeartRateSheet: View {
    @ObservedObject var model: PhoneModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            LockScreenHeartRatePicker(model: model)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
