# hands-free-vibe

[English](README.md)

hands-free-vibe（hfv）是一个无人值守的仓库维护机器人，服务对象是一个 RAGFlow fork。飞书群里报一个缺陷，它自己认领、复现、修复、验证，把 PR 交到 GitHub；之后的评审答复、rebase、CI 修复、合并就绪报告也归它管。从报告到合并，全程没有人参与。

## 能力

**收报告。** recorder 守护进程定时扫描飞书群，新报告连同附件写进本地 store，截图和录屏由视觉模型转写成文字——修复 agent 全程不需要打开图片。源可插拔：飞书群主源之外还有一个实验性的 GitHub issue 源，按标签收录 open issue，正文和评论里的截图链接在录入时同样下载转写。两个源写同一个 store，下游只按 message_id 前缀分发，不关心记录来自哪里。

**修复与验证。** 每个任务跑在一个一次性容器里，从冻结的 golden 镜像启动：完整服务栈（MySQL / Elasticsearch / Redis / MinIO / NATS）、模型 provider、登录态都预置在镜像里，任务容器互不影响。agent 在容器里把应用真正起起来，在真实浏览器里复现缺陷（chrome-devtools MCP），跑分层测试，修完再验证一轮——不是看着 diff 下结论。

**交付。** agent 没有 git 权限。它只把分支名、commit message、PR 标题正文、验证截图写进暂存目录，宿主侧脚本接手：先打备份 ref，再校验暂存内容的归属（worktree 印章对不上就归档，不交付），然后 commit、推送、开 PR。历史上几种典型事故——把整个 worktree 池扫进提交、空暂存集、在主仓根目录交付——都有硬守卫直接拒绝。

**PR 跟进。** PR 交出去之后，四条线分管后续：

- **review**：读本地快照里的新评审意见，判断哪些有效，修复、推送、逐条答复；
- **rebase**：无冲突走十几秒的纯脚本快速路，有冲突才动用 LLM，force-with-lease 推送也走 outbox；
- **ci**：盯检查单，区分 flake 和真失败，重触发标签门控的套件；自己的 PR 自己修，别人的 PR 留评论提醒；
- **follow**：纯脚本状态机，负责 merged/closed 翻转、停滞催办、给合并负责人发「可以合并了」的私信。

**反向评审。** pr-audit 线评审别人提交给上游的 PR：meta 和评论已由 recorder 预扫描，audit 在容器里把应用起起来做端到端验证，结论是 LGTM / PROBLEMS / INCOMPLETE。LGTM 会自动打上门禁标签——和自家交付共用同一个合并信号。

**按文档做特性。** 手动 feat 线：`hfv feat -f spec.md`，按需求文档实现完整特性，复用同一套交付机器。

**积累经验。** 每个任务把教训写进滚动 playbook。效果引擎不按被引用次数排位，按实际效果：一条教训出现之后，同类任务平均省了几轮迭代，就是它的分数。有用的浮上来，失效的沉下去被清掉。

## HFV 的优势

同一条缺陷从报告到合并，三种做法的差别：

| 维度 | 纯人工 | 半人工 + vibe coding | Hands Free Vibe |
|---|---|---|---|
| 验证 | ❌ 是否复现、是否回归由人自行决定，没有强制验证环节 | ❌ agent 手里只有代码，没有现成的全栈和浏览器，验证止步于「编译通过」，甚至「看起来对」 | ✅ 每个任务在 golden 镜像容器里起全栈：浏览器复现、分层测试、修完复验，以运行结果为准 |
| 凭证边界 | ❌ 全部凭证集中在个人开发机上，泄露面就是整个工作环境 | ❌ agent 与人共用环境，git/gh token 就在手边，一句幻觉命令就能推错地方 | ✅ 任务容器零凭证，agent 无 git 权限，所有写操作经宿主侧守卫脚本 |
| GitHub 写操作 | ❌ 没有队列、重试和幂等，漏发漏回没有兜底 | ❌ agent 直接调 gh，失败即丢；重试又可能重复评论、重复开 PR | ✅ 写操作先落盘进 outbox，带重试和依赖链执行；建 PR 幂等不会开出第二个，评论带幂等键不会发重 |
| 出错边界 | ❌ 没有守卫，误操作直接落到仓库上 | ❌ 没有护栏，破坏力随交出去的权限线性放大 | ✅ 硬守卫直接拒绝：推送只限线池 worktree、只推 fork、永不碰基线分支 |
| 并行 | ❌ 同一时刻只能处理一个 bug | ❌ 多开窗口共用同一环境，端口、分支、登录态互相打架 | ✅ `hfv scale <line> <n>` 一条命令扩容，per-instance 锁加取模分片，互不踩踏 |
| 经验 | ❌ 经验只存在人脑里，流程不保留也不传递 | ❌ 会话结束即遗忘，同样的坑下次重犯 | ✅ 教训进滚动 playbook，效果引擎按「后来省了几轮迭代」排位，失效自动清除 |
| …… | …… | …… | …… |

