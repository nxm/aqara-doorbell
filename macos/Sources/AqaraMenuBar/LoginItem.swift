import ServiceManagement

/// "Open at login" through the macOS 13+ login-item API, so it works however
/// the app was installed (Homebrew, DMG or Nix).
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// Applies the change. Returns a message for the user when it failed or
    /// macOS wants them to approve it in System Settings, nil when it went through.
    static func set(_ on: Bool) -> String? {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            return "Couldn't change Open at login: \(error.localizedDescription)"
        }
        if SMAppService.mainApp.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
            return "Allow Aqara Doorbell in Login Items"
        }
        return nil
    }
}
