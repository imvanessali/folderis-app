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
}
