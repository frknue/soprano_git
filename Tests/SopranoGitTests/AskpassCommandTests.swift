import AppKit
import Testing
@testable import SopranoGit

struct AskpassCommandTests {
    @Test func gitsCallbackIsRecognizedOnlyWithTheAskpassEnvironmentFlag() {
        let binary = "/Applications/Soprano Git.app/Contents/MacOS/SopranoGit"
        let prompt = "Password for 'https://me@github.com': "

        #expect(AskpassCommand.prompt(arguments: [binary, prompt], environment: ["SOPRANO_GIT_ASKPASS": "1"]) == prompt)
        #expect(AskpassCommand.prompt(arguments: [binary, prompt], environment: [:]) == nil)
        #expect(AskpassCommand.prompt(arguments: [binary], environment: ["SOPRANO_GIT_ASKPASS": "1"]) == nil)
        #expect(AskpassCommand.prompt(arguments: [binary, "-psn_0_123"], environment: ["SOPRANO_GIT_ASKPASS": "1"]) == nil)
        #expect(AskpassCommand.prompt(arguments: [binary, "askpass", "Username for", "x:"], environment: [:]) == "Username for x:")
    }

    @Test func secretsGetASecureFieldAndQuestionsAPlainOne() {
        #expect(AskpassCommand.isSecret("Password for 'https://github.com': "))
        #expect(AskpassCommand.isSecret("Enter passphrase for key '/Users/me/.ssh/id_ed25519': "))
        #expect(!AskpassCommand.isSecret("Username for 'https://github.com': "))
        #expect(!AskpassCommand.isSecret("Are you sure you want to continue connecting (yes/no/[fingerprint])? "))
        #expect(AskpassCommand.title(for: "Enter passphrase for key 'k': ") == "SSH Key Passphrase")
        #expect(AskpassCommand.title(for: "Username for 'https://github.com': ") == "Git Username")
    }
}
