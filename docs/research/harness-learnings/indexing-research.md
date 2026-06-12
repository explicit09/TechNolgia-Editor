# Codebase Indexing in Coding Harnesses — Research Dump

**Captured:** 2026-05-03
**Purpose:** Capture what coding-agent builders have learned about indexing the codebase, before we design our own video index. No video-specific design proposals here — pure research.

---

## 1. Why this exists

For a coding agent, indexing the codebase is the rate-limiting step on intelligence: the model can only reason about what it sees, the context window is finite, and "what to put in the window" is the single most consequential decision the harness makes. Anthropic's framing is blunt: ["Context, therefore, must be treated as a finite resource with diminishing marginal returns"](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents), and the goal is to find ["the smallest possible set of high-signal tokens"](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents) that yield the right answer.

Every coding harness has had to solve "given a 10M-line repo and a 200k-token budget, what 200k tokens do I show?" The space of answers is wider than it looks. This document captures what each major harness chose, why, and where they've changed their minds.

We expect the analogous bottleneck for a video-editing harness to be footage indexing. Before we propose anything, we want the lessons.

---

## 2. The big shapes

Five recognizable families have emerged. Most production harnesses are hybrids of two or three.

1. **RAG-via-embeddings.** Chunk the repo, embed each chunk, store in a vector DB, retrieve by cosine similarity at query time. Cursor's flagship `@codebase` is the canonical example. Continue.dev is the most architecturally documented OSS version.
2. **Compressed structural map (repomap-style).** Skip embeddings entirely. Parse with tree-sitter, extract the symbol graph, run PageRank, render the top-N definitions as elided source. Aider invented this. Up-front context, no retrieval round-trip.
3. **Native code search.** Lean on a real code-search engine — keyword search, BM25, regex, and a precise-symbol graph (SCIP/LSIF). Sourcegraph Cody Enterprise's path. Effectively: "use the search tool we already built for humans."
4. **Agentic grep.** No index at all. Give the model `glob`, `grep`, `read`, `ls` and let it explore. Claude Code's chosen path. Anthropic calls this ["just-in-time"](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents) retrieval.
5. **Hybrid search.** BM25 + dense embeddings + a re-ranker. Continue.dev's pipeline; also where many production systems land. Reciprocal Rank Fusion is the [common merge function](https://weaviate.io/blog/hybrid-search-explained), and the [reported gain](https://www.minimalistinnovation.co/post/hybrid-search-reciprocal-rank-fusion-lexical-semantic) is roughly "91% recall@10 vs 78% dense-only or 65% sparse-only."

The interesting story is that the field is no longer monotonically marching toward "more embeddings." Two of the most credible operators (Sourcegraph, Anthropic) have publicly de-emphasized them, and a third (Aider) never used them.

---

## 3. Per-harness deep dives

### 3.1 Cursor — embeddings + Merkle sync + Turbopuffer

Cursor's [`@codebase` system](https://cursor.com/blog/secure-codebase-indexing) is the most-deployed embedding-based code RAG in production.

