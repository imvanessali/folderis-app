#!/bin/bash
# 从母本重置测试文件夹：每轮 QA 前跑一次，保证从干净状态开始。
# 用法：./reset_test_folder.sh [目标目录]
#   默认目标 ~/Downloads/Test Folderis（会先整体移入废纸篓式备份再重建）
set -euo pipefail
MASTER="$(cd "$(dirname "$0")" && pwd)"
TARGET="${1:-$HOME/Downloads/Test Folderis}"

if [ -d "$TARGET" ]; then
  BAK="${TARGET}-旧-$(date +%m%d-%H%M%S)"
  mv "$TARGET" "$BAK"
  echo "已把旧目录挪到：${BAK}（确认无需要保留的产物后可删除）"
fi
mkdir -p "$TARGET"
# 只拷素材目录，不拷脚本和说明
for d in "Test Image" "Test Excel" "Test PDF" "Test Video" "Test Docs" "Test Audio" "Test Misc"; do
  [ -d "$MASTER/$d" ] && cp -R "$MASTER/$d" "$TARGET/"
done
find "$TARGET" -name '.DS_Store' -delete 2>/dev/null || true
# 重置后的副本恢复可写（母本是只读的）
chmod -R u+w "$TARGET"
echo "已从母本重置：$TARGET"
