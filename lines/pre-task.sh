#!/usr/bin/env bash
# pre 组：任务启动前按序执行的准备类作业。
# 新增 pre 作业时在此追加一行；单项失败不阻塞后续与主任务。
set -u
DIR="$(cd "$(dirname "$0")/.." && pwd)"  # repo root (this script lives in lines/)

# 0. 上一轮收尾补偿：daemon/主机在 run 中途死亡时整个 post 组缺失 ——
#    .quota-dead 没被 demote 抵消（select_count 白烧，issue 无谓逼近
#    MAX_PICKS 终态）、in-flight 标记悬死、task 永远卡 running。三种残留任一
#    存在即触发：.quota-dead（配额放弃后 demote 未跑）、.last-run-info
#    （run 已启动但 close 未跑）、.current（死在 assign 与 run 启动之间）。
#    仅当本槽位锁空闲（上一 run 确已结束、不是仍存活的遗留容器）时补跑。
SUF=""
[[ -n "${HFV_SLOT:-}" ]] && SUF="-s$HFV_SLOT"
if [[ -f "$DIR/logs/.quota-dead$SUF" || -f "$DIR/tasks/.last-run-info$SUF" || -f "$DIR/tasks/.current$SUF" ]]; then
  if flock -n "$DIR/locks/run$SUF.lock" true 2>/dev/null; then
    if [[ -f "$DIR/logs/.quota-dead$SUF" ]]; then
      python3 "$DIR/issues/issue-quota-demote.py" || true
      rm -f "$DIR/logs/.quota-dead$SUF"
      echo "[$(date +%Y%m%d-%H%M%S)] pre-task: reconciled leftover .quota-dead$SUF (pick un-counted, issue demoted)" >> "$DIR/logs/daemon.log"
    fi
    if [[ -f "$DIR/tasks/.last-run-info$SUF" || -f "$DIR/tasks/.current$SUF" ]]; then
      python3 "$DIR/issues/issue-release.py" || true
      python3 "$DIR/tools/tasks.py" close || true
      # close() no-ops when .current is already gone — drop any leftovers
      # explicitly so this reconcile converges instead of re-firing forever.
      rm -f "$DIR/tasks/.last-run-info$SUF" "$DIR/tasks/.current$SUF"
      echo "[$(date +%Y%m%d-%H%M%S)] pre-task: reconciled unfinished run (in-flight marker released, task closed)" >> "$DIR/logs/daemon.log"
    fi
  fi
fi
# 并行槽位下，第 1 步（飞书扫描）只在主槽（slot 1）与 legacy 路径执行，避免
# 多个槽位重复扫描同一飞书群、双倍消耗 API 配额；3 及之后的步骤是每槽位
# 自己的事，全部照常执行。
if [[ -z "${HFV_SLOT:-}" || "${HFV_SLOT:-}" == "1" ]]; then
  # 1. 刷新 issue 列表（增量记录新 issue，末尾清理超窗项）
  bash "$DIR/issues/issue-recorder.sh" || true
fi

# 2. glm 档案下用 kimi 把新截图转写为同名 .md 描述（供纯文本主体模型消费）。
#    每个槽位都跑：第 1 步只在主槽执行，若其余槽位跳过本步，它们可能在
#    recorder 下图与主槽 vision 完成之间的窗口选中带图 issue（.md 尚不
#    存在），主体会按"无截图"处理。转写幂等（.md 已新于图即跳过，不耗
#    API）；flock 防两槽同时转写同一张新图。
#    5 分钟整体上限：防止单个卡死的 vision 调用拖住整个 pre 组（SIGALRM
#    within issue-vision.py 兜底单次调用）；输出落 logs/vision.log 供排查。
if [[ "$(python3 "$DIR/tools/model-profile.py" current 2>/dev/null)" == "glm" ]]; then
  (
    flock -w 300 9 || exit 0
    timeout 300 python3 "$DIR/issues/issue-vision.py" >> "$DIR/logs/vision.log" 2>&1 || true
  ) 9>"$DIR/locks/.vision.lock"
fi

# 3. 选定本轮要处理的 open issue 并落盘 current.json（无 open 项则不产出，
#    run-task 据此直接休息，不启动 LLM）。消费 tasks/.pin（resume/follow 时
#    以 pin 的 task 快照覆盖常规选择）
bash "$DIR/issues/issue-select.sh" || true
# 3.5 为本轮 run 分配递增 task 编号（tasks/tasks.jsonl + ClickHouse cline.tasks，
#     快照存 tasks/<id>/issue.json），并把 task_id 写回 current.json
python3 "$DIR/tools/tasks.py" assign || true

# 4. 发送模板认领回复（纯脚本无 LLM，幂等：每条记录生命周期内只认领一次），
#    claim_reply_id 写回 issues.jsonl 记录并镜像到 current.json，供后续 recall
bash "$DIR/lines/pre-claim.sh" || true

# 4.5 宣告任务开始执行（claim 之后、run 之前；此后的 @接管 不再生效）。
#    每条 issue 生命周期内只发一次（start_notice_id 持久化），重选不重复。
#    注意用本脚本顶部定义的 SUF（-s<N> 后缀）——写成未定义的 HFV_SUF 会让
#    路径恒为 current.json（不存在），start notice 静默空转从未发出。
python3 "$DIR/issues/issue-start-notice.py" "$DIR/issues/current${SUF}.json" >> "$DIR/logs/daemon.log" 2>&1 || true

# 5. 清理工作区并同步到最新 main（快照残留 → 硬重置 → 清暂存区/工作区；
#    在役运行持 run.lock 时自动跳过，详见 pre-clean-worktree.sh 头注释）
bash "$DIR/lines/pre-clean-worktree.sh" || true
