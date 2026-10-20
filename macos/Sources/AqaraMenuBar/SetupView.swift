import AppKit
import SwiftUI

/// Aqara app-cloud regions. An account lives in exactly one of them; they all
/// share the same app id/key.
enum AqaraRegion: String, CaseIterable, Identifiable {
    case europe = "Europe"
    case usa = "United States"
    case china = "China"
    case russia = "Russia"
    case korea = "Korea / Japan"
    case australia = "Australia / SE Asia"
    case custom = "Custom…"

    var id: String { rawValue }

    var host: String? {
        switch self {
        case .europe: return "https://rpc-ger.aqara.com"
        case .usa: return "https://aiot-rpc-usa.aqara.com"
        case .china: return "https://aiot-rpc.aqara.cn"
        case .russia: return "https://rpc-ru.aqara.com"
        case .korea: return "https://rpc-kr.aqara.com"
        case .australia: return "https://rpc-au.aqara.com"
        case .custom: return nil
        }
    }
}

/// First-run sign-in: verifies the credentials against Aqara's cloud before
/// saving anything, then stores the password in the Keychain and the rest in
/// ~/.config/aqara-doorbell/config.json.
struct SetupView: View {
    let onDone: (AppConfig) -> Void

    @State private var region: AqaraRegion = .europe
    @State private var customURL = "https://"
    @State private var email = ""
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Sign in to Aqara").font(.title3.bold())
                    Text("Use the account your doorbell is paired with in Aqara Home.")
                        .font(.caption).foregroundColor(.secondary)
                }
            }

            Form {
                Picker("Region", selection: $region) {
                    ForEach(AqaraRegion.allCases) { Text($0.rawValue).tag($0) }
                }
                if region == .custom {
                    TextField("Server", text: $customURL)
                }
                TextField("Email", text: $email)
                    .textContentType(.username)
                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .onSubmit { Task { await signIn() } }
            }

            if let error {
                Text(error).font(.caption).foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("Your password is stored in the login Keychain, not in a file.")
                .font(.caption2).foregroundColor(.secondary)

            HStack {
                Button("Quit") { NSApp.terminate(nil) }
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("Sign in") { Task { await signIn() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || email.isEmpty || password.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    private func signIn() async {
        guard !busy, !email.isEmpty, !password.isEmpty else { return }
        busy = true
        error = nil
        defer { busy = false }

        let base = (region.host ?? customURL).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: base), url.scheme == "https", url.host != nil else {
            error = "Enter a valid https:// server URL."
            return
        }
        let user = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let cloud = AqaraCloud(config: .init(
            baseURL: base, appId: AqaraCloud.defaultAppId, appKey: AqaraCloud.defaultAppKey,
            phoneId: "aqara-menubar-\(ProcessInfo.processInfo.hostName)"))
        do {
            try await cloud.login(email: user, password: password)
        } catch {
            self.error = "Sign-in failed. Check the email, password and region. (\(error))"
            return
        }
        do {
            try Keychain.setPassword(password, account: user)
            let cfg = AppConfig(baseURL: base, user: user)
            try cfg.save()
            onDone(cfg)
        } catch {
            self.error = "Signed in, but saving failed: \(error.localizedDescription)"
        }
    }
}
