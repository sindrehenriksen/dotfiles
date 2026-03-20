#!/bin/sh
# Visma-specific setup — MCP servers, credentials, and tooling

#### MCP servers

# Aikido Security (https://github.com/visma-prodsec/aikido-mcp)
mkdir -p ~/dev/tools
git clone https://github.com/visma-prodsec/aikido-mcp.git ~/dev/tools/aikido-mcp
cd ~/dev/tools/aikido-mcp && npm install && npm run build && cd -
# Get API credentials (Private App, scopes: basics:read, issues:read, repositories:read):
#   https://app.aikido.dev/settings/integrations/api/aikido/rest

# Jira/Atlassian MCP (mcp-atlassian, via uvx — no install needed)
# Get a personal access token from your Jira profile

#### MCP config locations
# Both Claude Desktop and VS Code need MCP server entries with credentials.
#
# Claude Desktop: ~/Library/Application Support/Claude/claude_desktop_config.json
#   "mcpServers": {
#     "aikido": {
#       "command": "node",
#       "args": ["~/dev/tools/aikido-mcp/dist/index.js"],
#       "env": { "AIKIDO_CLIENT_ID": "...", "AIKIDO_API_KEY": "..." }
#     },
#     "jira": {
#       "command": "uvx",
#       "args": ["mcp-atlassian"],
#       "env": { "JIRA_URL": "https://jira.visma.com", "JIRA_PERSONAL_TOKEN": "..." }
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
#     "jira": {
#       "type": "stdio",
#       "command": "uvx",
#       "args": ["mcp-atlassian"],
#       "env": { "JIRA_URL": "https://jira.visma.com", "JIRA_PERSONAL_TOKEN": "..." }
#     }
#   }
