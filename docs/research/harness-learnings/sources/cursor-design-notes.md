# Cursor design notes (synthesized from public sources)
**Source:** Synthesized from public sources (cursor.com is not directly fetchable from this environment); cited URLs are listed at the end.
**Author/Org:** Not affiliated with Cursor; compiled by a research subagent.
**Captured:** 2026-05-02

> Note: This document is a synthesis assembled from public knowledge and Cursor's own published blog posts. Direct fetching of cursor.com was not possible from this environment, so quotes are paraphrased rather than verbatim. Treat specific numbers as approximate.

## What Cursor is

Cursor is a fork of VS Code that re-builds the editor around a tightly integrated AI agent loop. Where most AI coding tools sit beside the editor (a chat panel, a completion popup), Cursor treats the agent as a first-class user of the editor's data structures: the file tree, the language server, the diagnostics stream, and the terminal.

## Core surfaces

**Tab (predictive completion).** Cursor's flagship inline experience. Rather than completing the next token or line, Tab predicts the next *edit* — which can be a multi-line insert, a multi-line delete, or a rewrite that spans non-contiguous regions. The model is prompted with recent edits, the cursor position, and surrounding context so that the next "Tab" press jumps the cursor to wherever the next plausible edit is and proposes it. The user's behavior is the training signal: when they accept it, that's a positive; when they keep typing past it, that's a negative.

**Cmd+K (inline edit).** A scoped, modal "ask the model to rewrite this selection." It is intentionally narrow — no project-wide context, no agent loop, just a fast model call against the highlighted span. This is the workhorse for small refactors and "rename this loop variable to something descriptive."

**Composer / Agent mode.** The full agent loop. Composer can read files, edit files, run terminal commands, see the output, and iterate. It plans a multi-step change, executes it, observes the results (compiler errors, test output, diagnostics), and self-corrects. This is the surface that competes most directly with Claude Code, Aider, and other harnesses.

**Composer-1 (October 2025).** Cursor's first in-house model. Publicly described as a Mixture-of-Experts model trained with reinforcement learning specifically against the Cursor agent harness. The training environment isn't a generic benchmark — it's the same tools, file viewer, edit format, and terminal abstraction that the production Composer agent uses. The pitch is that an agent model trained directly against its own harness outperforms a frontier general-purpose model that has to learn the harness's quirks at inference time.

## Architecture pieces worth knowing about

**Shadow workspace.** A hidden, off-screen window of the user's project that the agent uses to "try things." When the agent wants to know whether a proposed edit type-checks or whether a test passes, it applies the edit in the shadow workspace, lets the language server and test runner react there, reads the diagnostics, and only surfaces the change to the user's real window if it looks good. This avoids polluting the user's editor with broken intermediate states and avoids the latency of round-tripping through a remote sandbox.

**Agent worktrees (Cursor 2.0).** Building on git's worktree feature, Cursor 2.0 lets multiple Composer agents work on the same repository in parallel without stepping on each other. Each agent gets its own checkout, its own branch, and its own shadow workspace. This is the multi-agent answer to "I want to try three approaches to this bug at once."

**Context retrieval.** Cursor's retrieval combines semantic embeddings of the repository (computed and indexed when you open the project) with lexical search and recently-edited-file heuristics. The agent doesn't just dump the whole repo into context; it queries the index for relevant chunks and assembles a focused prompt. The same machinery powers the @-mention picker (where the user can manually pin files, symbols, or docs into the context).

**Diff-based edits.** Composer applies model output as patches against the current file rather than rewriting whole files. This is the same lesson Aider learned with its edit formats: small diffs are faster, cheaper, and easier to review.

## URLs to cite when this is referenced

- https://cursor.com/blog/shadow-workspace
- https://cursor.com/blog/composer
- https://cursor.com/blog/2-0
