# config.sh — hands-free-vibe 站点配置的 bash 加载器。
# 默认值在此定义；仓库根目录的 hfv.conf（gitignored）逐项覆盖。
# 用法：source "$DIR/config.sh"（DIR 为仓库根）。
HFV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RAGFLOW_MAIN="${RAGFLOW_MAIN:-}"
# PR review/rebase/audit 线的 worktree 池直接建在 RAGFLOW_MAIN 下，靠锁 +
# 路径命名空间隔离（wt/review-<n>、wt/rebase-<n>、wt/audit-<n>、wt/manual-<n>）。
RAGFLOW_CI_CLONE="${RAGFLOW_CI_CLONE:-}"
CLINE_BIN="${CLINE_BIN:-$HOME/.npm-global/bin/cline}"
# host 上的 ClickHouse（run metrics / tasks 簿记；容器内经 socat 转发到同名端口）
CLICKHOUSE_HTTP="${CLICKHOUSE_HTTP:-http://127.0.0.1:8123/}"
GITHUB_REPO="${GITHUB_REPO:-}"
FORK_REMOTE="${FORK_REMOTE:-}"
OWN_LOGIN="${OWN_LOGIN:-}"
# 合并负责人：PR 交付的默认 reviewer、停滞催办与"可以合并"报告的接收人。
MERGE_OWNER_LOGIN="${MERGE_OWNER_LOGIN:-}"
PR_BASE="${PR_BASE:-main}"
PR_LABEL="${PR_LABEL:-ci}"
PR_REVIEWER="${PR_REVIEWER:-$MERGE_OWNER_LOGIN}"
# 自己在飞书的 user_id（claim/开始通知里的自我 @；空则发纯文本）
SELF_FEISHU_USER_ID="${SELF_FEISHU_USER_ID:-}"
MAIN_MAX_SECONDS="${MAIN_MAX_SECONDS:-7200}"
QUOTA_RETRY_SECONDS="${QUOTA_RETRY_SECONDS:-1800}"
QUOTA_MAX_WAIT_SECONDS="${QUOTA_MAX_WAIT_SECONDS:-21600}"
TRANSIENT_RETRY_SECONDS="${TRANSIENT_RETRY_SECONDS:-120}"
TRANSIENT_MAX_WAIT_SECONDS="${TRANSIENT_MAX_WAIT_SECONDS:-1800}"

# ---- 其它失败（CLI bug / session 丢失 / 崩溃）：也重跑，不轻易放弃 ----
OTHER_RETRY_SECONDS="${OTHER_RETRY_SECONDS:-240}"
OTHER_MAX_WAIT_SECONDS="${OTHER_MAX_WAIT_SECONDS:-720}"
STALLED_AGE_HOURS="${STALLED_AGE_HOURS:-12}"
REBASE_FIX_COOLDOWN_HOURS="${REBASE_FIX_COOLDOWN_HOURS:-4}"
# ---- pr-ci 线（CI 失败自动修复）----
CI_FIX_COOLDOWN_MINUTES="${CI_FIX_COOLDOWN_MINUTES:-90}"  # 同一 PR 两次修复的最小间隔
CI_FIX_MAX_ATTEMPTS="${CI_FIX_MAX_ATTEMPTS:-2}"           # 同一 head sha 最多修几次
CI_FIX_MAX_PER_DAY="${CI_FIX_MAX_PER_DAY:-3}"             # 同一 PR 每自然日最多修几次
BLAME_MAX_REVIEWERS="${BLAME_MAX_REVIEWERS:-1}"           # 交付时 blame 推荐的额外 reviewer 上限（合并负责人固定另算）
BLAME_REVIEWER_EXCLUDE="${BLAME_REVIEWER_EXCLUDE:-}"  # 永不自动请求为 reviewer 的人（逗号分隔）
WORK_START="${WORK_START:-09:30}"
WORK_END="${WORK_END:-20:00}"

# ---- 总结系统（树归并）----
LESSONS_PER_TASK="${LESSONS_PER_TASK:-4}"
TREE_FINAL_COUNT="${TREE_FINAL_COUNT:-16}"
SUMMARIZE_SECONDS="${SUMMARIZE_SECONDS:-900}"
GOLDEN_HIT_RATE="${GOLDEN_HIT_RATE:-0.6}"
GOLDEN_MIN_OPPS="${GOLDEN_MIN_OPPS:-4}"
FUSE_SIM="${FUSE_SIM:-0.6}"
FUSE_COOCC="${FUSE_COOCC:-3}"

# 显式传入的 RAGFLOW_MAIN 优先于站点钉值：pr-e2e.sh exec 用
# -e RAGFLOW_MAIN=<PR worktree> 把容器内的 ragflow-up.sh/build.sh 指向该 PR
# 的 worktree；若 hfv.conf 无条件覆盖，容器里起的就是 ragflow4 的代码。
# 未显式传入时 hfv.conf 行为完全不变。
_RAGFLOW_MAIN_ENV="${RAGFLOW_MAIN:-}"
[[ -f "$HFV_DIR/hfv.conf" ]] && source "$HFV_DIR/hfv.conf"
[[ -n "$_RAGFLOW_MAIN_ENV" ]] && RAGFLOW_MAIN="$_RAGFLOW_MAIN_ENV"
unset _RAGFLOW_MAIN_ENV

# ---- 任务容器（随起随用）----
# 每个任务从 golden 镜像 hfv-task:latest 起一个一次性容器
# （lines/run-container.sh），干净退出时 docker commit 回滚 golden——账号、
# default model、数据集、chrome 登录态全部经镜像层保留。
# HFV_SLOT 由 systemd 模板实例传入（cline-feishu-triage@<n>，并经
# run-container.sh 继承进容器），驱动 per-instance 的锁/current/deliver
# 命名；未传入时为空 = 单任务命名（run.lock / current.json / deliver）。
# RAGFLOW_MAIN 由 run-container.sh 按任务 worktree 经 -e 显式传入（见上文
# env 优先逻辑）。
HFV_SLOT="${HFV_SLOT:-}"
HFV_SUF="${HFV_SLOT:+-s$HFV_SLOT}"
RAGFLOW_HOST_REPO="$RAGFLOW_MAIN"
