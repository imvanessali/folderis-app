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

可选录屏只截 Finder 与 Folderis 可见窗口的联合边界，不包含联合边界外的桌面。
启动前先打开 Finder 和 Folderis；首次使用需在「隐私与安全性 → 屏幕录制」授权：

```bash
python3 test-fixtures/run_qa_macos.py --record-screen
```

证据固定写到 `~/Downloads/Folderis QA Evidence/`。已有录屏不会静默覆盖；
确认替换本轮固定文件时显式加 `--overwrite-evidence`。Windows 真机脚本与
macOS 脚本共用 `local_dispatch_cases.json`，两端正/负路由用例只维护一份。

自动测试（不触发屏幕录制授权）：

```bash
python3 -m unittest discover -s test-fixtures/tests -v
```

维护母本时先解锁：`chmod -R u+w "Test "*`，改完后重新锁定：
`find "Test "* -exec chmod a-w {} +`
