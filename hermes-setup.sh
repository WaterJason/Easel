#!/usr/bin/env bash
# Easel × Hermes 自检 / 重建
#
# 用法：
#   bash hermes-setup.sh            自检（含一次模型连通测试，约 20 秒）
#   bash hermes-setup.sh --fast     自检（跳过模型测试，约 1 秒）
#   bash hermes-setup.sh sync       重建：技能改符号链接 + 重放 AGENTS.md 补丁
#
# 为什么需要它：有两处会「静默失效」——技能副本飘了不报错；
# AGENTS.md 里若出现触发 Hermes 注入扫描的措辞，整份规则会被拦掉也不报错。
# 两者都只能靠量字节 / 数条目发现，所以固化成一条命令。
set -uo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
SHIM="$ROOT/.hermes-shim"
SKILLS_SRC="$ROOT/skills/openclaw"
SKILLS_DST="$ROOT/.hermes/skills"
AGENTS_UPSTREAM="$ROOT/openclaw/workspace/AGENTS.md"
AGENTS="$ROOT/AGENTS.md"
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

pass=0; warn=0; fail=0
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; fail=$((fail+1)); }
note() { printf '  \033[33m!\033[0m %s\n' "$1"; warn=$((warn+1)); }
hdr()  { printf '\n\033[1m%s\033[0m\n' "$1"; }

# macOS 自带没有 GNU timeout；gtimeout 要 coreutils；再不行用 perl alarm 兜底。
_with_timeout() {
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then gtimeout "$secs" "$@"
  elif command -v perl >/dev/null 2>&1; then perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
  else "$@"; fi
}

# ─────────────────────────────────────────────────────────── 重建
do_sync() {
  hdr "重建技能链接"
  mkdir -p "$SKILLS_DST"
  local made=0 removed=0
  # 上游已删除的技能 → 清掉对应的断链
  for entry in "$SKILLS_DST"/*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    local name; name="$(basename "$entry")"
    if [ ! -d "$SKILLS_SRC/$name" ]; then
      rm -rf "$entry"; removed=$((removed+1))
    fi
  done
  # 逐个改成指向源码的符号链接
  for src in "$SKILLS_SRC"/*/; do
    [ -f "$src/SKILL.md" ] || continue
    local name dst; name="$(basename "$src")"; dst="$SKILLS_DST/$name"
    if [ -L "$dst" ]; then
      [ "$(readlink "$dst")" = "${src%/}" ] && continue
      rm -f "$dst"
    fi
    rm -rf "$dst"
    ln -s "${src%/}" "$dst"
    made=$((made+1))
  done
  printf '  链接新建/修正 %d 个，清理上游已删除 %d 个\n' "$made" "$removed"

  hdr "同步 SOUL.md"
  # 上游的 SOUL.md 同样会飘，用符号链接指向它（无补丁，纯引用）
  if [ -f "$ROOT/openclaw/workspace/SOUL.md" ]; then
    if [ -L "$ROOT/SOUL.md" ] && [ "$(readlink "$ROOT/SOUL.md")" = "openclaw/workspace/SOUL.md" ]; then
      printf '  已是符号链接，跳过\n'
    else
      rm -f "$ROOT/SOUL.md"
      ( cd "$ROOT" && ln -s openclaw/workspace/SOUL.md SOUL.md )
      printf '  已链接到 openclaw/workspace/SOUL.md\n'
    fi
  else
    note "上游没有 SOUL.md，跳过"
  fi

  hdr "重放 AGENTS.md 补丁"
  if [ ! -f "$AGENTS_UPSTREAM" ]; then
    bad "找不到上游 $AGENTS_UPSTREAM"
    return
  fi
  /usr/bin/env python3 - "$AGENTS_UPSTREAM" "$AGENTS" "$ROOT" <<'PY'
import sys, pathlib
upstream, target, root = map(pathlib.Path, sys.argv[1:4])
text = upstream.read_text(encoding="utf-8")

# 补丁 1：Hermes 的注入扫描器会把 `cat .env` 判成凭据窃取载荷（read_secrets），
# 命中后整份规则被拦成残桩且无报错 → 改写掉这处引用。
bad_line = "- 不 `cat .env`、不回显 Key；使用 `model_registry.py configured` 或各脚本 `check`。"
good_line = ("- 禁止直接读取或回显 .env 内容；一律使用 `model_registry.py configured` "
             "或各脚本 `check` 做脱敏检查。")
if bad_line in text:
    text = text.replace(bad_line, good_line)

# 补丁 2：Hermes 的 --in 不改工具工作目录，必须每轮把项目根写进规则里。
marker = "## 运行时项目根（Hermes 路线）"
if marker not in text:
    text = text.rstrip() + (
        f"\n\n{marker}\n\n"
        f"Easel 项目根绝对路径：`{root}`\n\n"
        "运行任何 `skills/...` 项目脚本前必须先 `cd` 到该目录。"
        "所有产物写入该目录下的 `outputs/<主题>/`。\n"
    )
else:
    import re
    text = re.sub(rf"({re.escape(marker)}\n\n)Easel 项目根绝对路径：`[^`]*`",
                  rf"\g<1>Easel 项目根绝对路径：`{root}`", text)

target.write_text(text, encoding="utf-8")
print(f"  已从上游生成 {target.name}（{len(text.encode())} B），含 2 处补丁")
PY
}

