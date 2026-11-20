import SwiftUI

/// "Who's listening?" Shown once per person. The server recognises each
/// phone by its Tailscale account, so after this one choice the right
/// profile is used automatically on every phone that person signs in to.
struct ProfileChooser: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    /// False the first time (you have to choose); true when opened from Settings.
    var canCancel = false
    @State private var name = ""
    @State private var working = false

    var body: some View {
        NavigationStack {
            Form {
                let free = (library.me?.profiles ?? []).filter { !$0.claimed && $0.id != library.me?.profile?.id }
                if !free.isEmpty {
                    Section("Use an existing profile") {
                        ForEach(free) { choice in
                            Button(choice.name) { pick(id: choice.id) }
                        }
                    }
                }
                Section {
                    TextField("Name", text: $name).submitLabel(.done).onSubmit { pick(name: name) }
                    Button("Create Profile") { pick(name: name) }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                } header: {
                    Text("Or start a new one")
                } footer: {
                    Text("Your likes, playlists, history, speed dial and podcasts are kept in your profile. You're recognised by your Tailscale account\(library.me?.user.map { " (\($0.name))" } ?? ""), so there is no password.")
                }
                if let error = library.error { Section { Notice(text: error) } }
            }
            .disabled(working)
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .navigationTitle("Who's listening?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if canCancel { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            }
        }
        .interactiveDismissDisabled(!canCancel)
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
    }

    private func pick(id: Int? = nil, name: String = "") {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard id != nil || !name.isEmpty else { return }
        working = true
        Task {
            if await library.claimProfile(id: id, name: name) { dismiss() }
            working = false
        }
    }
}
