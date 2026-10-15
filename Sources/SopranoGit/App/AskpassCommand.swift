import AppKit

/// git and ssh call the app binary back for credentials (`GIT_ASKPASS`,
/// `SSH_ASKPASS` with `SOPRANO_GIT_ASKPASS=1`): show a Mission Control prompt,
/// print the answer to stdout and exit 0, or exit 1 when cancelled.
@MainActor
enum AskpassCommand {
    nonisolated static let environmentKey = "SOPRANO_GIT_ASKPASS"

    /// The prompt when this launch is an askpass call: `askpass <prompt>`, or
    /// git's own `<binary> <prompt>` while `SOPRANO_GIT_ASKPASS=1`.
    nonisolated static func prompt(arguments: [String], environment: [String: String]) -> String? {
        let rest = Array(arguments.dropFirst())
        if rest.first == "askpass" {
            return rest.dropFirst().joined(separator: " ")
        }
        guard environment[environmentKey] == "1", let first = rest.first, !first.hasPrefix("-psn_") else { return nil }
        return rest.joined(separator: " ")
    }

    /// Passwords, passphrases, tokens and PINs are typed into a secure field;
    /// usernames and yes/no host-key questions into a plain one.
    nonisolated static func isSecret(_ prompt: String) -> Bool {
        let lowered = prompt.lowercased()
        if lowered.contains("username") || lowered.contains("(yes/no") { return false }
        return ["password", "passphrase", "token", "pin", "secret", "passcode", "verification code"]
            .contains { lowered.contains($0) }
    }

    /// A short title for the prompt ("SSH Key", "Git Credentials").
    nonisolated static func title(for prompt: String) -> String {
        let lowered = prompt.lowercased()
        if lowered.contains("passphrase") { return "SSH Key Passphrase" }
        if lowered.contains("(yes/no") || lowered.contains("authenticity") { return "SSH Host Verification" }
        if lowered.contains("username") { return "Git Username" }
        return "Git Credentials"
    }

    static func run(prompt: String) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        _ = RetroFont.registerBundledFont()
        let settings = SettingsCenter.shared
        settings.start(createIfMissing: false, watching: false)
        ThemeCenter.shared.apply(setting: settings.settings.theme, watch: false)

        Task { @MainActor in
            let cleaned = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            let answer = await Dialogs.prompt(
                title: title(for: cleaned),
                message: cleaned.isEmpty ? "git needs a credential." : cleaned,
                placeholder: isSecret(cleaned) ? "••••••••" : nil,
                initialValue: "",
                confirmTitle: "Continue",
                isSecure: isSecret(cleaned),
                validate: nil,
                in: nil
            )
            if let answer {
                FileHandle.standardOutput.write(Data((answer + "\n").utf8))
                exit(0)
            }
            exit(1)
        }
        app.run()
        exit(1)
    }
}
