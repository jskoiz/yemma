import SwiftUI

struct PersonalPreferencesSheet: View {
    @Environment(AppPrivacyController.self) private var privacyController
    @Environment(\.dismiss) private var dismiss

    @State private var draftPreferences = ""
    @State private var didLoadPreferences = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $draftPreferences)
                        .frame(minHeight: 160)
                        .accessibilityLabel("Personal preferences")
                        .accessibilityHint("Enter up to 500 characters of guidance for subsequent responses.")

                    HStack {
                        Text("Saved locally on this iPhone")
                        Spacer()
                        Text("\(draftPreferences.count)/\(PersonalPreferences.characterLimit)")
                            .monospacedDigit()
                            .foregroundStyle(isPreferencesOverLimit ? .red : .secondary)
                            .accessibilityLabel("\(draftPreferences.count) of \(PersonalPreferences.characterLimit) characters")
                    }
                    .font(.footnote)

                    if isPreferencesOverLimit {
                        Text("Shorten your preferences before saving.")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("Subsequent responses")
                } footer: {
                    Text("These preferences are added as extra guidance to subsequent responses until you edit or clear them.")
                }

                Section("App lock") {
                    Button {
                        Task {
                            await toggleAppLock()
                        }
                    } label: {
                        HStack {
                            Label(
                                privacyController.enabled ? "Turn off app lock" : "Turn on app lock",
                                systemImage: privacyController.enabled ? "lock.open" : "lock"
                            )
                            Spacer()
                            if privacyController.isAuthenticating {
                                ProgressView()
                            } else {
                                Text(privacyController.enabled ? "On" : "Off")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .disabled(privacyController.isAuthenticating)
                    .accessibilityHint("Requires Face ID, Touch ID, or your device passcode.")

                    if let error = privacyController.error {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Text("Require Face ID, Touch ID, or your passcode when you return to Yemma. Changes to app lock take effect immediately.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Personal preferences")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        PersonalPreferences.save(draftPreferences)
                        dismiss()
                    }
                    .disabled(isPreferencesOverLimit)
                }
            }
        }
        .onAppear {
            guard !didLoadPreferences else { return }
            draftPreferences = PersonalPreferences.savedText()
            didLoadPreferences = true
        }
    }

    private var isPreferencesOverLimit: Bool {
        draftPreferences.count > PersonalPreferences.characterLimit
    }

    private func toggleAppLock() async {
        if privacyController.enabled {
            _ = await privacyController.disable()
        } else {
            _ = await privacyController.enable()
        }
    }
}

#if DEBUG
#Preview("Personal Preferences") {
    PersonalPreferencesSheet()
        .environment(AppPrivacyController(defaults: UserDefaults(suiteName: "PersonalPreferencesPreview") ?? .standard))
}
#endif
