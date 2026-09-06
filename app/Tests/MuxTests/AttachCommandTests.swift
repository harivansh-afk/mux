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
}
