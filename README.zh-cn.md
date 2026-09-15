# hands-free-vibe

[English](README.md)

hands-free-vibe（hfv）是一个无人值守的仓库维护机器人，服务对象是一个 RAGFlow fork。入口是飞书群里的缺陷反馈，出口是 GitHub 上的 PR，以及从评审到合并之间的全部跟进工作。整个过程没有人在环路里：认领、复现、修复、验证、交付、答复评审、重基、报告可合并，都由它自己完成。

## 一条反馈的完整旅程

**录入。** 一个 recorder 守护进程定时扫飞书群。新报告作为不透明记录落进本地 store，附件下载到本地；截图和录屏由视觉模型转写成文字，修复者全程不需要打开任何图片。recorder 是通用组件，源可插拔：与飞书（Lark）群主源并列，还有一个实验性质的 GitHub issue 源——按标签收录 open issue，正文和评论里的截图链接在录入时同样下载转写。两个源写进同一个 store，下游只用 message_id 前缀分发，不关心记录来自哪里。

**修复。** 每个任务跑在一个一次性容器里。golden 镜像是冻结的：完整服务栈（MySQL / Elasticsearch / Redis / MinIO / NATS）、模型 provider、登录态全部烘焙在内，任务容器之间互不影响。agent 在里面做真实的复现和验证——起整个应用、走浏览器级的检查（chrome-devtools MCP）、跑分层测试，而不是只看 diff 说话。

**交付。** agent 无权碰 git。它只把分支名、commit message、PR 标题/正文、验证截图暂存到目录里，宿主侧脚本接手：先打备份 ref，再校验暂存内容的归属（worktree 印章对不上就归档而不是交付），然后 commit、推送。几种经典翻车方式——把整个 worktree 池扫进提交、空暂存集、在主仓根目录交付——都有硬守卫直接拒绝。

**GitHub 出口收敛到一个后台服务。** gh-recorder 每分钟一趟，是全系统唯一碰 GitHub 的组件。所有写操作——建 PR、评论、摘打标签、甚至 git push——都先入队到磁盘上的 outbox，由它带重试地执行，支持依赖链（"已修复"的回复只在对应 push 真正落地后发出）。推送有三重安全闸：只允许线池 worktree、只推 fork、永远不碰基线分支。同一个服务还异步扫描所有在跟踪的 PR：三通道对齐的完整评论清单、评审状态、CI 桶，评论里的图片附件同样下载并转写。线脚本和容器只读本地快照，不碰 GitHub；容器里没有任何凭证。

**跟进。** PR 交出去之后还有四条线各管一段：review 线读快照里的新评审意见，判断有效性，修复后推送并逐条答复；rebase 线在无冲突时走十几秒的纯脚本快速路，有冲突才动用 LLM，force-with-lease 推送也走 outbox；ci 线盯检查单，区分 flake 和真失败，重触发标签门控的套件，自己的 PR 自己修，别人的 PR 留评论提醒；follow 是纯脚本状态机，负责 merged/closed 翻转、停滞催办和「可以合并了」的 DM。

**反向评审。** pr-audit 线评审别人提交给上游的 PR：recorder 已把 meta 和评论预扫描好，audit 在容器里把应用真正起起来做端到端验证，结论是 LGTM / PROBLEMS / INCOMPLETE；LGTM 自动打上门禁标签，和自家交付共用一个合并信号。

**它会变聪明。** 每个任务把教训写进滚动 playbook，效果引擎按「后续任务省了几轮迭代」给教训排位，有用的浮上来，失效的沉下去被清掉。playbook 分中英文滚动区和归档区，语言有门禁检查。

## 形态

systemd 用户级 timer 驱动每条线，线之间互不依赖。每条线可独立扩缩容（`hfv scale <line> <n>`），per-instance 锁加取模分片，实例互不踩踏。任务 worktree 池有 48 小时壳回收；闲置超过一小时的 per-PR 服务组自动停机（卷保留，下轮热启动）。ClickHouse 收集指标，`hfv ps` / `hfv log` / `hfv follow` 看实时任务视图。

另外有一条手动 feat 线：`hfv feat -f spec.md`，按需求文档实现完整特性，复用同一套交付机器。

## 适用边界

它为「一个仓库 + 一个飞书群」而建，不为通用场景设计。站点相关的配置（仓库路径、GitHub 身份、merge owner、飞书凭证）全部 gitignore，模板在 `hfv.conf.example` 和 `issues/config.example`。

## 安装

前置：Linux（systemd 用户会话）、Docker、Node 22+、Python 3.11+、uv、Google Chrome、一个桌面会话（lark-mcp 的加密 token 存储依赖 D-Bus Secret Service）。

```bash
git clone <this-repo> ~/hands-free-vibe && cd ~/hands-free-vibe
bash install.sh
```

install.sh 检查前置、装 cline CLI、从官方 npm registry 装 MCP 工具并生成固定桌面会话环境的 wrapper、从模板生成站点配置、构建 `hfv-task:base` 镜像、装 systemd 单元。幂等；`--check` 只校验不改动。

首次 golden 引导：起一个一次性容器，`ragflow-up.sh` 把栈拉起来，浏览器里登录一次，然后 `docker commit <容器> hfv-task:latest`。golden 此后冻结，不随任务回写；更新走手动引导流程。

## 日常

```bash
hfv on                    # 启用所有线（各 1 实例）
hfv scale issue 2         # issue 线开 2 个并行实例
hfv ps                    # 任务视图：每条线的每个实例在干什么
hfv log / hfv follow      # 看日志（默认第一个运行中的任务）
hfv run [n]               # 立刻触发一次 issue 运行
hfv stop                  # 全部停掉（含容器）
```

## License

[MIT](LICENSE)
