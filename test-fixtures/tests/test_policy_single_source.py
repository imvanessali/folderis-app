# -*- coding: utf-8 -*-
"""共享产物政策的单一来源守卫（macOS + Windows 同测）。

政策正文只允许存在于 skills/catalog.txt 的「全局产物规则」段；
四个后端提示词位置（macOS CLI/内置、Windows CLI/内置）只能保留指针。
任何一端把政策正文抄回源码，本测试显式失败。
"""
import re
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
CATALOG = REPO / "01-finder-sidebar" / "skills" / "catalog.txt"
MAC_VM = REPO / "01-finder-sidebar" / "HostApp" / "ChatViewModel.swift"
WIN_PANEL = REPO / "win-explorer-sidebar" / "src" / "Sider" / "MainPanel.xaml.cs"
WIN_RUNNER = REPO / "win-explorer-sidebar" / "src" / "Sider" / "SkillRunner.cs"
MARKER = "全局产物规则："

# 政策正文的独特语块：出现在提示词源码里即视为重复内嵌。
POLICY_FRAGMENTS = [
    "版本化的 Output（已",
    "构建安全副本并提示用户核对后手动删除",
    # B6/B7（20260805.3 §9）：HTML 自包含与表格列类型同属政策正文，禁止抄回源码。
    "以 data URI 内嵌",
    "按对应的数值/日期类型写入",
]


class PolicySingleSourceTests(unittest.TestCase):
    def test_catalog_policy_segment_is_complete(self):
        text = CATALOG.read_text(encoding="utf-8")
        self.assertIn(MARKER, text)
        policy = text[text.index(MARKER):].split("\n", 1)[0].strip()
        self.assertGreater(len(policy), 80)
        for term in ["原文件", "Output", "覆盖", "副本"]:
            self.assertIn(term, policy, f"政策段缺少关键语义：{term}")
        # A3（20260805.3 case23/28/55）：归置进 Output 必须是移动，根目录零残留。
        for term in ["移动（move）", "不得残留"]:
            self.assertIn(term, policy, f"政策段缺少归置语义：{term}")
        # B6（20260805.3 case53）：HTML 汇报默认自包含，无法内嵌时必须明示同目录依赖。
        for term in ["data URI", "同一目录"]:
            self.assertIn(term, policy, f"政策段缺少 HTML 自包含语义：{term}")
        # B7（20260805.3 case9）：表格数字/金额/日期列写对应类型，不写文本。
        for term in ["数值/日期类型", "不得写成文本"]:
            self.assertIn(term, policy, f"政策段缺少表格列类型语义：{term}")

    def test_backend_prompts_keep_only_pointers(self):
        for src in (MAC_VM, WIN_PANEL):
            code = src.read_text(encoding="utf-8")
            for fragment in POLICY_FRAGMENTS:
                self.assertNotIn(
                    fragment, code,
                    f"{src.name} 内嵌了共享政策正文（{fragment}）——唯一来源是 catalog.txt")
            self.assertIn(MARKER.rstrip("："), code,
                          f"{src.name} 应保留指向「全局产物规则」的指针或提取器")

    def test_both_platforms_extract_by_the_same_marker(self):
        mac = MAC_VM.read_text(encoding="utf-8")
        win = WIN_RUNNER.read_text(encoding="utf-8")
        self.assertIn('artifactPolicyMarker = "全局产物规则："', mac)
        self.assertIn('ArtifactPolicyMarker = "全局产物规则："', win)
        # fail-safe：双端都必须存在“运行时损坏即拒绝”的分支。
        for code, name in ((mac, MAC_VM.name), (win, WIN_PANEL.name + "/" + WIN_RUNNER.name)):
            self.assertIn("技能运行时损坏或缺失", code if code is mac else
                          WIN_PANEL.read_text(encoding="utf-8"),
                          f"{name} 缺少运行时损坏 fail-safe")


if __name__ == "__main__":
    unittest.main()
