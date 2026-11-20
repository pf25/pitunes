import SwiftUI

/// First launch: PiTunes plays from a server you run yourself, so the first
/// thing it needs is that server's address.
struct ConnectView: View {
    @Environment(Library.self) private var library
    @AppStorage(API.serverKey) private var server = ""
    @State private var address = ""
    @State private var checking = false
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Space.xl) {
                Image(systemName: "music.note.house.fill")
                    .font(.system(size: 56)).foregroundStyle(Theme.brandGradient)
                    .padding(.top, 60)
                VStack(spacing: Theme.Space.s) {
                    Text("Connect to your server").font(.title.bold())
                    Text("PiTunes plays music and podcasts from a small server you run at home, such as a Raspberry Pi. Enter its address to get started.")
                        .font(.subheadline).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center)
                }
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    TextField("", text: $address, prompt: Text(API.exampleServer).foregroundStyle(Theme.textTertiary))
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .submitLabel(.go).focused($focused)
                        .onSubmit { Task { await connect() } }
                        .padding(Theme.Space.m)
                        .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.m))
                        .accessibilityLabel("Server address")
                    if let error { Notice(text: error) }
                }
                Button { Task { await connect() } } label: {
                    if checking { ProgressView().tint(Theme.onAccent) } else { Text("Connect") }
                }
                .buttonStyle(.primary)
                .disabled(checking || address.trimmingCharacters(in: .whitespaces).isEmpty)

                VStack(spacing: Theme.Space.s) {
                    Text("Don't have a server yet?").font(.footnote).foregroundStyle(Theme.textSecondary)
                    Link("Read the setup guide at pitunes.com", destination: URL(string: "https://pitunes.com")!)
                        .font(.footnote.weight(.semibold))
                }
                .padding(.top, Theme.Space.s)
            }
            .padding(.horizontal, Theme.Space.xl)
        }
        .scrollDismissesKeyboard(.interactively)
        .screenBackground()
    }

    private func connect() async {
        guard let url = API.normalized(address) else {
            error = "That doesn't look like an address. Try something like \(API.exampleServer)."
            return
        }
        checking = true
        defer { checking = false }
        if let problem = await API.check(url) {
            error = "Couldn't connect: \(problem) Check the address, and that this phone can reach the server (for example, that your VPN or Tailscale is connected)."
            return
        }
        error = nil
        server = url.absoluteString      // switches the app to its main screens
        await library.refresh()
    }
}
