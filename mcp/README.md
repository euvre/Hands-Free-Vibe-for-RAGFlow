# mcp/ — MCP server toolbelt

The daemon's LLM tasks use these MCP servers (configured in cline's
`~/.cline/data/settings/cline_mcp_settings.json`):

| Package | Installed by | Entry point |
|---|---|---|
| `@larksuiteoapi/lark-mcp` | `npm install -g @larksuiteoapi/lark-mcp` (official registry) | `dist/cli.js` |
| `chrome-devtools-mcp` | `npm install -g chrome-devtools-mcp` (official registry) | `build/src/bin/chrome-devtools-mcp.js` |
| `@modelcontextprotocol/server-filesystem` | `npx -y @modelcontextprotocol/server-filesystem` (no install needed) | — |

`install.sh` does all three, then installs the wrappers below.

## Wrappers (mcp/wrappers/ → ~/bin/)

Host-side launchers that pin a working desktop env (DISPLAY / DBUS /
XAUTHORITY) — lark-mcp's encrypted token store dies without them, and MCP
hosts spawn servers without the desktop session env. `install.sh` renders the
templates for your `$HOME` into `~/bin/`; point the cline MCP settings at the
wrapped paths:

- `lark-mcp-wrapper.sh` — invoked as `mcp -a <APP_ID> -s <APP_SECRET> …`
  (credentials come from `issues/config`, never from this repo)
- `chrome-devtools-mcp-wrapper.sh` — no args; adds `-e <chrome binary>`

## cline_mcp_settings.json sketch

```json
{
  "mcpServers": {
    "lark-mcp":        { "command": "~/bin/lark-mcp-wrapper.sh",
                         "args": ["mcp", "-a", "<APP_ID>", "-s", "<APP_SECRET>", "-u", "oauth"] },
    "chrome-devtools": { "command": "~/bin/chrome-devtools-mcp-wrapper.sh", "args": [] },
    "filesystem":      { "command": "npx",
                         "args": ["-y", "@modelcontextprotocol/server-filesystem", "<repo roots>"] }
  }
}
```