**Pipeline:**
- On project open, walk the file tree and split each file into syntactic chunks. AST-aware via tree-sitter, depth-first traversal, sub-tree splitting until each chunk fits a token budget. Per [Engineer's Codex's writeup](https://read.engineerscodex.com/p/how-cursor-indexes-codebases-fast), this approach lets chunks "respect code structure" rather than line-based slicing.
- Embed each chunk. Embeddings (and obfuscated metadata only) are stored in [Turbopuffer](https://turbopuffer.com/customers/cursor) — an object-storage-backed vector DB chosen specifically because Cursor needed to scale to "[100B+ vectors](https://turbopuffer.com/customers/cursor)."
- Embeddings are content-hash cached on AWS so unchanged code reuses prior embeddings across runs.
- Query path: embed the user's query, ANN search Turbopuffer, return matching chunks. Original source stays on the user's machine and is fetched by the client when the agent asks for it.

**Merkle tree sync.** The cleverest piece. The client maintains a Merkle tree over the repo. The server holds an embedding-only index. When a file changes, the client walks branches where hashes differ — only changed subtrees re-index. ["With the Merkle tree, Cursor walks only the branches where hashes differ"](https://cursor.com/blog/secure-codebase-indexing). The tree also serves as a security primitive: during search, the server can require the client to prove possession of a file via the hash chain before returning results.

**Path obfuscation.** Cursor never stores raw code server-side. Per their security writeup, ["Cursor stores with every vector an obfuscated relative file path"](https://www.adwaitx.com/cursor-secure-codebase-indexing-architecture/) — every component split on `/` and `.` is masked with a secret key + small fixed nonce. This hides file/folder names while preserving enough structure for filtering.

**The @-symbol context provider model.** Beyond automated retrieval, Cursor exposes manual context controls — [`@codebase`, `@file`, `@folder`, `@code`/`@symbols`, `@docs`, `@web`, `@git`](https://cursorpractice.com/en/cursor-tutorials/getting-started/6-Context). Effective usage in the docs is roughly: ["@Codebase 60% of the time, @Files 30%, others 10%."](https://datalakehousehub.com/blog/2026-03-context-management-cursor/) Targeted context (`@code`, `@file`) reportedly outperforms broad `@codebase` retrieval in latency, accuracy, and hallucination rate.

**The acknowledged failure mode.** Cursor's own community guidance flags it: ["@Codebase is probabilistic — if you call your function 'Login' but the code says 'SessionCreation', RAG may fail to find it because the search is semantic, not lexical."](https://datalakehousehub.com/blog/2026-03-context-management-cursor/) Embedding similarity collapses to fuzzy term overlap on the wrong vocabulary.

### 3.2 Sourcegraph Cody — embeddings, then away from embeddings

Cody's evolution is the most important contrarian data point in the space.

**Original design** ([How Cody understands your codebase](https://sourcegraph.com/blog/how-cody-understands-your-codebase)). Embeddings were the backbone of Cody's retrieval stack at launch. Code went to OpenAI for embedding, vectors lived in Sourcegraph's storage, retrieval was cosine ANN.

**The pivot.** When Cody Enterprise went GA, Sourcegraph removed embeddings. From their [FAQ](https://sourcegraph.com/docs/cody/faq): ["Cody does not support embeddings on Cody Enterprise because they have been replaced with Sourcegraph Search."](https://sourcegraph.com/docs/cody/faq) Three reasons cited:
1. **Scale.** Vector search across "[>100,000 repositories](https://www.augmentcode.com/tools/cursor-vs-sourcegraph-cody-embeddings-and-monorepo-scale)" was complex and resource-intensive.
2. **Security.** Embeddings forced sending code to a third-party (OpenAI) embedding API.
3. **Maintenance.** Embeddings need refreshing as code changes; the operational burden was real and fell on Sourcegraph admins.

**Replacement architecture.** Cody now leans on the existing Sourcegraph stack: [keyword search, BM25, the SCIP-based code graph, and intelligent ranking](https://sourcegraph.com/blog/anatomy-of-a-coding-assistant). [SCIP (Source Code Intelligence Protocol)](https://sourcegraph.com/blog/announcing-scip) is a Protobuf-based indexing format Sourcegraph built to power "go to definition" and "find references" — a precise, deterministic symbol graph rather than a probabilistic vector index. The arxiv paper [AI-assisted Coding with Cody](https://arxiv.org/abs/2408.05344) (Hartman et al., 2024) frames the lesson as "context retrieval as a recommender systems problem" and emphasizes structured, deterministic signals.

**What's notable.** Cody runs at multi-repo enterprise scale (1M+ token windows, ~10 remote repos at once) and they decided embeddings weren't worth it at that scale. The economics flip the other way for a single-developer tool like Cursor. Scale matters.

### 3.3 Continue.dev — the most documented OSS hybrid

Continue.dev is the open-source coding assistant whose architecture is most fully described in public docs.

**Storage layout** ([DeepWiki](https://deepwiki.com/continuedev/continue/3.4-codebase-indexing)):
- **LanceDB** for vectors. Schema: `uuid, path, cachekey, vector, startLine, endLine, contents`.
- **SQLite** for metadata. The `code_snippets` table holds symbol title, signature, content for each tree-sitter-extracted entity.
- **Rust-based sync library** for incremental indexing. Mirrors what Cursor does with Merkle hashes, but built into a separate crate.

**Chunking.** Tree-sitter with per-language `.scm` query files (e.g., `code-snippet-queries/typescript.scm`). The `CodeSnippetsCodebaseIndex` uses these queries to extract function definitions, interface declarations, class structures.

**Embeddings.** Default is local: [transformers.js + `all-MiniLM-L6-v2`](https://docs.continue.dev/customize/model-roles/embeddings), shipped inside the VS Code extension. For larger models locally, Continue recommends `nomic-embed-text` via Ollama (786-dim vectors). Critically, this is local-first — no third-party API call required for the most common case.

**Re-ranking.** Two-stage. ["Reranking involves retrieving a larger initial pool of results from the vector database, and then using a reranking model to order them"](https://docs.continue.dev/customize/model-roles/reranking). Default sizes from the [docs](https://docs.continue.dev/customize/model-roles/reranking): retrieve ~25, re-rank to top 5; or retrieve 50, return 10. Voyage AI's `rerank-2` is recommended; Cohere also supported.

**The asymmetric query/code problem.** Continue's docs name this explicitly: ["the user's question is a question, whereas the necessary snippets will be code — two different categories of text, which might be separated in the latent space."](https://blog.continue.dev/accuracy-limits-of-codebase-retrieval/) This is the mathematical reason `@codebase`-style retrieval misses calls like the "Login → SessionCreation" case. Re-rankers help; HyDE (generating a hypothetical answer to embed) helps; switching to BM25 in parallel helps. None fully solve it.

### 3.4 Aider — repomap, no embeddings

Aider's [repomap](https://aider.chat/2023/10/22/repomap.html) is the cleanest counterexample to the "embeddings are the only path" narrative.

**The pipeline:**
1. Tree-sitter parses every source file using language-specific `tags.scm` query files. ["The repo map system supports 130+ languages through tree-sitter parsers."](https://deepwiki.com/Aider-AI/aider/4.1-repository-mapping)
2. Tags split into "definitions" and "references."
3. Build a directed graph: nodes are files (and symbols), edges are references between symbols across files.
4. Run [personalized PageRank via NetworkX](https://deepwiki.com/Aider-AI/aider/4.1-repository-mapping). The personalization vector biases toward files currently in the chat or symbols mentioned in the user's message.
5. Edge weights use [identifier multipliers: ~10x for mentioned identifiers, ~10x for "well-named" identifiers, ~50x for files already added to chat](https://deepwiki.com/Aider-AI/aider/4.1-repository-mapping).
6. Top-ranked tags get formatted via `to_tree()` into elided source. Uses `TreeContext` from `grep_ast` to render only the relevant lines, scope-aware.
7. Binary search on tag count to fit a token budget — [`--map-tokens` defaults to 1000](https://aider.chat/docs/repomap.html).

**What gets shown.** Class headers, method signatures, important defs — with `⋮...` placeholders for everything else. The model sees the *shape* of the codebase, not the substance, and asks for files when it needs them.

**Why this works.** Aider's bet: ["a function called by 20 other functions is more valuable context than a private helper called once."](https://deepwiki.com/Aider-AI/aider/4.1-repository-mapping) Reference frequency is a proxy for importance, and PageRank generalizes that proxy across the whole graph. No embeddings, no third-party API, no privacy story to manage. Adding a language is just dropping a `tags.scm` file.

**Limits.** Repomap doesn't help when the answer is "go read the body of `compute_billing()`" — only that the body exists and is signature-shaped like X. Aider compensates by letting the model request files into chat.

### 3.5 Claude Code — search, don't index, layer everything else as just-in-time prose

Claude Code's choice is the most contrarian: there is essentially no codebase index. The agent gets `Glob`, `Grep` (ripgrep), `Read`, `LS`, `Bash`, and reasons its way through the repo turn by turn. Around that core, Anthropic has built a stack of *prose-and-folder* mechanisms — CLAUDE.md, skills, sub-agents, hooks, MCP — that together do the work other harnesses ask of an embedding store.

[Anthropic's framing](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents) is just-in-time: ["Rather than pre-processing all relevant data up front, agents maintain lightweight identifiers (file paths, stored queries, web links, etc.) and use these references to dynamically load data into context at runtime using tools."](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents) The hybrid concession is `CLAUDE.md`: ["CLAUDE.md files are naively dropped into context up front, while primitives like glob and grep allow it to navigate its environment and retrieve files just-in-time, effectively bypassing the issues of stale indexing and complex syntax trees."](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents)

**The CLAUDE.md hierarchy is itself an index — for prose, not code.** Per the [best-practices doc](https://www.anthropic.com/engineering/claude-code-best-practices), CLAUDE.md files load from multiple locations and compose: home folder (`~/.claude/CLAUDE.md`, applies to all sessions), project root (`./CLAUDE.md`, checked into git for the team), parent directories (monorepo support — `root/CLAUDE.md` and `root/foo/CLAUDE.md` both load when working in `foo`), and child directories (pulled in on demand). Files can `@import` other files. Enterprise scope exists too. Every session starts with this stack pre-resolved into context. The advice in the docs is blunt: ["Bloated CLAUDE.md files cause Claude to ignore your actual instructions"](https://www.anthropic.com/engineering/claude-code-best-practices) — keep it short, prune it, treat it like code.

**The `#` shortcut adds memory mid-session.** Type `#` followed by an instruction (e.g. `# always use TypeScript strict mode`) and Claude prompts you to save it to project- or user-level CLAUDE.md. The quickest way to grow the prose index without leaving the session.

**Plan mode is a context-shaping pattern.** Claude Code separates exploration from execution. Plan mode is read-only: the agent gathers context, drafts a plan, and waits for approval before any mutation. Per the best-practices doc, this exists because ["letting Claude jump straight to coding can produce code that solves the wrong problem."](https://www.anthropic.com/engineering/claude-code-best-practices) Operationally, plan mode is also a *context budget firewall* — the planning subagent fills its own window with exploration, returns a compact plan, and the executing agent starts fresh.

**Sub-agents are deliberate context segregation.** Per the [sub-agents doc](https://docs.claude.com/en/docs/claude-code/sub-agents): ["Use one when a side task would flood your main conversation with search results, logs, or file contents you won't reference again: the subagent does that work in its own context and returns only the summary."](https://docs.claude.com/en/docs/claude-code/sub-agents) Built-in subagents include **Explore** (read-only, runs on Haiku, used for codebase search), **Plan** (read-only research during plan mode), and **general-purpose**. Each runs in its own context window with a custom system prompt and tool restrictions. The indexing pattern: a subagent processes 50k tokens of search results and returns a 1k-token summary; the parent never sees the 50k. This is the same compression idea as a re-ranker, except the "re-ranker" is itself an LLM-driven search session.

**Hooks are dynamic context injection.** The [hooks system](https://docs.claude.com/en/docs/claude-code/hooks) fires user-defined shell commands at lifecycle points (`PreToolUse`, `PostToolUse`, `Notification`, `UserPromptSubmit`, `SessionStart`). The indexing-relevant ones: a `UserPromptSubmit` hook can inject ad-hoc context for every prompt (current branch state, lint diagnostics, recent failing tests); a `SessionStart` hook can warm the context with project-specific info beyond CLAUDE.md; a `PostToolUse` hook on `Edit` can run a formatter or trigger a re-indexer in the background. Hooks turn "context retrieval" into something deterministic and out-of-band: the agent doesn't have to think to ask for the context, it just appears.

**MCP is the external-context surface.** [Model Context Protocol](https://docs.claude.com/en/docs/claude-code/mcp) lets Claude Code reach databases, issue trackers, monitoring dashboards, internal services. From the docs: ["Connect a server when you find yourself copying data into chat from another tool... Once connected, Claude can read and act on that system directly instead of working from what you paste."](https://docs.claude.com/en/docs/claude-code/mcp) MCP is what lets Claude Code stay "no codebase index" while still being able to query Sentry, JIRA, Postgres, Figma, Slack — these *are* indexes, just owned by other systems and exposed via tool calls.

**Skills are just-in-time, three-level loading.** From [Anthropic's Skills writeup](https://www.anthropic.com/engineering/equipping-agents-for-the-real-world-with-agent-skills), a skill is a folder with a `SKILL.md` and optional bundled files. Three levels of progressive disclosure:
1. **Always loaded** — the `name` and `description` of every installed skill go into the system prompt at startup.
2. **On-relevance** — when Claude judges a skill applies, it reads the full `SKILL.md`.
3. **On-demand** — `SKILL.md` references additional files (`reference.md`, `forms.md`, scripts) that Claude reads only as needed.

This is the same compression-vs-fidelity tradeoff a vector index tries to solve, but resolved by *human authoring + folder structure + the model's judgment* rather than embeddings. Quoting Anthropic: ["The amount of context that can be bundled into a skill is effectively unbounded."](https://www.anthropic.com/engineering/equipping-agents-for-the-real-world-with-agent-skills) The total skill library can be megabytes; only the names and descriptions hit the prompt baseline.

**Why this stack works:**
- No index sync, no third-party embedding APIs, no stale-index bugs. The model always looks at HEAD.
- The "index" surface is human-curated prose (CLAUDE.md, SKILL.md descriptions). Cheaper to maintain than vectors, easier to debug.
- Sub-agents and skills both implement compression: load only the metadata, expand only when needed. Progressive disclosure as the design principle, not just a feature.
- "[Less scaffolding, more model.](https://kotrotsos.medium.com/things-we-can-learn-from-claude-code-67e10daa3976)" Trust the model, skip the orchestration.

**The trade-offs.** Slower for cold queries. Costs more tokens when the agent reads files it didn't need. Authoring CLAUDE.md and skills is real work that falls on the user. Per-turn latency higher than a vector lookup. Anthropic's bet is that context-rot, stale-index bugs, and operational cost outweigh these.

**Direction of travel: even less scaffolding.** As of v2.1.117 (April 2026), Claude Code ["removed both ripgrep and the dedicated Grep tool on macOS and Linux native builds; embedded ugrep and bfs binaries are now invoked through Bash instead."](https://www.codeant.ai/blogs/why-coding-agents-should-use-ripgrep) The dedicated `Glob` tool went too — confirmed in the [community issues](https://github.com/anthropics/claude-code/issues/51781). Search is now just `bash` calls. The thesis hardens: as the model gets smarter, even thin specialized tools (let alone a vector store) become scaffolding the model can route around.

### 3.6 OpenAI Codex — AGENTS.md, sandboxes, and a parallel cloud agent

OpenAI's Codex line has two surfaces that share a context philosophy: the open-source **Codex CLI** ([github.com/openai/codex](https://github.com/openai/codex)) that runs locally, and **Codex Web / Codex cloud** ([chatgpt.com/codex](https://chatgpt.com/codex)) that runs delegated tasks in cloud sandboxes. Both treat the codebase the same way Claude Code does — read/grep/shell, no embeddings — but layer different scaffolding on top.

**AGENTS.md vs CLAUDE.md.** Codex's prose-context file is `AGENTS.md`, a convention also adopted by Cursor, Aider's `--read` mode, and others under the [agents.md](https://agents.md/) umbrella. Same idea as CLAUDE.md, different filename. From OpenAI's docs: ["Codex reads AGENTS.md files before doing any work, and by layering global guidance with project-specific overrides, you can start each task with consistent expectations."](https://developers.openai.com/codex/guides/agents-md) The hierarchy mirrors Claude Code's:
- **Global scope** — `~/.codex/AGENTS.md` (or `AGENTS.override.md`).
- **Project scope** — walk from the Git root down to the current directory; in each, check `AGENTS.override.md`, then `AGENTS.md`, then `project_doc_fallback_filenames`.
- **Precedence** — global lowest; deeper files take precedence because language models weight recent context more heavily.
- **Size cap** — Codex stops reading once it accumulates `project_doc_max_bytes` (32 KiB by default). If the stack exceeds that, the deepest project files may get partially or fully dropped — the opposite of CLAUDE.md's "import what you want" model.

**Context strategy: also no embeddings.** Codex CLI reaches for the same primitives as Claude Code — shell, read, grep — and explicitly recommends `rg` for searches. From OpenAI's [prompting guide](https://developers.openai.com/cookbook/examples/gpt-5/codex_prompting_guide): ["The agent doesn't need a semantic search engine — it needs to grep well."](https://developers.openai.com/cookbook/examples/gpt-5/codex_prompting_guide) Same philosophical bet as Anthropic: the model is smart enough to navigate a real filesystem; an upfront vector index is overhead.

**Sandbox dictates what the agent can see.** The other major Codex-specific lever is sandboxing. Locally, Codex runs under an OS-enforced sandbox that limits filesystem access (typically to the current workspace) and a separate approval policy that controls when the agent must stop and ask. The presets are roughly *read-only*, *workspace-write* (with `--ask-for-approval on-request`, the "Auto" preset), and *full-access*. Approval modes round-trip across TUI sessions, MCP sandbox state, and shell escalation. The indexing implication: **the sandbox itself shapes the visible-context surface.** A workspace-write sandbox means the agent's "index" is exactly "everything in this directory tree it can reach with `ls` and `cat`," and the sandbox is the enforcement that makes "reach with `cat`" a safe primitive.

**Codex Web: parallel tasks, repo-clone-as-context.** Codex cloud (originally launched May 2025, integrated into ChatGPT) gives each delegated task its own cloud sandbox preloaded with a fresh repo clone. Per OpenAI's announcements, ["each task runs in its own cloud sandbox environment, preloaded with your repository,"](https://openai.com/index/introducing-codex/) and ["because it runs in the cloud, Codex can handle multiple tasks in parallel."](https://openai.com/index/introducing-codex/) A setup script runs once and the resulting container is cached. Each task is isolated in its own VM. This is **context isolation through environment, not embeddings**: instead of partitioning a vector store, Codex partitions whole containers. The agent in each container then explores the cloned repo with the same read/grep tools as the local CLI. Tasks can run for hours; you check back later.

**Long sessions: native compaction, opaque blobs.** GPT-5.1-Codex-Max (and 5.2-Codex) is ["the first model natively trained to operate across multiple context windows through a process called compaction, coherently working over millions of tokens in a single task."](https://openai.com/index/gpt-5-1-codex-max/) Codex CLI's compaction is server-side and produces ["an opaque, AES-encrypted blob rather than a human-readable summary."](https://codex.danielvaughan.com/2026/04/14/context-compaction-deep-dive-codex-cli-claude-code-opencode/) A two-tier strategy first checks whether structured session memory can substitute for a full LLM summarization call; most auto-compactions take that path. Both Codex and Claude Code treat compaction as a *replacement* for a persistent index — re-summarize what the agent already learned rather than re-retrieve from a store.

**Model selection.** Codex CLI exposes `/model` to switch mid-session. OpenAI's recommendation: start with the strongest available model for complex coding (GPT-5.5 / GPT-5.2-Codex / GPT-5.1-Codex-Max depending on cohort). Lower-cost models work for narrower lookup tasks — paralleling Claude Code's pattern of running the Explore subagent on Haiku.

**Skills, MCP, slash commands.** Codex CLI also supports [skills](https://github.com/openai/codex/blob/main/docs/skills.md), [MCP servers](https://github.com/openai/codex/blob/main/docs/config.md) (configured in `~/.codex/config.toml` with per-server `default_tools_approval_mode` and per-tool `approval_mode`), slash commands, and ChatGPT connectors (the `$` composer prefix inserts a connector). The convergence with Claude Code is striking: both stacks now have prose-context files, skills, hooks-or-equivalent (Codex calls them "lifecycle hooks" replacing the deprecated `notify`), MCP, and sub-agents. The differences are mostly cosmetic.

---

## 4. Cross-cutting techniques

### 4.1 Chunking strategies — the unglamorous foundation

**Fixed-size / line-based.** The naive default. Cheap, fast, language-agnostic. Mangles syntactic units. The [cAST paper](https://arxiv.org/abs/2506.15655) names the problem directly: ["existing line-based chunking heuristics often break semantic structures, splitting functions or merging unrelated code, which can degrade generation quality."](https://arxiv.org/abs/2506.15655)

**AST-aware.** Tree-sitter is the universal answer. Cursor, Continue.dev, and Aider all use it. Walk the AST depth-first, recursively split nodes that exceed the budget, merge sibling nodes when they fit. This is essentially what cAST formalizes:

> [cAST] "recursively breaks large AST nodes into smaller chunks and merges sibling nodes while respecting size limits."

Their reported gains: ["StarCoder2-7B sees an average of 5.5 points gain on RepoEval"](https://arxiv.org/html/2506.15655v1) versus line-based chunking, plus cross-language consistency and better metadata retention (~2.7 points on SWE-bench).

**The four design goals from cAST** are worth quoting because they generalize:
1. Syntactic integrity — boundaries align with complete syntactic units.
2. High information density — pack each chunk to a fixed budget.
3. Language invariance — no per-language heuristics in the algorithm.
4. Plug-and-play compatibility — concatenating chunks reproduces the file verbatim.

**Symbol-level (Aider style).** Skip the file entirely; index the symbols (functions, classes) as graph nodes. Chunking effectively becomes "what's the signature of this function?" + an elided body view.

### 4.2 Embedding models

For code, the consensus has shifted from generic models (OpenAI's `text-embedding-ada-002`) toward code-specialized models. The [RACG survey](https://arxiv.org/abs/2510.04905) names UniXcoder, CodeBERT, GraphCodeBERT as the canonical academic options. Continue.dev defaults to general-purpose `all-MiniLM-L6-v2` for footprint reasons (it ships in the extension), and recommends `nomic-embed-text` (786-dim) for users wanting more capacity locally.

**Local-first matters.** Continue's choice to ship a local embedder by default avoids the privacy and latency story Cody got tired of managing. This is part of why Cody's pivot makes sense: at enterprise scale, the embedder-as-API model has real costs that don't show up in the prototype.

### 4.3 Re-ranking — the cheap accuracy lever

The pattern is consistent across Continue.dev, Cody (originally), and most production hybrid systems:
- Retrieve broadly (50-100 candidates) via cheap similarity.
- Re-rank tightly (return 5-10) via a cross-encoder that scores `(query, candidate)` pairs together.

Continue defaults to ["~25 retrieved → 5 reranked"](https://docs.continue.dev/customize/model-roles/reranking) or "50 → 10." Voyage AI's `rerank-2` is the recommended code re-ranker. Cohere's reranker is the other common pick.

The math: a cross-encoder is too expensive to run on every chunk in the index, but cheap enough to run on a top-50. The gain over single-stage similarity is large enough that nearly every production RAG system has a re-ranking layer.

### 4.4 Hybrid search — BM25 + dense + RRF

Sparse (BM25) is unbeatable for ["technical terms, acronyms and specifically used identifiers."](https://www.atlantis-press.com/article/126020757.pdf) Dense embeddings are good for paraphrase ("login function" → "authenticate user"). They have orthogonal failure modes.

**Reciprocal Rank Fusion (RRF)** is the merge function of choice. Each system produces a ranking; RRF score for an item is the sum over each ranker of `1 / (k + rank)` (with `k ≈ 60`). It's normalization-free — you don't need calibrated scores from either side.

Quoted lift: ["Combining them hits 91% recall@10 versus 78% for dense-only or 65% for sparse-only."](https://www.minimalistinnovation.co/post/hybrid-search-reciprocal-rank-fusion-lexical-semantic) Modern vector DBs (Qdrant, Elasticsearch, Weaviate, Milvus) all ship hybrid + RRF natively now.

### 4.5 Incremental updates — Merkle trees everywhere

The dominant pattern: hash file contents (BLAKE3 or SHA-256), build a Merkle tree over the directory structure, on re-index walk only branches where hashes differ.

- **Cursor** uses Merkle for both incremental sync and as a security primitive (server requires hash-chain proofs to return results).
- **Continue.dev** uses a Rust sync library with similar hashing.
- **Code-Graph-MCP** (a third-party Claude Code MCP) [uses BLAKE3 + mtime cache](https://github.com/sdsrss/code-graph-mcp) — unchanged subtrees skipped entirely.
- **Claude Context** (Zilliz) [uses Merkle tree + SHA-256 file hashing](https://www.npmjs.com/package/@zilliz/claude-context-core).

The lesson: every harness that pre-builds an index has converged on Merkle hashing for invalidation. It's logarithmic-time change detection and naturally enables partial sync.

### 4.6 The asymmetric query/code problem

Stated by Continue.dev directly: ["the user's question is a question, whereas the necessary snippets will be code — two different categories of text, which might be separated in the latent space."](https://blog.continue.dev/accuracy-limits-of-codebase-retrieval/)

Mitigations seen in the field:
- **Re-rankers** with cross-encoders trained on query-code pairs.
- **HyDE** — let an LLM generate a hypothetical answer (in code form), embed *that*, search.
- **Hybrid search** — BM25 catches what dense misses on technical identifiers.
- **Symbol-level retrieval** — Aider sidesteps it entirely by ranking symbols not chunks.

This is the deep reason "embed everything and pray" doesn't work for code.

---

## 5. The contrarian voices

The "no embeddings club" has grown to four credible operators publicly pushing back on the embedding-RAG-by-default consensus:

**Cody (Sourcegraph)** ripped embeddings out of their enterprise product. Reasons: scale economics, third-party data exposure, operational maintenance. They replaced it with native code search (BM25 + SCIP code graph + intelligent ranking). At enterprise scale, deterministic structured search wins.

**Aider** never used embeddings. Their bet is that compressed structural maps + PageRank give the model enough of the codebase shape to navigate, and the model can request files when it needs detail. Competitive on SWE-bench. The thesis: ["compressed structure beats embedded chunks for many tasks."](https://aider.chat/2023/10/22/repomap.html) Even Aider's structural index is tree-sitter symbols, not vectors.

**Anthropic / Claude Code** went further. No persistent code index at all. Just `glob`, `grep` (now `bash`), `read`. The replacement isn't a different index — it's a *constellation* of human-curated prose contexts (CLAUDE.md hierarchy), progressive-disclosure skills, sub-agents that compress their own work, and MCP for external systems. ["[Glob and grep] effectively bypass the issues of stale indexing and complex syntax trees."](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents)

**OpenAI / Codex CLI + Codex Web** lands in the same place independently. Codex CLI uses read/grep/shell against a real filesystem — ["the agent doesn't need a semantic search engine — it needs to grep well."](https://developers.openai.com/cookbook/examples/gpt-5/codex_prompting_guide) Codex Web replaces "shared index across tasks" with "fresh repo clone per task in a sandboxed VM." Two of the three biggest model labs converged on the same anti-index posture.

**The pattern.** Each contrarian is rejecting a specific embedding cost: Cody rejects the *scaling cost*, Aider rejects the *infrastructure cost*, Anthropic rejects the *staleness cost*, OpenAI rejects the *cross-task isolation cost* (and ships parallel sandboxes as the alternative). The replacement is always "use deterministic, structural signals (PageRank graph, SCIP, file system + grep, repo clone) plus model intelligence." The probabilistic vector layer becomes optional.

**The Markdown-context-file convergence is itself a finding.** CLAUDE.md, AGENTS.md, `.cursor/rules`, Aider's `--read` files, Continue's project-level config — every harness has converged on a small Markdown file at the repo root as the lightest-weight "index." The human writes the index once (specifying conventions, build commands, gotchas), and the agent reads it every session. It's a *pre-baked compressed index*: lossy by design, hand-curated, human-readable, debuggable, and free of any sync infrastructure. It's striking that the operationally simplest possible "index" (a paragraph of prose) is what shipped at every harness, including the ones with full vector stacks. The vector index supplements the Markdown file; it doesn't replace it.

A useful prediction lens: the smarter the model, the less elaborate the harness needs to be. ["Less scaffolding, more model."](https://kotrotsos.medium.com/things-we-can-learn-from-claude-code-67e10daa3976) Embedding-RAG is scaffolding the model can increasingly route around — but a hand-curated AGENTS.md is scaffolding nobody is in a hurry to delete.

---

## 6. Privacy & security patterns

Embedding-based indexing creates a third-party data exposure surface that everyone has to manage somehow.

**Cursor — never store raw code.** Original source stays on the developer's machine. Server holds only embeddings + obfuscated metadata. ["Each component of the path, split by / and ., is masked using a secret key and a small fixed nonce, which hides the actual file and folder names while preserving enough directory structure to support effective retrieval and filtering."](https://www.adwaitx.com/cursor-secure-codebase-indexing-architecture/) When a search returns hits, the client fetches the actual source from local disk. ["Original source code remains on the local machine and is never stored on Cursor servers or in Turbopuffer."](https://towardsdatascience.com/how-cursor-actually-indexes-your-codebase/)

**Cursor — Merkle as proof-of-possession.** ["During search, the server filters results by checking hashes against the client's tree, and if the client can't prove it has a file, the result is dropped."](https://cursor.com/blog/secure-codebase-indexing) This prevents file-leak across user copies of the same codebase — even if two clients embedded the same file, only the client that holds it can fetch search results pointing to it. The Merkle tree is a security primitive, not just a sync primitive.

**Cursor — Privacy Mode.** Per Cursor's own writeup, ["50% of users"](https://towardsdatascience.com/how-cursor-actually-indexes-your-codebase/) run with Privacy Mode, where no raw code is retained beyond a single request.

**Cody — quit embeddings to remove the third party.** ["No code is being sent to a third-party embedding API"](https://sourcegraph.com/docs/cody/faq) is one of the reasons cited for the move to Sourcegraph Search. Eliminating the embedding step eliminates the data-exfil concern.

**Continue.dev — local-first embedders.** Default `all-MiniLM-L6-v2` runs in the extension via transformers.js. No call out to OpenAI for embedding. The vector DB (LanceDB) is local. End-to-end local for the common case.

**Claude Code — nothing to leak.** No persistent index, no third-party embedder, no server-side code storage. The privacy story is "we never had your code" rather than "we have your code but treat it carefully."

The general lesson: every layer of the index pipeline that touches a remote service is a layer to defend. Cursor's approach is "minimize what crosses the wire and prove ownership cryptographically." Cody, Continue, and Claude Code's approach is "don't put a third party in the loop at all."

---

## 7. Open observations relevant to video

Observations only, not proposals.

- **Video has more candidate index types than code.** Code's main axes are file/symbol/import-graph/embedding. Video has at least: transcript text, scene boundaries, shot composition, speaker turns, audio energy, on-screen text/OCR, face identities, motion intensity, scene-graph entities (people/objects/places), camera-motion class, color palettes, B-roll vs talking-head. Each is a different "index" and probably needs different infrastructure.
- **No AST equivalent.** This is a real loss. Tree-sitter gives the coding harnesses a free, deterministic, language-invariant structural signal — both for chunking (cAST) and for symbol graphs (Aider). Video has no canonical tree of "this is one syntactic unit." Scene detection is the closest analogue and it's much fuzzier (PySceneDetect, shot-boundary models). Transcript sentence/paragraph structure is the next-closest, but only covers the dialogue track.
- **Embeddings work well on transcript text.** Transcript text behaves like normal prose; standard text embedders (and re-rankers) apply. The asymmetric query problem is *less severe* here because both the user's question and the transcript are natural language.
- **Vision embeddings are the visual analogue.** CLIP-style joint text-image embeddings (and their video extensions: VideoCLIP, X-CLIP, InternVideo) let "find the shot where the host points at the whiteboard" return frames matching the textual query. The asymmetric query problem flips to text-vs-frame-content asymmetry, which is exactly what CLIP was designed to bridge.
- **Speaker diarization, face recognition, OCR are deterministic structural signals.** Like SCIP for code: precise, queryable, not probabilistic. Worth treating as first-class index types alongside or instead of vision embeddings.
- **Incremental indexing matters more than for code.** Re-running scene detection / diarization / vision embeddings on multi-GB footage is expensive in a way that re-embedding 1000 source files is not. The Merkle-style "only re-do what changed" pattern probably needs an analogue at the clip level (and within-clip at the segment level after edits).
- **Cuts mutate the index.** Editing footage is destructive (or at least transformative) in a way that editing source code isn't. A `split_clip` shifts every overlay timestamp downstream of it. The index has to track source-time vs timeline-time. Aider's "self-loops with weight=0.1 to prevent isolated nodes" is the kind of detail that has analogues here — "what happens to indexed metadata for a clip segment that's been ripple-deleted?"
- **Just-in-time retrieval is plausible.** Anthropic's bet is essentially "let the model navigate the file system." The video equivalent is letting the model navigate the timeline + asset library with primitives like "list clips," "get transcript range," "extract frame at timestamp," "search transcript for substring." This is significantly simpler than building a vision-embedding index, and might be enough for the dialogue-driven cases. It's clearly insufficient for purely visual queries ("find the shot where the cat jumps off the couch") because there's no `grep` for pixels.
- **Hybrid is probably mandatory.** No single index type covers all queries. "Find the shot where she says 'machine learning'" needs transcript search. "Find the wide establishing shot" needs vision embeddings + shot-type classifier. "Find every cut to the host" needs face recognition. "Find the high-energy moments" needs audio energy analysis. The harness will likely need to route queries to the right index, which is itself a model-decision.
- **Compression matters.** Aider's repomap is fundamentally a compression technique — ~1k tokens that summarize a million-line repo. The video analogue would be: a compact prompt-time summary of the entire footage library (e.g., "12 clips, 47 minutes total, 3 speakers identified, dominant scenes: kitchen / studio / outdoors, transcript topics: cooking, equipment review, recipe walkthrough"). This is clearly different from a chunk-level index but probably needed alongside it.
- **The asymmetric query problem applies to vision queries.** "A frame where someone holds up a red mug" is a text query against pixel content. CLIP-style embeddings address this directly. But the same asymmetric-failure-mode lesson applies: if the user's word doesn't match the canonical visual concept ("mug" vs "cup" vs "tumbler"), single-stage similarity will miss it. Re-rankers and HyDE-style query rewriting are likely useful.
- **Privacy framing is different.** Code is the user's IP and they care about it leaving the machine. Footage is often the user's IP *and contains other people's likenesses* — the privacy concerns are even sharper. The Cursor / Claude Code patterns of "minimize what crosses the wire" or "nothing crosses the wire at all" are worth taking seriously.

---

## 8. Source list

**Anthropic / Claude Code**
- [Effective context engineering for AI agents — Anthropic](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents)
- [Claude Code best practices — Anthropic](https://www.anthropic.com/engineering/claude-code-best-practices)
- [Equipping agents for the real world with Agent Skills — Anthropic](https://www.anthropic.com/engineering/equipping-agents-for-the-real-world-with-agent-skills)
- [Sub-agents — Claude Code docs](https://docs.claude.com/en/docs/claude-code/sub-agents)
- [Hooks — Claude Code docs](https://docs.claude.com/en/docs/claude-code/hooks)
- [Model Context Protocol — Claude Code docs](https://docs.claude.com/en/docs/claude-code/mcp)
- [Memory / CLAUDE.md hierarchy — Claude Code docs](https://code.claude.com/docs/en/memory)
- [Things we can learn from Claude Code — Marco Kotrotsos](https://kotrotsos.medium.com/things-we-can-learn-from-claude-code-67e10daa3976)
- [How Claude Code Works: Architecture & Internals](https://cc.bruniaux.com/guide/architecture/)
- [Why Your Coding Agent Should Use ripgrep — CodeAnt](https://www.codeant.ai/blogs/why-coding-agents-should-use-ripgrep)
- [Grep and Glob removed in Claude Code 2.1.117 — GitHub issue](https://github.com/anthropics/claude-code/issues/51781)

**OpenAI / Codex**
- [openai/codex on GitHub](https://github.com/openai/codex) — Codex CLI README, AGENTS.md, docs/
- [Custom instructions with AGENTS.md — OpenAI Developers](https://developers.openai.com/codex/guides/agents-md)
- [Sandbox — OpenAI Developers](https://developers.openai.com/codex/concepts/sandboxing)
- [Cloud environments — Codex web (OpenAI Developers)](https://developers.openai.com/codex/cloud/environments)
- [Codex Prompting Guide — OpenAI Cookbook](https://developers.openai.com/cookbook/examples/gpt-5/codex_prompting_guide)
- [Introducing Codex — OpenAI](https://openai.com/index/introducing-codex/)
- [Building more with GPT-5.1-Codex-Max — OpenAI](https://openai.com/index/gpt-5-1-codex-max/)
- [Context Compaction Deep Dive: Codex CLI, Claude Code, OpenCode](https://codex.danielvaughan.com/2026/04/14/context-compaction-deep-dive-codex-cli-claude-code-opencode/)
- [agents.md — the cross-harness convention](https://agents.md/)
- [Codex CLI MCP & config docs (in-repo)](https://github.com/openai/codex/blob/main/docs/config.md)

**Cursor**
- [Securely indexing large codebases — Cursor blog](https://cursor.com/blog/secure-codebase-indexing)
- [Cursor scales code retrieval to 100B+ vectors with Turbopuffer](https://turbopuffer.com/customers/cursor)
- [How Cursor Indexes Codebases Fast — Engineer's Codex](https://read.engineerscodex.com/p/how-cursor-indexes-codebases-fast)
- [How Cursor Actually Indexes Your Codebase — Towards Data Science](https://towardsdatascience.com/how-cursor-actually-indexes-your-codebase/)
- [Cursor Deploys Merkle Trees for Secure Code Indexing — Adwait](https://www.adwaitx.com/cursor-secure-codebase-indexing-architecture/)
- [Cursor: Security — Simon Willison](https://simonwillison.net/2025/May/11/cursor-security/)
- [Cursor — Codebase Indexing docs](https://docs.cursor.com/context/codebase-indexing)
- [Context Management Strategies for Cursor — datalakehousehub](https://datalakehousehub.com/blog/2026-03-context-management-cursor/)
- [Cursor IDE Tutorials — context providers](https://cursorpractice.com/en/cursor-tutorials/getting-started/6-Context)

**Sourcegraph Cody**
- [How Cody understands your codebase — Sourcegraph blog](https://sourcegraph.com/blog/how-cody-understands-your-codebase)
- [The anatomy of an AI coding assistant — Sourcegraph blog](https://sourcegraph.com/blog/anatomy-of-a-coding-assistant)
- [Cody FAQs — Sourcegraph docs](https://sourcegraph.com/docs/cody/faq)
- [SCIP — a better code indexing format than LSIF](https://sourcegraph.com/blog/announcing-scip)
- [SCIP repository on GitHub](https://github.com/sourcegraph/scip)
- [Embeddings — Sourcegraph docs](https://sourcegraph.com/docs/cody/core-concepts/embeddings)
- [AI-assisted Coding with Cody (arxiv 2408.05344)](https://arxiv.org/abs/2408.05344)
- [Cursor vs Sourcegraph Cody: Embeddings and Monorepo at Scale — Augment](https://www.augmentcode.com/tools/cursor-vs-sourcegraph-cody-embeddings-and-monorepo-scale)

**Continue.dev**
- [Codebase Indexing — DeepWiki / Continue](https://deepwiki.com/continuedev/continue/3.4-codebase-indexing)
- [How to Build Custom Code RAG — Continue Docs](https://docs.continue.dev/guides/custom-code-rag)
- [Embed Role — Continue Docs](https://docs.continue.dev/customize/model-roles/embeddings)
- [Rerank Role — Continue Docs](https://docs.continue.dev/customize/model-roles/reranking)
- [What are the accuracy limits of codebase retrieval? — Continue blog](https://blog.continue.dev/accuracy-limits-of-codebase-retrieval/)
- [Building RAG on codebases — LanceDB blog Part 1](https://www.lancedb.com/blog/building-rag-on-codebases-part-1)
- [Building RAG on codebases — LanceDB blog Part 2](https://www.lancedb.com/blog/building-rag-on-codebases-part-2)

**Aider**
- [Repository map — aider docs](https://aider.chat/docs/repomap.html)
- [Building a better repository map with tree sitter — aider blog](https://aider.chat/2023/10/22/repomap.html)
- [Repository Mapping System — DeepWiki / Aider](https://deepwiki.com/Aider-AI/aider/4.1-repository-mapping)
- [Repository Understanding and Context — DeepWiki / Aider](https://deepwiki.com/Aider-AI/aider/4-repository-understanding-and-context)
- [aider/repomap.py source on GitHub](https://github.com/Aider-AI/aider/blob/main/aider/repomap.py)
- [Supported languages — aider docs](https://aider.chat/docs/languages.html)
- [RepoMapper — Aider-style standalone tool](https://github.com/pdavis68/RepoMapper)

**Academic / surveys**
- [cAST: Enhancing Code RAG with Structural Chunking via AST (arxiv 2506.15655)](https://arxiv.org/abs/2506.15655)
- [cAST HTML version](https://arxiv.org/html/2506.15655v1)
- [astchunk — cAST reference implementation on GitHub](https://github.com/yilinjz/astchunk)
- [Retrieval-Augmented Code Generation: A Survey (arxiv 2510.04905)](https://arxiv.org/abs/2510.04905)
- [RACG Survey HTML version](https://arxiv.org/html/2510.04905v1)

**Hybrid search / RRF / general retrieval**
- [Hybrid Search Explained — Weaviate](https://weaviate.io/blog/hybrid-search-explained)
- [Hybrid Search & Reciprocal Rank Fusion — Minimalist Innovation](https://www.minimalistinnovation.co/post/hybrid-search-reciprocal-rank-fusion-lexical-semantic)
- [Hy-Search: A Hybrid Retrieval-Augmented Framework](https://www.atlantis-press.com/article/126020757.pdf)

**Incremental indexing / Merkle**
- [code-graph-mcp — BLAKE3 Merkle MCP server](https://github.com/sdsrss/code-graph-mcp)
- [@zilliz/claude-context-core — Merkle + SHA256 sync](https://www.npmjs.com/package/@zilliz/claude-context-core)

**Previously captured (not re-fetched)**
- `sources/aider-repomap.md` — full text of aider's repomap docs
- `sources/anthropic-context-engineering.md` — full text of Anthropic's context engineering post
- `sources/cursor-design-notes.md` — synthesized Cursor design notes from earlier pass
- Other `sources/anthropic-*.md` files captured in the first research pass
