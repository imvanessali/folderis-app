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

    func testSkillsBriefTellsCLIHowToInvokeToolboxAndRequiresConsent() throws {
        // 运行时未安装的机器上简报为空（CLI 不该被承诺不存在的工具箱）。
        let brief = ChatViewModel.cliSkillsBrief
        try XCTSkipIf(brief.isEmpty, "skills runtime not installed on this machine")

        XCTAssertTrue(brief.contains("skills.py"), "必须给出工具箱调用路径")
        XCTAssertTrue(brief.contains("install-component"), "组件安装必须走同意流程")
        XCTAssertTrue(brief.contains(ChatViewModel.skillsCatalog.prefix(40)),
                      "技能目录必须完整并入简报")
    }

    func testArtifactPolicyExtractionUsesStableMarker() {
        let policy = "全局产物规则：所有技能默认保留原文件和每一次历史产物。多个最终文件统一放进版本化的 Output（已有则 Output_2、Output_3）。文件碰撞使用 _2、_3，不允许静默覆盖。删除/去重类任务必须在 Output 中构建安全副本。"
        let catalog = "# 注释/版本头也不影响提取\n\(policy)\nrename-batch <files…> — 批量重命名"

        XCTAssertEqual(ChatViewModel.extractArtifactPolicy(from: catalog), policy)
        XCTAssertNil(ChatViewModel.extractArtifactPolicy(from: "没有政策标记的目录"),
                     "缺标记必须判定为运行时损坏")
        XCTAssertNil(ChatViewModel.extractArtifactPolicy(from: "全局产物规则：太短"),
                     "截断的政策段必须判定为运行时损坏")
    }

    func testBackendPromptsDoNotDuplicateSharedArtifactPolicy() {
        // 共享政策唯一来源是 catalog；后端提示词只允许保留指针。
        for fragment in ["版本化的 Output（已", "构建安全副本并提示用户核对"] {
            XCTAssertFalse(ChatViewModel.cliScopePolicyForTesting.contains(fragment),
                           "cliScopePolicy 不得内嵌共享政策正文：\(fragment)")
        }
        XCTAssertTrue(ChatViewModel.cliScopePolicyForTesting.contains("全局产物规则"),
                      "cliScopePolicy 必须保留指向单一来源的指针")
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
