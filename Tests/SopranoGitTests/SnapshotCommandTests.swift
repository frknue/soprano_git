import AppKit
import Testing
@testable import SopranoGit

struct SnapshotCommandTests {
    @Test func optionsParseIntoTheHarnessConfiguration() throws {
        let options = try SnapshotCommand.parse([
            "--repo", "/tmp/fixture/work", "--out", "/tmp/shot.png", "--size", "1200x800",
            "--theme", "nord", "--keys", "cmd+p j enter", "--wait", "1.5", "--dialog", "choose",
            "--recent", "/tmp/a,/tmp/b", "--fail", "Push",
        ])

        #expect(options.repo?.path == "/tmp/fixture/work")
        #expect(options.out.path == "/tmp/shot.png")
        #expect(options.size == NSSize(width: 1200, height: 800))
        #expect(options.theme == "nord")
        #expect(options.keys == ["cmd+p", "j", "enter"])
        #expect(options.wait == 1.5)
        #expect(options.dialog == "choose")
        #expect(options.recent.map(\.path) == ["/tmp/a", "/tmp/b"])
        #expect(options.fail == "Push")
    }

    @Test func badOptionsAreRejected() {
        #expect(throws: SnapshotCommand.OptionError.self) { try SnapshotCommand.parse(["--repo", "/tmp/x"]) }
        #expect(throws: SnapshotCommand.OptionError.self) { try SnapshotCommand.parse(["--out", "/tmp/x.png", "--size", "big"]) }
        #expect(throws: SnapshotCommand.OptionError.self) { try SnapshotCommand.parse(["--out", "/tmp/x.png", "--bogus"]) }
        #expect(throws: SnapshotCommand.OptionError.self) { try SnapshotCommand.parse(["--out"]) }
    }
}
