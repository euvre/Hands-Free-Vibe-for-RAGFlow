# hands-free-vibe

[English](README.en.md)

**hands-free-vibe（hfv）** 是一个无人值守的开源仓库维护机器人：它以飞书群里的 issue 反馈为入口，自动完成「认领 → 复现 → 修复 → 验证 → 交付 PR → 跟进评审 → 重基 → 报告可合并」的完整闭环，全程由 LLM agent（Cline CLI）在一次性 Docker 容器里执行。

## 它在做什么

| 线 | 职责 |
|---|---|
| **issue** | 监听飞书群的新反馈，截图经视觉模型转写后，LLM 在一次性容器里复现/修复/验证，交付 PR 并在群里回复 |
| **feat** | 手动触发（`hfv feat -f spec.md`）：按需求文档实现一个完整特性并交付 PR |
| **pr-review** | 跟踪我们提交的 PR：读评审意见、判断有效性、修复并回复 |
| **pr-rebase** | PR 与 main 冲突时做语义化重基（无冲突走纯脚本快速路） |
| **pr-audit** | 反向角色：评审**别人的** PR（端到端实测后给出 LGTM / PROBLEMS / INCOMPLETE，LGTM 自动打标） |
| **pr-ci** | CI 失败时自动定位并修复 |
| **follow** | 纯脚本状态机：merged/closed 翻转、停滞催办、「可以合并」DM |

支撑系统：任务级 playbook 自我进化（八宫效果引擎按「省迭代数」归位规则）、ClickHouse 指标、每任务一次性容器 + golden 镜像滚动固化（账号/登录态/模型配置随镜像层保留）。

## 架构一句话

所有 LLM 运行都在容器里（golden 镜像 `hfv-task:latest`，每任务一次性实例，干净退出时 `docker commit` 滚动回写）；systemd 用户级 timer 驱动各线；每条线可独立扩缩容（`hfv scale <line> <n>`），per-instance 锁 + 取模分片保证互不踩踏。

## 安装

前置：Linux（systemd 用户会话）、Docker、Node 22+、Python 3.11+、uv、Google Chrome、一个桌面会话（lark-mcp 的加密 token 存储依赖 D-Bus Secret Service）。

```bash
git clone <this-repo> ~/hands-free-vibe && cd ~/hands-free-vibe
bash install.sh
```

`install.sh` 会：检查系统依赖 → 安装 cline CLI → **从官方 npm registry 安装 MCP 工具**（`@larksuiteoapi/lark-mcp`、`chrome-devtools-mcp`，filesystem 走 npx）**并生成 wrapper**（固定桌面会话环境）→ 从模板生成站点配置 → 构建 `hfv-task:base` 镜像 → 安装 systemd units。幂等，可反复执行；`--check` 只检查不改动。

然后填入真实配置（全部 gitignored，永不入库）：

| 文件 | 内容 |
|---|---|
| `hfv.conf` | 仓库路径、GitHub 身份、合并负责人等（模板 `hfv.conf.example`） |
| `issues/config` | 飞书群与应用凭据、vision 转写用的 Kimi key（模板 `issues/config.example`） |
| `model-keys.json` | LLM key 列表（quota 时自动轮换） |

golden 镜像首次引导：起一个一次性容器 → `ragflow-up.sh` 起栈 + 浏览器登录一次 → `docker commit <容器> hfv-task:latest`。

## 日常使用

```bash
hfv on                    # 启用全部线（各 1 实例）
hfv scale issue 2         # issue 线 2 路并行
hfv ps                    # 任务视图：每条线每个实例在跑什么
hfv log / hfv follow      # 看日志（默认第一个运行中的任务）
hfv run [n]               # 立即触发一次 issue 运行
hfv stop                  # 全停（含容器）
```

## 许可证

[MIT](LICENSE)
