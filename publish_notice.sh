#!/bin/bash
# 下发/撤回版本公告(两端唯一的更新通道):
#   1. 改 announce/public/announce.json —— mac/win 各自的 version(比装机新才亮横幅)
#      与 url(横幅「前往下载」打开的网页);message.zh/en 可选自定义文案。
#   2. 跑本脚本上线。撤回 = 把 version 改回线上版本再跑一次。
# 前置(一次性):npm i -g wrangler && wrangler login
set -euo pipefail
cd "$(dirname "$0")/announce"

FEED="https://folderis-announce.folderis.workers.dev/announce.json"

# 先验 JSON 格式,防止把坏文件推上线(客户端解析失败会静默不提示,等于没发)
python3 - <<'EOF'
import json, sys
d = json.load(open("public/announce.json"))
for plat in ("mac", "win"):
    node = d.get(plat) or {}
    v, u = node.get("version", ""), node.get("url", "")
    assert v.strip(), f"{plat}.version 不能为空"
    assert u.startswith("https://"), f"{plat}.url 必须是 https:// 开头: {u!r}"
print("announce.json 校验通过:",
      ", ".join(f"{p} {d[p]['version']}" for p in ("mac", "win")))
EOF

WRANGLER=(wrangler)
command -v wrangler >/dev/null || {
  command -v npx >/dev/null || { echo "缺少 wrangler:npm i -g wrangler"; exit 1; }
  WRANGLER=(npx wrangler)
}
"${WRANGLER[@]}" deploy

# 上线后回读验证,确认边缘拿到的就是刚发的内容
sleep 2
diff <(curl -fsS "$FEED") public/announce.json && echo "已生效:$FEED"
