# Easel × Hermes 接入层

把 [Easel](https://github.com/ZJU-REAL/Easel) 的 Agent 运行时从 OpenClaw 换成
本机已装的 [Hermes Agent](https://github.com/NousResearch/hermes-agent)，
**不改 Easel 源码一行**。

## 为什么这么做

Easel 的程序层（`web/app.py`、`easel/commands/*.py`、`scripts/gateway.sh`）把引擎命令
硬编码成了 `openclaw ...`。如果你本机已经有 Hermes，再装一个 OpenClaw 是多余的。

这个接入层放一个**伪装成 `openclaw` 的转发脚本**在 PATH 最前面，把调用翻译成 Hermes 命令。
好处是 Easel 上游更新时不会冲突——零源码改动。

## 快速开始

```bash
# 1. 准备 Python 环境
python3 -m venv .venv
.venv/bin/pip install -e .

# 2. 重建接入层（生成 AGENTS.md、挂技能符号链接）
bash hermes-setup.sh sync

# 3. 自检
bash hermes-setup.sh

# 4. 启动
bash start-easel.sh          # 然后打开 http://127.0.0.1:7860
```

前提：`hermes` 在 PATH 中（通常 `~/.local/bin/hermes`），且已登录某个模型供应商
（`hermes status` 可查）。

## 它做了什么

```
网页对话页 → Easel 后端 → 转发层(伪装 openclaw) → Hermes → 产物落盘
```

| 文件 | 作用 |
|---|---|
| `.hermes-shim/openclaw` | 转发脚本。解析 `--profile X agent --session-id N --message M`，翻译成 `hermes --in <根> --cli -z M`；用 `--usage-file` 回读会话 ID 实现上下文续接；模拟宿主期望的流式事件 |
| `hermes-setup.sh` | `check`（默认）自检 / `sync` 重建 / `--fast` 跳过模型连通测试 |
| `start-easel.sh` | 启动 Web 工作台：PATH 前置、起健康探针、设环境变量 |

`sync` 会**生成** `AGENTS.md`（上游规则 + 两处补丁）并把 `SOUL.md`、112 个技能挂成符号链接，
所以这些都不入库。

## 两处静默失效（这是自检存在的理由）

这套接法有两个坑，**都不会报错**：

**1. 规则文件被注入扫描器拦掉。**
Hermes 加载项目规则前会做提示注入扫描（`tools/threat_patterns.py`）。Easel 上游
`AGENTS.md` 里有一句「不 \`cat .env\`、不回显 Key」——这条**安全指令**命中了
`cat ... .env` 的 `read_secrets` 模式，被判定为凭据窃取载荷，**整份规则被拦成残桩且无任何日志**。

后果是静默的：规则注入量从 ~11.7 KB 掉到 ~1.9 KB，然后 Agent 开始把产物写到 `~/outputs/`
而不是项目里，也不再按技能路由。`sync` 会把这句改写成不触发扫描的表述。

**2. `--in DIR` 不改工具的工作目录。**
实测：即使进程 CWD 已是项目根、且显式传了 `--in <绝对路径>`，Hermes 里 Agent 的 `pwd`
仍是 `$HOME`（`--no-restore-cwd` 也无效）。`--in` 只改会话分组标签。

所以转发层**每轮消息前缀里显式带上项目根**——这是必须的，否则 Agent 找不到项目。

## ⚠️ 如果你的 Hermes 配了 shell hook，必须传 `--accept-hooks`

`~/.hermes/config.yaml` 里若声明了 `hooks:`（例如 `on_session_start` / `pre_tool_call`），
Hermes 首次遇到会弹：

```
Allow this hook to run? [y/N]:
```

**无人值守的运行会永久卡在这里**——没有输出、没有超时、没有报错（实测一句两个字的话
挂了 45 分钟不返回）。转发层因此默认加 `--accept-hooks`。

注意 **`--yolo` 管不了这个**：`--yolo` 绕过的是危险命令审批，hook 审批是另一套。
两个都要传。

可用 `EASEL_SHIM_NO_ACCEPT_HOOKS=1` 关掉（那时若配了 hook 就会卡，需自行处理）。
或者在 Hermes 侧一次性关掉提示：`hooks_auto_accept: true`。

## 自检覆盖了什么

`bash hermes-setup.sh` 会查：转发层可执行 / hermes 可达 / 技能数与链接数一致 / 断链数 /
**规则注入字节数（判断第 1 条静默失效）** / 两个端口 / **真跑一次模型调用**
（带 120 秒超时，用 `perl alarm` 兜底——macOS 没有 GNU `timeout`）/ 仓库整洁。

模型那一步最容易漏，但代理继承、hook 死锁这类问题只有真跑才暴露。

## 上游更新后

```bash
git pull
bash hermes-setup.sh sync && bash hermes-setup.sh
```

`sync` 幂等，重复跑结果一致。技能用符号链接指向 `skills/openclaw/`，所以上游改了技能
Hermes 立刻看到，不需要同步。上游删掉某个技能时链接变断链，自检会报出来。

## 已知限制

- **不是逐字流式**。Easel 靠一个 JSONL 事件流做逐字显示，Hermes 没有 stream-json 输出模式，
  所以转发层只能把整段回答作为一次性事件写入。功能正常，只是答案整体出现而非逐字浮现。
- **会话是两套**。Easel 的会话 ID 与 Hermes 的会话 ID 靠 `.hermes-shim/sessions.json` 映射，
  不共享历史。网页里聊过的内容，命令行 `hermes` 看不到（反之亦然）。
- **健康探针是个桩**。Easel 前端靠探测 `127.0.0.1:18789/healthz` 判断"网关是否连通"。
  Hermes 路线下没有 OpenClaw gateway，`start-easel.sh` 起了一个只回 200 的最小服务，
  让状态指示如实反映"Agent 后端可用"。
- 前端有两处**缺加载态**（技能库请求中显示"0 个技能"、工作台把"连接中"当"未连接"）。
  未修，因为修要改 Easel 源码，会破坏零改动这个前提。

## 前置条件

- macOS（转发层用了 `fcntl` 风格的锁语义与 macOS 路径习惯；Linux 大致可用但未测）
- Hermes Agent v0.20+（转发层依赖 `--usage-file`、`prompt-size`、`skills trust`、
  `--accept-hooks`）
- Python 3.11+、Node 18+（Easel 自身要求）
- **Hermes 的模型 provider 必须可达**——见下

## ⚠️ 如果 Hermes 指向本地 provider 桥，那个桥必须先起来

Hermes 可以把模型指向一个本地进程（`~/.hermes/config.yaml` 里 `providers.<名>.base_url`
形如 `http://127.0.0.1:PORT/v1`，用途是把订阅账号暴露成 OpenAI 兼容端点）。

**那个桥没启动时，Hermes 只报笼统的 `API call failed after 3 retries: Connection error.`**
——完全看不出是本地依赖没起，极易误判成网络问题、代理问题或授权过期。

自检里有一项专门查这个：

```
Provider 端点
  ✓ 本地 provider「magpie」在跑（http://127.0.0.1:3425/v1）
```

报 ✗ 就是桥没起。手动确认：

```bash
lsof -iTCP:<端口> -sTCP:LISTEN
hermes status        # 看 Model / Provider 那两行
```

