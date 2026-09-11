#!/usr/bin/env bash
# post 组：任务结束后按序执行的收尾类作业。
# 新增 post 作业时在此追加一行；单项失败不影响后续作业。
set -u
DIR="$(cd "$(dirname "$0")/.." && pwd)"  # repo root (this script lives in lines/)
SUF=""
[[ -n "${HFV_SLOT:-}" ]] && SUF="-s$HFV_SLOT"

# run-task rested this tick (no issue to process, no LLM run happened):
# post jobs are pointless here — consume the marker and skip entirely.
# (The PR follow-up is no longer part of this group: it runs on its own
# cline-feishu-pr-follow.timer, which covers rested ticks too.)
if [[ -f "$DIR/logs/.rested$SUF" ]]; then
  rm -f "$DIR/logs/.rested$SUF"
  echo "post-task: skipped (tick rested, no run)" >> "$DIR/logs/daemon.log"
  exit 0
fi

# 1. 发送主任务暂存的回复（纯脚本无 LLM）：主任务把回复文本写入
#    deliver/reply-<message_id>.md，本步骤代替它发送（先于 PR 通知；
#    主任务内禁止直接调用任何消息发送脚本/API）
bash "$DIR/lines/post-reply.sh" || true

# 2. 交付 + 完结回复（纯脚本无 LLM）：调 issue-deliver.sh 创建 PR，
#    回复 PR 链接到原话题。deliver/ 文件缺失时自动跳过（主任务未到交付步）。
bash "$DIR/lines/post-deliver.sh" || true

# 3. issue 状态同步（纯规则无 LLM）：第三方认领/发 PR → 删除记录（并发
#    "我现在放弃该任务。"回复）；我方话题回复含 PR → done；消息消失 → 删除记录
bash "$DIR/issues/issue-sync.sh" || true

# 4. 总结本轮 run 的可复用经验，写入 playbook.md 滚动区
bash "$DIR/lines/summarize-run.sh" || true

# 5. 释放本槽位在 issues.jsonl 上的 in-flight 标记（并行槽位防重复领取；
#    host 路径清 "host" 标记，与槽位同理）
python3 "$DIR/issues/issue-release.py" || true

# 6. 配额性放弃的降级（纯脚本无 LLM）：run-task.sh 在配额重试预算耗尽而放弃
#    时落下 .quota-dead 标记——配额枯竭是基础设施的锅，不是 issue 本身的：
#    撤销本轮 pick 计数并将 priority_penalty +1（issue-select 排序降一等），
#    issue 保持 open，配额恢复后由降级队列自然领回，绝不烧向终态 fail。
if [[ -f "$DIR/logs/.quota-dead$SUF" ]]; then
  rm -f "$DIR/logs/.quota-dead$SUF"
  python3 "$DIR/issues/issue-quota-demote.py" || true
fi

# 7. 收口 task 编号（status/exit/log/pr 写回 tasks.jsonl 与 ClickHouse）
python3 "$DIR/tools/tasks.py" close || true
