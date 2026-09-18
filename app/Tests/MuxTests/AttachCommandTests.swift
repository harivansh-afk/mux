@testable import Mux
import XCTest

final class AttachCommandTests: XCTestCase {
    func testShellReceivesLiteralArguments() throws {
        let arguments = [
            "", "a path with spaces", "a'quote", "a\"quote", "$HOME",
            "$(printf expanded)", "`printf expanded`", "a\\path", "line\nbreak",
            "github:owner/repo#template", "日本語",
        ]
        let command = Muxd.Attach.quote(["printf", "%s\\0"] + arguments)
        for shell in ["/bin/sh", "/bin/bash", "/bin/zsh"] {
            let output = try XCTUnwrap(Subprocess.output(shell, ["-c", command]))
            XCTAssertEqual(output, arguments.map { $0 + "\0" }.joined(), shell)
        }
    }

    func testBundleRequiresBothExecutableHelpers() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertEqual(Muxd.missingHelpers(in: directory), ["mux-attach", "muxd"])
        for name in ["mux-attach", "muxd"] {
            let path = directory.appendingPathComponent(name)
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: path)
            XCTAssertTrue(Muxd.missingHelpers(in: directory).contains(name))
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        }
        XCTAssertTrue(Muxd.missingHelpers(in: directory).isEmpty)
    }

    func testEveryTargetUsesTheRelayAndPreservesAttachOptions() throws {
        let id = UUID()
        let source = UUID()
        for target: String? in [nil, "spark", "ix:dev"] {
            let attach = Muxd.Attach(
                paneID: id, target: target, ptyCommand: nil,
                expectExisting: true, requireExisting: true
            )
            let command = attach.commandLine(cwd: "/stale", cwdFrom: source)
            // Decode the shell command without running a daemon or creating a PTY.
            let output = try XCTUnwrap(Subprocess.output("/bin/sh", ["-c", "printf '%s\\0' " + command]))
            let arguments = output.split(separator: "\0").map(String.init)
            XCTAssertEqual(Array(arguments.prefix(3)), [Muxd.attachBinary, attach.address, "--require-existing"])
            XCTAssertFalse(arguments.contains("--expect-existing"))
            if target == "ix:dev" {
                XCTAssertEqual(Array(arguments.suffix(4)), ["--", IX.binary, "shell", "dev"])
            } else {
                XCTAssertEqual(Array(arguments.suffix(2)), ["--cwd-from", source.uuidString])
            }
        }
    }
}
