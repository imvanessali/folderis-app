# 测试素材母本（勿在此目录内直接测试）

- 本目录是 QA 素材的唯一权威来源，文件已设为只读。
- **每轮测试前**运行 `./reset_test_folder.sh` 把干净副本重置到
  `~/Downloads/Test Folderis`（或传参指定其他目录），在副本上测试。
- 合成类素材（文档/音频/Excel补充样例/印章/字幕）由 `make_fixtures.py`
  确定性生成；需要调整素材时改脚本重新生成，不要手改产物。
- 真原件（图片/PDF/视频/原始Excel）直接入库，不可再生，务必保持只读。
- Windows 侧同理：把本目录打包复制过去后，同样"母本只读、副本测试"。

## 自动 QA

macOS 每一轮都由脚本先调用上面的 reset 脚本，再在
`~/Downloads/Test Folderis` 副本上运行内置本地技能（不经过 AI）：

```bash
python3 test-fixtures/run_qa_macos.py
```

可选录屏只截 Finder 与 Folderis 面板形成的单一无缝矩形。启动前必须只保留
一个 Finder 窗口和一个 Folderis 面板（关闭设置/引导等额外窗口），并把面板
紧贴 Finder、对齐上下边；否则脚本会在录制前明确失败，绝不把桌面缝隙录进去。
整轮开始前批准一次精确窗口几何；每个任务录制前都会重新置前同一个 Finder
窗口（不点击文件、不改变选择）。如果面板缺失，脚本会调用 Folderis 菜单栏的
「显示/隐藏聊天面板」恢复它；如果面板虽有 AX 几何却被其他应用遮挡，则安全地
关闭/重开面板。随后脚本会重新读取两个窗口，证明其几何仍与批准值完全相同，
并用 CoreGraphics 的屏幕 z-order 证明两个矩形上方没有相交的无关 layer-0
窗口。面板缺失、几何变化或可见像素归属无法证明时，该任务会记录 `ERROR` 并
跳过 screencapture，绝不会只凭 AX 几何录到其他窗口。
首次使用需在「隐私与安全性 → 屏幕录制」授权：

```bash
python3 test-fixtures/run_qa_macos.py --record-screen
```

每个实际 QA 任务各写一个可独立播放的 H.264 MP4，默认位于
`~/Downloads/Folderis QA Evidence/recordings/`。文件名以稳定任务 ID 开头，
报告中对应的任务行会记录视频路径、`RECORDED`/`ERROR` 状态和错误详情。纯粹在
命令结束后读取产物、原件或哈希的汇总验证不会生成空录屏。可用
`--recording-directory PATH` 改目录；旧的单文件 `--recording-output` 会给出明确
迁移提示。整轮开始前会一次性检查全部目标文件，已有证据不会静默覆盖；确认
替换本轮同名文件时显式加 `--overwrite-evidence`。

Windows 真机脚本与 macOS 脚本共用 `local_dispatch_cases.json`，两端正/负路由
用例只维护一份。
此外，macOS 报告的 `structural_validations` 会逐项执行并语义验证既有
`W-01`…`W-47` 真素材工作流；每行都记录精确输入、实际输出、关键参数和证据，
不会用汇总行或填充 PASS 冒充 47 项。

自动测试（不触发屏幕录制授权）：

```bash
python3 -m unittest discover -s test-fixtures/tests -v
```

维护母本时先解锁：`chmod -R u+w "Test "*`，改完后重新锁定：
`find "Test "* -exec chmod a-w {} +`