## 架构

```
feishu group ──┐
               │   recorder (timer): attachments downloaded,
github issues ─┘   screenshots/recordings transcribed to text
               │
               ▼
         issues store
               │
               ▼
   issue / feat lines ──► throwaway containers (golden image:
               │           full stack, browser repro, tiered tests)
               ▼
         staging dir ──► host-side delivery
               │           (backup ref, ownership check, hard guards)
               ▼
         gh-outbox ──► gh-recorder ──► GitHub
        (disk queue,     │ every minute; the only
         retries + dep   │ GitHub caller
         chains)         ▼
              gh-store (local PR snapshots:
              meta, comments, CI, review states)
                         │
                         ▼
      review / rebase / ci / follow / audit lines
```

systemd 用户级 timer 驱动各条线，线之间互不依赖。gh-recorder 每分钟跑一趟，是唯一访问 GitHub 的组件，一趟做两件事：排空 outbox 里的写操作；把所有在跟踪的 PR 刷成本地快照——meta、三通道对齐的完整评论清单、评审状态、CI 桶，评论里的图片附件同样下载转写。线脚本和容器只读快照，不碰 GitHub。

日常回收：任务 worktree 池 48 小时清一次壳；闲置超过一小时的 per-PR 服务组自动停机，卷保留，下轮热启动。ClickHouse 收指标（cline.runs 系列表，90 天 TTL）和 PR 归宿（cline.prs：每个 issue 产出的 PR 是否被合并、GitHub 对话数量，按变迁逐行记录、无 TTL），`hfv ps` / `hfv log` / `hfv follow` 看实时任务视图。

## 安装

前置要求：

- Linux + systemd 用户会话
- Docker
- Node 22+、Python 3.11+、uv
- Google Chrome
- 一个桌面会话（lark-mcp 的加密 token 存储依赖 D-Bus Secret Service）

```bash
git clone <this-repo> ~/hands-free-vibe && cd ~/hands-free-vibe
bash install.sh
```

install.sh 依次做这些事：检查前置；安装 cline CLI；从官方 npm registry 安装 MCP 工具，并生成固定桌面会话环境的 wrapper；从模板生成站点配置；构建 `hfv-task:base` 镜像；安装 systemd 单元。脚本幂等，重复执行安全；`--check` 只校验不改动。

首次 golden 引导：起一个一次性容器，在容器里跑 `ragflow-up.sh` 拉起服务栈，浏览器登录一次，然后 `docker commit <容器> hfv-task:latest`。golden 此后冻结——任务运行不会回写镜像，更新就走一遍手动引导。

站点配置（全部 gitignore，不进仓库）：`hfv.conf` 由 `hfv.conf.example` 复制，`issues/config` 由 `issues/config.example` 复制，`model-keys.json` 放 LLM key。

## 日常

```bash
hfv on                    # 启用所有线（各 1 实例）
hfv scale issue 2         # issue 线开 2 个并行实例
hfv ps                    # 任务视图：每条线的每个实例在干什么
hfv log / hfv follow      # 看日志（默认第一个运行中的任务）
hfv run [n]               # 立刻触发一次 issue 运行
hfv stop                  # 全部停掉（含容器）
```

## 适用边界

它为「一个仓库 + 一个飞书群」而建，不为通用场景设计。仓库路径、GitHub 身份、merge owner、飞书凭证这类站点配置全部 gitignore，模板在 `hfv.conf.example` 和 `issues/config.example`。

## License

[MIT](LICENSE)
