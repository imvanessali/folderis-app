import XCTest
@testable import FinderSidebarPanel

final class FinderContextTests: XCTestCase {
    func testSelectionIsLimitedToFrontFinderFolder() {
        let front = URL(fileURLWithPath: "/tmp/front", isDirectory: true)
        let selection = [
            URL(fileURLWithPath: "/tmp/front/a.txt"),
            URL(fileURLWithPath: "/tmp/stale/b.txt")
        ]

        XCTAssertEqual(
            FinderContext.selectionInFrontFolder(selection, folder: front),
            [URL(fileURLWithPath: "/tmp/front/a.txt")]
        )
    }

    func testSelectionIsEmptyWithoutAFrontFinderFolder() {
        XCTAssertTrue(
            FinderContext.selectionInFrontFolder(
                [URL(fileURLWithPath: "/tmp/stale/b.txt")],
                folder: nil
            ).isEmpty
        )
    }

    func testTaskWorkingDirectoryUsesActualAttachmentParent() {
        let staleBinding = URL(fileURLWithPath: "/tmp/stale", isDirectory: true)
        let attachments = [
            URL(fileURLWithPath: "/tmp/front/a.txt"),
            URL(fileURLWithPath: "/tmp/front/b.txt")
        ]

        XCTAssertEqual(
            ChatViewModel.taskWorkingDirectory(boundFolder: staleBinding, attachments: attachments),
            URL(fileURLWithPath: "/tmp/front", isDirectory: true)
        )
    }

    func testTaskWorkingDirectoryFallsBackForMixedAttachmentParents() {
        let binding = URL(fileURLWithPath: "/tmp/front", isDirectory: true)
        let attachments = [
            URL(fileURLWithPath: "/tmp/front/a.txt"),
            URL(fileURLWithPath: "/tmp/other/b.txt")
        ]

        XCTAssertEqual(
            ChatViewModel.taskWorkingDirectory(boundFolder: binding, attachments: attachments),
            binding
        )
    }

    func testPollsWhenFinderIsFrontmost() {
        XCTAssertTrue(FinderContext.shouldPoll(
            frontmostBundleIdentifier: "com.apple.finder",
            ownBundleIdentifier: "app.folderis"
        ))
    }

    func testPollsWhenFolderisIsFrontmost() {
        XCTAssertTrue(FinderContext.shouldPoll(
            frontmostBundleIdentifier: "app.folderis",
            ownBundleIdentifier: "app.folderis"
        ))
    }

    func testDoesNotPollOtherApplications() {
        XCTAssertFalse(FinderContext.shouldPoll(
            frontmostBundleIdentifier: "com.apple.TextEdit",
            ownBundleIdentifier: "app.folderis"
        ))
        XCTAssertFalse(FinderContext.shouldPoll(
            frontmostBundleIdentifier: nil,
            ownBundleIdentifier: nil
        ))
    }

    func testRecognizesAutomationDenialErrorsAcrossSystemVersions() {
        XCTAssertTrue(FinderContext.isAutomationDeniedError(
            "Not authorized to send Apple events to Finder. (-1743)"
        ))
        XCTAssertTrue(FinderContext.isAutomationDeniedError(
            "A privilege violation occurred. (-10004)"
        ))
        XCTAssertFalse(FinderContext.isAutomationDeniedError(
            "Finder got an error: Connection is invalid. (-609)"
        ))
    }
}