# ─────────────────────────────────────────────────────────── 自检
do_check() {
  local deep="${1:-yes}"

  hdr "运行环境"
  if [ -x "$SHIM/openclaw" ]; then ok "转发层可执行"; else bad "转发层缺失或不可执行：$SHIM/openclaw"; fi
  if command -v hermes >/dev/null 2>&1; then
    ok "hermes 可用（$(hermes --version 2>/dev/null | head -1 | cut -c1-40)）"
  else
    bad "PATH 里找不到 hermes"
  fi
  if [ -x "$ROOT/.hermes-shim/openclaw" ] && [ -f "$ROOT/.hermes-shim/sessions.json" ]; then
    ok "会话映射存在"
  else
    note "尚无会话映射（首次对话后生成）"
  fi

  hdr "技能"
  local n_src n_dst n_link
  n_src=$(find "$SKILLS_SRC" -maxdepth 1 -mindepth 1 -type d | wc -l | tr -d ' ')
  n_dst=$(find "$SKILLS_DST" -maxdepth 1 -mindepth 1 2>/dev/null | wc -l | tr -d ' ')
  n_link=$(find "$SKILLS_DST" -maxdepth 1 -type l 2>/dev/null | wc -l | tr -d ' ')
  printf '  源码 %s 个 / 已挂载 %s 个（其中符号链接 %s 个）\n' "$n_src" "$n_dst" "$n_link"
  if [ "$n_src" = "$n_dst" ]; then
    ok "数量一致"
  else
    bad "数量不一致 —— 跑 'bash hermes-setup.sh sync' 重建"
  fi
  if [ "$n_link" = "$n_dst" ] && [ "$n_dst" != "0" ]; then
    ok "全部为符号链接，不会漂移"
  else
    note "$((n_dst - n_link)) 个是副本（不是链接），上游更新后可能飘"
  fi
  local dangling; dangling=$(find "$SKILLS_DST" -maxdepth 1 -xtype l 2>/dev/null | wc -l | tr -d ' ')
  if [ "$dangling" != "0" ]; then
    bad "$dangling 个断链 —— 上游已删除，跑 sync 清理"
  fi

  hdr "规则文件（最容易静默失效的一环）"
  if [ ! -f "$AGENTS" ]; then
    bad "缺少 $AGENTS"
  else
    local sz ctx
    sz=$(stat -f%z "$AGENTS" 2>/dev/null || stat -c%s "$AGENTS")
    ctx=$(cd "$ROOT" && hermes prompt-size 2>/dev/null \
          | sed -n 's/.*context (AGENTS\.md\/cwd files)[^:]*: *\([0-9,]*\) *B.*/\1/p' | tr -d ',')
    if [ -z "$ctx" ]; then
      note "拿不到注入量（hermes prompt-size 无输出），无法判断是否被拦"
    elif [ "$ctx" -ge "$sz" ]; then
      ok "注入 ${ctx} B ≥ 文件 ${sz} B，规则完整进去了"
    else
      bad "注入仅 ${ctx} B，文件有 ${sz} B —— 规则被注入扫描器拦了！跑 sync 重放补丁"
    fi
    if grep -q 'cat \.env' "$AGENTS" 2>/dev/null; then
      bad "文件里出现 'cat .env' 字样，会被判成 read_secrets 并拦掉整份规则"
    fi
  fi

  hdr "服务"
  local c
  c=$(curl -s --noproxy '*' -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:7860/" 2>/dev/null)
  if [ "$c" = "200" ]; then ok "Web 工作台在跑（7860）"; else note "Web 未运行（7860 返回 ${c:-无响应}）"; fi
  c=$(curl -s --noproxy '*' -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:18789/healthz" 2>/dev/null)
  if [ "$c" = "200" ]; then ok "健康探针在跑（18789）"; else note "健康探针未运行（18789）"; fi

  if [ "$deep" = "yes" ]; then
    hdr "模型连通（会真实调用一次，约 20 秒）"
    local out
    # --accept-hooks 必须传：config.yaml 里声明了 shell hook 时，Hermes 会弹
    # "Allow this hook to run? [y/N]" 等 TTY 输入，无人值守会永久挂死。
    # 用 timeout 兜底，避免把自检本身也卡住。
    out=$(
      cd "$ROOT" || exit 1
      unset HTTP_PROXY HTTPS_PROXY http_proxy https_proxy ALL_PROXY all_proxy
      _with_timeout 120 hermes --in "$ROOT" --cli --accept-hooks \
        -z "只回复两个字：正常" 2>&1 | tail -3
    )
    if printf '%s' "$out" | grep -q "正常"; then
      ok "模型可达"
    elif [ -z "$out" ]; then
      bad "模型调用无输出（超时或挂起）—— 检查是否 hook 等待审批、或代理环境变量被继承"
    else
      bad "模型调用失败：$(printf '%s' "$out" | head -1 | cut -c1-120)"
      printf '      常见原因：代理环境变量被继承。用 env -u HTTP_PROXY -u HTTPS_PROXY 起服务\n'
    fi
  fi

  hdr "仓库整洁"
  local stray
  stray=$(cd "$ROOT" && ls *.pid *.log 2>/dev/null | tr '\n' ' ')
  if [ -z "$stray" ]; then ok "运行期文件未混在源码目录"; else note "源码目录有运行期文件：$stray"; fi

  printf '\n\033[1m结果\033[0m  通过 %d  警告 %d  失败 %d\n' "$pass" "$warn" "$fail"
  [ "$fail" -eq 0 ]
}

case "${1:-check}" in
  sync) do_sync ;;
  --fast) do_check no ;;
  check|"") do_check yes ;;
  *) printf '用法: bash hermes-setup.sh [check|--fast|sync]\n' >&2; exit 2 ;;
esac
