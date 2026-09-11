# Team mapping task (one-shot)

Your job: build `team-map.json` at the repo root, a mapping between team
members' Feishu identities and their GitHub accounts, by scanning the Feishu
group and public GitHub information. This file is gitignored and will
afterwards be consumed by `tools/feishu-dm.py` (read it for the exact expected
JSON shape):

```json
{
  "members": [
    {"github": "<github-login>", "feishu": "<feishu open_id (ou_...)>", "name": "<display name>"}
  ],
  "owner": "<the merge owner's feishu open_id>"
}
```

Steps:
1. Use the lark-mcp tools (already configured) to list the members of the
   target group (`im_v1_chatMembers_get` with the chat_id from
   `issues/config`). For each member, record the open_id and name.
2. For each member, find their GitHub account. Cross-reference in this order:
   a. their Feishu profile / description fields if exposed;
   b. git commit history in the main clone (`hfv.conf`: RAGFLOW_MAIN) —
      `git log --format='%an %ae'` over recent history gives author
      name/email pairs; match by name similarity;
   c. the repo's PR/review activity: reviewers who reviewed our PRs
      (`gh pr view <N> --json reviews` across our open PRs) — active reviewer
      logins are exactly the people we need mapped.
3. The merge owner (GitHub login in `hfv.conf`: MERGE_OWNER_LOGIN) must be
   mapped and put into the top-level "owner" field — they receive the
   ready-to-merge reports.
4. Only include members you can map with reasonable confidence; skip
   bots (coderabbitai, github-actions, …) and our own fork account
   (`hfv.conf`: OWN_LOGIN).
5. Write the JSON atomically (write to team-map.json.tmp then rename) and
   validate it parses (`python3 -m json.tool`).

Rules:
- Read-only on Feishu: list members only. Do NOT send any message.
- No secrets in the output file (open_ids are fine, they are not secrets).
- If a member's GitHub cannot be determined, omit them rather than guess.
