import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The Apps pane's view of the profile store.
@MainActor
final class AppProfilesModel: ObservableObject {
    @Published private(set) var profiles: [AppProfile]

    private let store: AppProfileStore

    init(store: AppProfileStore) {
        self.store = store
        profiles = store.all
        store.onChange = { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        let fresh = store.all
        if fresh != profiles { profiles = fresh }
    }

    func upsert(_ profile: AppProfile) { store.upsert(profile) }
    func remove(_ profile: AppProfile) { store.remove(bundleID: profile.bundleID) }
}

/// The per-app cleanup rule as a picker: default (follow the toggle), on, off.
let cleanupRuleChoices: [(tag: Int, label: String)] = [(0, "Default"), (1, "On"), (2, "Off")]

func cleanupRuleTag(_ cleanup: Bool?) -> Int {
    switch cleanup {
    case nil: return 0
    case true?: return 1
    case false?: return 2
    }
}

func cleanupRule(fromTag tag: Int) -> Bool? {
    switch tag {
    case 1: return true
    case 2: return false
    default: return nil
    }
}

/// A profile for an application bundle the user picked; nil when the bundle has no id.
func appProfile(forBundleAt url: URL) -> AppProfile? {
    guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return nil }
    let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
        ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
        ?? url.deletingPathExtension().lastPathComponent
    return AppProfile(bundleID: id, appName: name)
}

struct AppsPane: View {
    @ObservedObject var model: AppProfilesModel

    var body: some View {
        Form {
            Text("Rules for the app you dictate into. Deterministic — the cleanup model never sees them.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if model.profiles.isEmpty {
                Text("No app rules yet.").foregroundStyle(.secondary)
            }
            ForEach(model.profiles) { profile in
                profileSection(profile)
            }
            HStack {
                Spacer()
                Button("Add App…", action: addApp)
            }
        }
        .padding(16)
        .onAppear { model.refresh() }
    }

    @ViewBuilder
    private func profileSection(_ profile: AppProfile) -> some View {
        Section {
            Picker(
                "Cleanup",
                selection: Binding(
                    get: { cleanupRuleTag(profile.cleanup) },
                    set: { tag in
                        var changed = profile
                        changed.cleanup = cleanupRule(fromTag: tag)
                        model.upsert(changed)
                    })
            ) {
                ForEach(cleanupRuleChoices, id: \.tag) { choice in
                    Text(choice.label).tag(choice.tag)
                }
            }
            Toggle(
                "Drop the trailing period",
                isOn: Binding(
                    get: { profile.stripTrailingPeriod },
                    set: { on in
                        var changed = profile
                        changed.stripTrailingPeriod = on
                        model.upsert(changed)
                    }))
            Toggle(
                "Lowercase the first letter",
                isOn: Binding(
                    get: { profile.lowercaseFirst },
                    set: { on in
                        var changed = profile
                        changed.lowercaseFirst = on
                        model.upsert(changed)
                    }))
        } header: {
            HStack {
                Text(profile.appName)
                Text(profile.bundleID).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    model.remove(profile)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Remove the rules for \(profile.appName)")
                .accessibilityLabel("Remove rules for \(profile.appName)")
            }
        }
    }

    /// Settings is frontmost while open, so "the current app" would be scribe itself; the user picks the app.
    private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose the app these rules apply to"
        guard panel.runModal() == .OK, let url = panel.url, let profile = appProfile(forBundleAt: url) else { return }
        model.upsert(profile)
    }
}
