import SwiftUI

struct SettingsView: View {
    @AppStorage(API.serverKey) private var server = ""
    @State private var status: String?
    @Environment(Library.self) private var library
    @AppStorage(API.profileKey) private var profileID = 1
    @State private var profiles: [API.Profile] = []
    @State private var newProfile = ""
    @State private var choosing = false
    /// Which text field has the keyboard (nil = keyboard hidden).
    @FocusState private var focus: Field?
    private enum Field { case profile, server }

    var body: some View {
        Form {
            if let user = library.me?.user {
                // The server knows whose phone this is (from Tailscale), so
                // there is nothing to pick here.
                Section {
                    LabeledContent("Listening as", value: library.me?.profile?.name ?? "Not chosen")
                    Button("Use a Different Profile") { choosing = true }
                } header: {
                    Text("Profile")
                } footer: {
                    Text("Recognised by your Tailscale account (\(user.name)). Each person has their own likes, playlists, history, speed dial and podcasts.")
                }
            } else {
            Section {
                Picker("Listening as", selection: $profileID) {
                    ForEach(profiles) { Text($0.name).tag($0.id) }
                    if !profiles.contains(where: { $0.id == profileID }) { Text("Profile \(profileID)").tag(profileID) }
                }
                HStack {
                    TextField("New profile name", text: $newProfile)
                        .focused($focus, equals: .profile)
                        .submitLabel(.done)
                        .onSubmit { Task { await addProfile() } }
                    Button("Add") { Task { await addProfile() } }
                        .disabled(newProfile.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("Profile")
            } footer: {
                Text("Each profile has its own likes, playlists, history, speed dial and podcasts. There are no passwords: pick yours once on each phone.")
            }
            }
            Section {
                TextField("Server", text: $server)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focus, equals: .server)
                    .submitLabel(.done)
                Button("Test Connection") { Task { await test() } }
                if let status { Text(status).font(.caption).foregroundStyle(Theme.textSecondary) }
            } header: {
                Text("Server")
            } footer: {
                Text("Your pitunes server on Tailscale, e.g. http://music:8000. The Tailscale app must be connected.")
            }
        }
        // Hide the keyboard when you scroll or tap anywhere outside a text field.
        .scrollDismissesKeyboard(.immediately)
        // The tap is only listened for while the keyboard is up; otherwise it
        // swallows taps meant for the "Listening as" menu.
        .simultaneousGesture(TapGesture().onEnded { focus = nil },
                             including: focus == nil ? .subviews : .all)
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .navigationTitle("Settings")
        .sheet(isPresented: $choosing) { ProfileChooser(canCancel: true) }
        .task { profiles = (try? await API.profiles()) ?? [] }
        .onChange(of: profileID) { _, _ in Task { await library.refresh() } }
    }

    private func addProfile() async {
        let name = newProfile.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { focus = nil; return }
        focus = nil
        guard let created = try? await API.createProfile(name) else { status = "❌ Couldn't create that profile (name taken?)"; return }
        profiles.append(created)
        profileID = created.id
        newProfile = ""
    }

    private func test() async {
        focus = nil
        status = "Checking…"
        do {
            try await API.health()
            status = "✅ Connected"
        } catch {
            status = "❌ \(error.localizedDescription)"
        }
    }
}
