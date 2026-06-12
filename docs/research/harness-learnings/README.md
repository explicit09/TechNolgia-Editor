# Harness Learnings

Source material on agentic coding harness design, captured for a video editing harness build.

Two files at this level:

- `synthesis.md` — cross-source distillation, opinionated, with specific applications to a video editing harness.
- `sources/*.md` — raw captured posts, one file per source. Each starts with a frontmatter block (URL, author, capture date).

The synthesis is what to read first. The raw sources are there so you can dig into anything that looks important without re-fetching.

## Source index

### Anthropic engineering (the most directly applicable thinking)

| File | What it covers |
| --- | --- |
| `sources/anthropic-context-engineering.md` | Context as a finite "attention budget". Just-in-time retrieval, structured note-taking, sub-agent compaction. Foundational. |
| `sources/anthropic-long-running-harnesses.md` | Two-agent pattern (initializer + coding agent) for tasks that span many context windows. Concrete artifacts: `claude-progress.txt`, `feature_list.json`, `init.sh`. |
| `sources/anthropic-claude-code-best-practices.md` | Practical patterns from internal Anthropic teams: planning mode, slash commands, hooks, subagents, CLAUDE.md hygiene. |
| `sources/anthropic-claude-agent-sdk.md` | Why the SDK is for any long-horizon agent loop, not just coding. Gather-context / take-action / verify. |
| `sources/anthropic-building-effective-agents.md` | Foundational taxonomy: workflows vs. agents, prompt chaining, routing, parallelization, orchestrator-worker, evaluator-optimizer. |
| `sources/anthropic-multi-agent-research-system.md` | Lead-agent + parallel sub-agents. Beat single-agent Opus 4 by ~90% on internal eval. Includes prompt eng + reliability principles. |
| `sources/anthropic-agent-skills.md` | Skills as folders with `SKILL.md` + bundled files. Progressive disclosure (3 levels of loading). Skills can ship deterministic Python. |

### Claude Code docs (concrete reference)

| File | What it covers |
| --- | --- |
| `sources/claude-code-overview.md` | What Claude Code is and how it's structured. |
| `sources/claude-code-subagents.md` | Subagent definition format, tool scoping, when to spawn vs. inline. |
| `sources/claude-code-hooks.md` | Hook events, matchers, security posture, examples. |
| `sources/claude-code-mcp.md` | MCP server config, allowlists, OAuth, managed configurations. |

### Aider (terminal-native pair programmer, lots of design wisdom)

| File | What it covers |
| --- | --- |
| `sources/aider-architect-pattern.md` | Architect/Editor split: reasoning model proposes, editor model applies. SOTA on Aider's bench. |
| `sources/aider-edit-formats.md` | whole / diff / diff-fenced / udiff / editor-* formats; which models prefer which. |
| `sources/aider-modes.md` | `/code`, `/architect`, `/ask`, `/help`, `/context` mode design. |
| `sources/aider-repomap.md` | Tree-sitter-built concise map of classes/signatures fed to the LLM as compressed structural context. |

### Research / open-source agents

| File | What it covers |
| --- | --- |
| `sources/swe-agent-aci.md` | The Agent-Computer Interface concept. Linter on edit, 100-line file viewer, succinct grep, "your command produced no output" nudges. |
| `sources/openhands-overview.md` | Stateless, event-sourced, composable architecture. Four packages (SDK / Tools / Workspace / Server). Immutable components. |

### Cursor (synthesized from public sources — cursor.com is not fetchable)

| File | What it covers |
| --- | --- |
| `sources/cursor-design-notes.md` | Hand-written summary of Cursor's architecture: Tab, Cmd+K, Composer (agent mode), Composer-1 MoE/RL model, shadow workspace, agent worktrees, retrieval. |

## Capture notes

- Captured 2026-05-02.
- All HTML sources were fetched via `mcp__workspace__web_fetch`, parsed with BeautifulSoup + html2text, and stripped of nav/footer chrome.
- Aider docs were extracted from GitHub `/blob/` HTML payloads (the `/raw/` redirect wasn't reachable).
- Cursor's blog is not on the workspace network allowlist; that source was synthesized from external knowledge with the canonical URLs cited inline.
