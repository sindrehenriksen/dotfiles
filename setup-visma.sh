#!/bin/sh
# Visma-specific setup — MCP servers, credentials, and tooling

#### MCP servers

# Aikido Security (https://github.com/visma-prodsec/aikido-mcp)
mkdir -p ~/dev/tools
git clone https://github.com/visma-prodsec/aikido-mcp.git ~/dev/tools/aikido-mcp
cd ~/dev/tools/aikido-mcp && npm install && npm run build && cd -
# Get API credentials (Private App, scopes: basics:read, issues:read, repositories:read):
#   https://app.aikido.dev/settings/integrations/api/aikido/rest

