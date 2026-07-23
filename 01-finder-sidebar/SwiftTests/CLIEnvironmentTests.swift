import XCTest
@testable import FinderSidebarPanel

final class CLIEnvironmentTests: XCTestCase {
    func testCLIPathIsPrependedForGUIEnvironment() {
        let environment = BackendKind.environmentForCLI(
            at: "/Users/example/.local/bin/claude",
            base: ["PATH": "/usr/bin:/bin"]
        )

        XCTAssertEqual(environment["PATH"], "/Users/example/.local/bin:/usr/bin:/bin")
    }

    func testExistingCLIPathIsNotDuplicated() {
        let environment = BackendKind.environmentForCLI(
            at: "/Users/example/.local/bin/claude",
            base: ["PATH": "/Users/example/.local/bin:/usr/bin:/bin"]
        )

        XCTAssertEqual(environment["PATH"], "/Users/example/.local/bin:/usr/bin:/bin")
    }

    func testCLIExitCodeIsNotPresentedAsHTTPStatus() {
        let message = APIError.cli(
            exitCode: 127,
            body: "Claude Code: env: node: No such file or directory"
        ).message

        XCTAssertTrue(message.contains("127"))
        XCTAssertFalse(message.contains("HTTP"))
    }
}
