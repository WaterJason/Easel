#!/usr/bin/env bash
# 启动 Easel Web 工作台（Agent 运行时 = 本机 Hermes，无需 OpenClaw）
#
# 用法：
#   bash start-easel.sh            # 默认 7860 端口
#   bash start-easel.sh 8080       # 指定端口
#
# 原理：Easel 的程序层把引擎命令写死成 `openclaw`。本脚本把 .hermes-shim/
# 放到 PATH 最前面，那里有一个名为 openclaw 的转发脚本，会把调用翻译成
# Hermes Agent 命令。Easel 源码不改一行。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
PORT="${1:-7860}"

# Finder / 双击启动时 PATH 是精简的（通常只有 /usr/bin:/bin:/usr/sbin:/sbin），
# ~/.local/bin 不在里面 → 找不到 hermes。显式补上。
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

# 找 Python 环境：优先 $EASEL_VENV（指向 venv 目录），其次仓库内 .venv / venv，
# 最后回退系统 python3
PY=""
for cand in "${EASEL_VENV:+$EASEL_VENV/bin/python}" "$ROOT/.venv/bin/python" "$ROOT/venv/bin/python"; do
  [ -n "$cand" ] && [ -x "$cand" ] && { PY="$cand"; break; }
done

# 候选都不存在时，回退到系统 python3 —— 但它大概率没装依赖，
# 所以下面必须校验，否则会在启动几秒后抛 ModuleNotFoundError，很难定位。
if [ -z "$PY" ]; then
  PY="$(command -v python3 || true)"
fi

if [ -z "$PY" ] || [ ! -x "$PY" ]; then
  echo "找不到可用的 Python 解释器。" >&2
  echo "请建一个环境并装依赖：" >&2
  echo "  python3 -m venv \"$ROOT/.venv\"" >&2
  echo "  \"$ROOT/.venv/bin/pip\" install -e \"$ROOT\"" >&2
  echo "或用 EASEL_VENV=/path/to/venv 指定已有环境。" >&2
  exit 1
fi

# 依赖校验：确认选中的解释器真的装了 Easel 的依赖。
# （不校验的话，回退到系统 python3 会在启动后几秒才报 ModuleNotFoundError）
if ! "$PY" -c 'import fastapi, uvicorn' >/dev/null 2>&1; then
  echo "选中的 Python 环境缺少依赖：$PY" >&2
  echo "装一下：\"$PY\" -m pip install -e \"$ROOT\"" >&2
  echo "或用 EASEL_VENV=/path/to/venv 指定已有环境。" >&2
  exit 1
fi

if ! command -v hermes >/dev/null 2>&1; then
  echo "找不到 hermes 命令；请确认 ~/.local/bin 在 PATH 中。" >&2
  exit 1
fi

# 转发层优先于任何真实 openclaw
export PATH="$ROOT/.hermes-shim:$PATH"
export EASEL_ROOT="$ROOT"
export EASEL_PORT="$PORT"
# 打开转发层日志：记录每轮会话映射与 token 用量，便于排查"网页没反应"
export EASEL_SHIM_LOG=1

# Easel 前端靠探测 http://127.0.0.1:18789/healthz 判断"网关是否连通"。
# Hermes 路线下没有 OpenClaw gateway，这个探测会永远失败、左下角常亮"网关离线"，
# 但它想表达的真实语义是"Agent 后端可用吗"——那个是通的。
# 这里起一个只回 200 的最小探针服务，让状态指示如实反映"可以对话"。
if ! curl -s -o /dev/null --noproxy '*' "http://127.0.0.1:18789/healthz" 2>/dev/null; then
  "$PY" - <<'HEALTHZ' >/dev/null 2>&1 &
import http.server, socketserver
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200); self.send_header("Content-Type", "application/json")
        self.end_headers(); self.wfile.write(b'{"status":"ok","backend":"hermes"}')
    def log_message(self, *a): pass
socketserver.TCPServer.allow_reuse_address = True
socketserver.TCPServer(("127.0.0.1", 18789), H).serve_forever()
HEALTHZ
  HEALTHZ_PID=$!
  trap 'kill "$HEALTHZ_PID" 2>/dev/null || true' EXIT
fi

echo "Easel Web  →  http://127.0.0.1:$PORT"
echo "Agent 引擎 →  Hermes ($(hermes --version 2>/dev/null | head -1))"
echo "转发层     →  $ROOT/.hermes-shim/openclaw"
echo

cd "$ROOT"
"$PY" web/app.py
