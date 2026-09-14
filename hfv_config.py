#!/usr/bin/env python3
"""hfv_config.py — hands-free-vibe 站点配置的 python 加载器（与 config.sh 同默认值）。
仓库根目录的 hfv.conf（gitignored，KEY=VALUE）逐项覆盖；$HOME/~ 会被展开。
用法：from hfv_config import load; cfg = load(); cfg['GITHUB_REPO'] ...
"""
import os

DIR = os.path.dirname(os.path.abspath(__file__))
_HOME = os.path.expanduser("~")

DEFAULTS = {
    # PR review/rebase/audit 线共用 RAGFLOW_MAIN 的 worktree 池（ragflow2/3 已去除）
    "RAGFLOW_MAIN": "",
    "RAGFLOW_CI_CLONE": "",
    "CLINE_BIN": "$HOME/.npm-global/bin/cline",
    "CLICKHOUSE_HTTP": "http://127.0.0.1:8123/",
    "GITHUB_REPO": "",
    "FORK_REMOTE": "",
    "OWN_LOGIN": "",
    "MERGE_OWNER_LOGIN": "",
    "SELF_FEISHU_USER_ID": "",
    "PR_BASE": "main",
    "PR_LABEL": "ci",
    "PR_REVIEWER": "",
    "MAIN_MAX_SECONDS": "7200",
    "QUOTA_RETRY_SECONDS": "1800",
    "QUOTA_MAX_WAIT_SECONDS": "21600",
    "TRANSIENT_RETRY_SECONDS": "120",
    "TRANSIENT_MAX_WAIT_SECONDS": "1800",
    "OTHER_RETRY_SECONDS": "240",
    "OTHER_MAX_WAIT_SECONDS": "720",
    "STALLED_AGE_HOURS": "12",
    "REBASE_FIX_COOLDOWN_HOURS": "4",
    "CI_FIX_COOLDOWN_MINUTES": "90",
    "CI_FIX_MAX_ATTEMPTS": "2",
    "CI_FIX_MAX_PER_DAY": "3",
    "BLAME_MAX_REVIEWERS": "1",
    "BLAME_REVIEWER_EXCLUDE": "",
    "WORK_START": "09:30",
    "WORK_END": "20:00",
    "LESSONS_PER_TASK": "4",
    "TREE_FINAL_COUNT": "16",
    "SUMMARIZE_SECONDS": "900",
    "GOLDEN_HIT_RATE": "0.6",
    "GOLDEN_MIN_OPPS": "4",
    "FUSE_SIM": "0.6",
    "FUSE_COOCC": "3",
}


def load():
    cfg = dict(DEFAULTS)
    p = os.path.join(DIR, "hfv.conf")
    if os.path.exists(p):
        for line in open(p):
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                v = v.split("#", 1)[0].strip().strip('"')  # 剥行内注释
                cfg[k.strip()] = v
    for k, v in cfg.items():
        cfg[k] = os.path.expanduser(v.replace("$HOME", _HOME))
    cfg["PR_REVIEWER"] = cfg["PR_REVIEWER"] or cfg["MERGE_OWNER_LOGIN"]
    return cfg


if __name__ == "__main__":
    import json
    print(json.dumps(load(), indent=1, ensure_ascii=False))
