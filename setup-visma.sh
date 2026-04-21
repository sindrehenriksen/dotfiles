#!/bin/sh
# Visma-specific setup — MCP servers, credentials, and tooling

#### MCP servers

# Aikido Security (https://github.com/visma-prodsec/aikido-mcp)
mkdir -p ~/dev/tools
git clone https://github.com/visma-prodsec/aikido-mcp.git ~/dev/tools/aikido-mcp
cd ~/dev/tools/aikido-mcp && npm install && npm run build && cd -
# Get API credentials (Private App, scopes: basics:read, issues:read, repositories:read):
#   https://app.aikido.dev/settings/integrations/api/aikido/rest

# Jira MCP (mcp-atlassian, via uvx — no install needed)
# Confluence MCP tools are intentionally disabled by omitting CONFLUENCE_URL
# and CONFLUENCE_PERSONAL_TOKEN from the MCP env below — the MCP doesn't work
# reliably for Confluence (auth/VPN issues). Use the curl-based skill instead
# (.agents/skills/confluence/), which reads CONFLUENCE_URL and
# CONFLUENCE_PERSONAL_TOKEN from ~/.secrets-visma.env.
# Jira and Confluence need separate PATs — generate each from its own profile.

#### MCP config locations
# Three clients need MCP servers configured. Claude Desktop and VS Code use JSON
# config files; Claude Code CLI uses `claude mcp add` (writes to ~/.claude.json).
#
# Claude Desktop: ~/Library/Application Support/Claude/claude_desktop_config.json
#   "mcpServers": {
#     "aikido": {
#       "command": "node",
#       "args": ["~/dev/tools/aikido-mcp/dist/index.js"],
#       "env": { "AIKIDO_CLIENT_ID": "...", "AIKIDO_API_KEY": "..." }
#     },
#     "atlassian": {
#       "command": "uvx",
#       "args": ["mcp-atlassian"],
#       "env": {
#         "JIRA_URL": "https://jira.visma.com",
#         "JIRA_PERSONAL_TOKEN": "..."
#       }
#     }
#   }
#
# VS Code: ~/Library/Application Support/Code/User/mcp.json
#   "servers": {
#     "aikido": {
#       "type": "stdio",
#       "command": "node",
#       "args": ["~/dev/tools/aikido-mcp/dist/index.js"],
#       "env": { "AIKIDO_CLIENT_ID": "...", "AIKIDO_API_KEY": "..." }
#     },
#     "atlassian": {
#       "type": "stdio",
#       "command": "uvx",
#       "args": ["mcp-atlassian"],
#       "env": {
#         "JIRA_URL": "https://jira.visma.com",
#         "JIRA_PERSONAL_TOKEN": "..."
#       }
#     }
#   }
#
# Claude Code CLI (user-level): registered via `claude-work mcp add`, stored in
# ~/.claude-work/.claude.json. Use `claude-work` (NOT bare `claude`) — the shell
# wrapper in .shellrc routes bare `claude` to the personal account config dir, and
# MCP servers are registered per-account. Visma work uses the work account.
# NOTE: ~/.claude/.mcp.json is for Claude Desktop, NOT Claude Code CLI.
#
#   claude-work mcp add -s user \
#     -e "AIKIDO_CLIENT_ID=..." -e "AIKIDO_API_KEY=..." \
#     -- aikido node ~/dev/tools/aikido-mcp/dist/index.js
#
#   claude-work mcp add -s user \
#     -e "JIRA_URL=https://jira.visma.com" \
#     -e "JIRA_PERSONAL_TOKEN=..." \
#     -- atlassian uvx mcp-atlassian
#
# Verify with: claude-work mcp list
