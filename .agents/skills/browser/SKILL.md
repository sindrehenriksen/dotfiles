---
name: browser
description: 'Automate browser interactions using agent-browser CLI. USE FOR: web scraping, form filling, UI testing, screenshots, browser automation. DO NOT USE FOR: API calls, curl requests, non-browser tasks.'
argument-hint: 'what to do in the browser (e.g. "go to example.com and take a screenshot")'
allowed-tools: Bash, Read
---

# Browser Automation — agent-browser

Use the `agent-browser` CLI to automate browser interactions.

## When to Use

- Open a webpage and interact with it (click, fill forms, scrape text)
- Take screenshots or PDFs of web pages
- Automate multi-step browser workflows
- Test a web UI or verify page content
- Scrape or extract data from a website

## Core Workflow

1. **Open** a page: `agent-browser open <url>`
2. **Inspect** the page: `agent-browser snapshot` (returns accessibility tree with `@eN` element refs)
3. **Interact** using element refs from the snapshot: `click @e2`, `fill @e3 "text"`, etc.
4. **Extract** data: `agent-browser get text @e1`, `agent-browser get title`, `agent-browser get url`
5. **Capture** output: `agent-browser screenshot [path]` or `agent-browser pdf <path>`
6. **Close** when done: `agent-browser close`

## Key Principles

- **Always snapshot before interacting.** The snapshot gives you `@eN` element references needed for clicks, fills, and reads. Never guess selectors — use the snapshot.
- **Use `--annotate` screenshots for debugging.** `agent-browser screenshot --annotate` overlays element labels on the screenshot so you can visually verify targets.
- **Wait for dynamic content.** Use `agent-browser wait` commands before interacting with elements that load asynchronously.
- **Close the browser when done.** Always run `agent-browser close` at the end.
- **Handle errors gracefully.** If a command fails, take a snapshot or screenshot to diagnose, then retry with corrected selectors.

## Command Reference

### Navigation & Interaction

```bash
agent-browser open <url>                    # Navigate to URL
agent-browser click <sel>                   # Click element
agent-browser click <sel> --new-tab         # Click, opening in new tab
agent-browser dblclick <sel>                # Double-click
agent-browser fill <sel> "<text>"           # Clear field and fill
agent-browser type <sel> "<text>"           # Type into element (appends)
agent-browser press <key>                   # Press key (Enter, Tab, Control+a)
agent-browser keyboard type "<text>"        # Real keystrokes, no selector
agent-browser hover <sel>                   # Hover over element
agent-browser select <sel> <value>          # Select dropdown option
agent-browser check <sel>                   # Check checkbox
agent-browser uncheck <sel>                 # Uncheck checkbox
agent-browser scroll <dir> [px]            # Scroll (up/down/left/right)
agent-browser drag <src> <tgt>              # Drag and drop
agent-browser upload <sel> <files>          # Upload file(s)
```

### Inspection & Data Extraction

```bash
agent-browser snapshot                      # Accessibility tree with @eN refs
agent-browser screenshot [path]             # Screenshot (default: stdout)
agent-browser screenshot --annotate         # Screenshot with element labels
agent-browser screenshot --full             # Full-page screenshot
agent-browser pdf <path>                    # Save page as PDF
agent-browser get text <sel>                # Get text content
agent-browser get html <sel>                # Get innerHTML
agent-browser get value <sel>               # Get input value
agent-browser get attr <sel> <attr>         # Get attribute
agent-browser get title                     # Page title
agent-browser get url                       # Current URL
agent-browser get count <sel>               # Count matching elements
```

### Semantic Locators (find)

Use when `@eN` refs are insufficient or you need to locate by role/text/label:

```bash
agent-browser find role button click --name "Submit"
agent-browser find text "Sign In" click
agent-browser find label "Email" fill "test@test.com"
agent-browser find placeholder "Search..." fill "query"
agent-browser find testid "login-btn" click
agent-browser find nth 2 "a" text            # Get text of 2nd link
```

### Waiting

```bash
agent-browser wait <selector>               # Wait for element
agent-browser wait <ms>                     # Wait milliseconds
agent-browser wait --text "Welcome"         # Wait for text to appear
agent-browser wait --url "**/dashboard"     # Wait for URL pattern
agent-browser wait --load networkidle       # Wait for network idle
agent-browser wait "#spinner" --state hidden # Wait for element to hide
```

### Tabs

```bash
agent-browser tab                           # List tabs
agent-browser tab new [url]                 # Open new tab
agent-browser tab <n>                       # Switch to tab N
agent-browser tab close [n]                 # Close tab N
```

### Browser Settings

```bash
agent-browser set viewport <w> <h>          # Set viewport size
agent-browser set device "<name>"           # Emulate device
agent-browser set media dark                # Dark mode
agent-browser set offline on                # Go offline
agent-browser set credentials <user> <pass> # HTTP auth
```

### Network Monitoring

```bash
agent-browser network requests              # List captured requests
agent-browser network requests --filter api # Filter by URL pattern
agent-browser network requests --type xhr,fetch
agent-browser network requests --method POST
agent-browser network har start             # Start HAR recording
agent-browser network har stop [output.har] # Stop and save HAR
```

## Safety

- Do not submit real credentials unless the user explicitly provides them for this purpose.
- Do not interact with payment forms or make purchases without explicit user confirmation.
- Close the browser when the task is complete to avoid leaving sessions open.

$ARGUMENTS
