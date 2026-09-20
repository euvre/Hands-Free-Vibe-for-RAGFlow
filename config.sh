# config.sh — hands-free-vibe 站点配置的 bash 加载器。
# 默认值在此定义；仓库根目录的 hfv.conf（gitignored）逐项覆盖。
# 用法：source "$DIR/config.sh"（DIR 为仓库根）。
HFV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RAGFLOW_MAIN="${RAGFLOW_MAIN:-}"
# PR review/rebase/audit/ci 线的 worktree 池直接建在 RAGFLOW_MAIN 下，靠锁 +
# 路径命名空间隔离（wt/review-<n>、wt/rebase-<n>、wt/audit-<n>、wt/ci-<n>、wt/manual-<n>）。
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

# ---- 总结系统（leaf 归并 → playbook-effect 八宫引擎）----
LESSONS_PER_TASK="${LESSONS_PER_TASK:-4}"
SUMMARIZE_SECONDS="${SUMMARIZE_SECONDS:-900}"

# ---- bug 扫描线（scan）：中间区段文件审计 → 复现 → 群报告 → 修复交付 ----
# 窗口：排除最新 SCAN_NEW_EXCLUDE_DAYS 天内改动的文件，排除最老
# SCAN_OLD_PCT 分位之外的文件；中间区段按日历月分桶，UCB1 选批次。
# 动态调整（SCAN_DYNAMIC=1）：连续 SCAN_ZERO_HIT_EXPAND 轮零命中 → 窗口扩张
# 一档（new_days-7 下限 3、old_pct+5 上限 95）；候选池近枯竭时 select 内联
# 扩张一次。hfv scan window --set 钉住后动态调整停用（--auto 恢复）。
SCAN_NEW_EXCLUDE_DAYS="${SCAN_NEW_EXCLUDE_DAYS:-14}"
SCAN_OLD_PCT="${SCAN_OLD_PCT:-85}"
SCAN_BATCH_SIZE="${SCAN_BATCH_SIZE:-10}"
SCAN_DYNAMIC="${SCAN_DYNAMIC:-1}"
SCAN_ZERO_HIT_EXPAND="${SCAN_ZERO_HIT_EXPAND:-3}"
# 源码扩展名白名单与路径排除（逗号分隔；前缀以 / 结尾，其余为子串）
SCAN_EXTS="${SCAN_EXTS:-.py,.go,.ts,.tsx,.js,.jsx,.mjs,.cjs}"
SCAN_EXCLUDE="${SCAN_EXCLUDE:-}"   # 空 = scan-select.py 内置默认

# 显式传入的 RAGFLOW_MAIN 优先于站点钉值：run-container.sh 用
# -e RAGFLOW_MAIN=<PR worktree> 把容器内的 ragflow-up.sh/build.sh 指向该 PR
# 的 worktree；若 hfv.conf 无条件覆盖，容器里起的就是 ragflow4 的代码。
# 未显式传入时 hfv.conf 行为完全不变。
_RAGFLOW_MAIN_ENV="${RAGFLOW_MAIN:-}"
[[ -f "$HFV_DIR/hfv.conf" ]] && source "$HFV_DIR/hfv.conf"
[[ -n "$_RAGFLOW_MAIN_ENV" ]] && RAGFLOW_MAIN="$_RAGFLOW_MAIN_ENV"
unset _RAGFLOW_MAIN_ENV

# ---- 任务容器（随起随用）----
# 每个任务从 golden 镜像 hfv-task:latest 起一个一次性容器
# （lines/run-container.sh）。golden 是冻结的并行基底：容器纯弃置，
# 不做 commit 回写；账号/数据集/chrome 登录态冻结在镜像里，
# 更新须走 install.sh 的人工 bootstrap。
# HFV_SLOT 由 systemd 模板实例传入（cline-feishu-triage@<n>，并经
# run-container.sh 继承进容器），驱动 per-instance 的锁/current/deliver
# 命名；未传入时为空 = 单任务命名（run.lock / current.json / deliver）。
# RAGFLOW_MAIN 由 run-container.sh 按任务 worktree 经 -e 显式传入（见上文
# env 优先逻辑）。
HFV_SLOT="${HFV_SLOT:-}"
HFV_SUF="${HFV_SLOT:+-s$HFV_SLOT}"
RAGFLOW_HOST_REPO="$RAGFLOW_MAIN"

# ---- 提示词多版本 ----
# prompts/<base>.md 是默认版本；prompts/<base>@<variant>.md 是变体。
# hfv.conf 用 PROMPT_VARIANT_<BASE大写、连字符转下划线> 选定变体
# （如 PROMPT_VARIANT_PR_AUDIT_TASK=dual-check）；未设置或文件不存在时回落默认。
# 命令行侧：hfv prompt list / show / use。
resolve_prompt() { # <base> → 打印该提示词当前应使用的文件（绝对路径）
  local base="$1" key var
  key="PROMPT_VARIANT_$(tr 'a-z-' 'A-Z_' <<<"$base")"
  var="${!key:-}"
  if [[ -n "$var" && -f "$HFV_DIR/prompts/$base@$var.md" ]]; then
    printf '%s' "$HFV_DIR/prompts/$base@$var.md"
  else
    printf '%s' "$HFV_DIR/prompts/$base.md"
  fi
}
