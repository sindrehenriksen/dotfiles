---
name: confluence
description: 'Fetch and summarize Confluence pages via REST API. USE FOR: confluence page, confluence URL, read confluence, summarize confluence, confluence search. DO NOT USE FOR: editing confluence pages, Jira queries.'
---

<!-- Claude Code counterpart: .claude/agents/confluence.md — keep in sync -->

# Confluence Query

> **Why this skill exists:** The Atlassian MCP server does not work reliably for
> Confluence (auth/VPN issues). Always use this curl-based skill for Confluence
> queries — never the MCP `confluence_*` tools. The MCP works fine for Jira.

Query Confluence pages using the REST API via curl. `CONFLUENCE_URL` and `CONFLUENCE_PERSONAL_TOKEN` are available as environment variables.

## Input Handling

The user may provide:
- A full Confluence URL (e.g., `https://confluence.visma.com/display/SPACE/Page+Title` or `.../pages/123456/...`)
- A page ID
- A space key and title
- A search query

## URL Parsing

Extract page info from common Confluence URL formats:
- `/display/{spaceKey}/{title}` — use spaceKey + title lookup
- `/pages/viewpage.action?pageId={id}` — use page ID lookup
- `/spaces/{spaceKey}/pages/{id}/{title}` — use page ID lookup

## API Calls

```sh
# By page ID:
curl -s -H "Authorization: Bearer $CONFLUENCE_PERSONAL_TOKEN" \
  "$CONFLUENCE_URL/rest/api/content/{id}?expand=body.storage,space,version,children.page"
# By space + title:
curl -s -H "Authorization: Bearer $CONFLUENCE_PERSONAL_TOKEN" \
  "$CONFLUENCE_URL/rest/api/content?spaceKey={space}&title={title}&expand=body.storage,space,version,children.page"
# Search by CQL:
curl -s -H "Authorization: Bearer $CONFLUENCE_PERSONAL_TOKEN" \
  "$CONFLUENCE_URL/rest/api/search?cql={cql}&limit={limit}"
```

## Processing

1. Parse the JSON response with `python3 -c` or `jq`
2. The page body is in Confluence storage format (XML/HTML). Strip tags to extract text, but preserve structure:
   - Convert `<h1>`–`<h6>` to markdown headings
   - Convert `<li>` to bullet points
   - Convert `<a href="...">` to markdown links
   - Convert `<ac:link>` with `ri:content-title` to page title references
   - Strip remaining tags
3. Present a concise summary unless the user asks for the full content
4. If the page links to subpages (via `children.page` or inline links), mention them so the user can ask to dive deeper

## Child Pages

To list child pages:
```sh
curl -s -H "Authorization: Bearer $CONFLUENCE_PERSONAL_TOKEN" \
  "$CONFLUENCE_URL/rest/api/content/{id}/child/page?limit=25"
```

## Error Handling

- 302 redirect to login/OAuth: VPN is likely not connected — suggest the user connect to VPN
- 401: Token may be expired — suggest the user regenerate their PAT in Confluence
- 404: Page not found or no permission
- If env vars are missing, tell the user to check their shell config
