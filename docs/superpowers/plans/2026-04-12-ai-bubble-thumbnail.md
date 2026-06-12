# AI Bubble Thumbnail Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rebuild the existing Paper thumbnail artboard into an exact-match composition based on the approved AI Bubble reference while reusing the local photo and logo assets already on the board.

**Architecture:** Keep the existing Paper artboard and reusable image nodes, remove the temporary placeholder composition, and rebuild the design as a clean editable layer stack. Work from back to front so composition, typography, and atmospheric overlays stay isolated and easy to tune.

**Tech Stack:** Paper design tools, existing image-fill nodes on the current artboard, local project docs

---

### Task 1: Audit reusable artboard assets

**Files:**
- Modify: `docs/superpowers/plans/2026-04-12-ai-bubble-thumbnail.md`
- Inspect: `Paper document "TECHNOLGIA" / artboard "Thumbnail — The AI Bubble" (node id: 1-0)`

- [ ] **Step 1: Confirm the reusable image nodes and current layer tree**

Inspect these nodes before any destructive edit:

```text
Artboard: 1-0
Left photo rectangle: T-0
Logo rectangle: R-0
Right photo rectangle: S-0
```

- [ ] **Step 2: Capture a baseline screenshot for comparison**

Run a Paper screenshot on node `1-0`.
Expected: a `1280x720` thumbnail showing the current simplified title/logo layout.

- [ ] **Step 3: Keep the three reusable image nodes and mark all other current layers as replaceable**

Replaceable nodes:

```text
10-0
11-0
12-0
13-0
15-0
16-0
1C-0
1E-0
```

Expected: only the photo/logo assets remain protected from deletion.

### Task 2: Clear the placeholder composition

**Files:**
- Modify: `Paper document "TECHNOLGIA" / artboard "Thumbnail — The AI Bubble" (node id: 1-0)`

- [ ] **Step 1: Delete the non-asset placeholder layers**

Delete only these nodes:

```text
10-0
11-0
12-0
13-0
15-0
16-0
1C-0
1E-0
```

Expected: the artboard contains only `T-0`, `R-0`, and `S-0`.

- [ ] **Step 2: Re-check the artboard children**

Expected: exactly three remaining reusable rectangles are present before reconstruction begins.

### Task 3: Rebuild the base composition

**Files:**
- Modify: `Paper document "TECHNOLGIA" / artboard "Thumbnail — The AI Bubble" (node id: 1-0)`

- [ ] **Step 1: Reposition the left and right photo panels**

Set the image rectangles so they behave as edge-to-edge side panels:

```text
Left panel width: about 520px, full height, anchored to left edge
Right panel width: about 530px, full height, anchored to right edge
Logo remains centered near the top
```

Expected: both portraits frame the canvas edges with open space left for the center slab.

- [ ] **Step 2: Add the center dark trapezoid slab**

Insert a new top-level shape spanning roughly the middle 520px of the canvas with a dark green-black gradient and angled sides that overlap the photo panels.

Expected: the center slab visually matches the reference’s tall tapered column.

- [ ] **Step 3: Add atmospheric green glow overlays**

Insert soft blurred glow elements near the lower left, lower right, and outer side edges.

Suggested treatment:

```text
Color family: green/teal
Opacity: low to medium
Blur: high
Placement: corners and side edges, not over the title text
```

Expected: the board gains the same green ambient energy as the reference without washing out the center.

### Task 4: Rebuild the title system

**Files:**
- Modify: `Paper document "TECHNOLGIA" / artboard "Thumbnail — The AI Bubble" (node id: 1-0)`

- [ ] **Step 1: Add the black title banner**

Insert a centered horizontal black rectangle across the middle of the artboard.

Suggested dimensions:

```text
Width: about 640px
Height: about 190px
```

Expected: the banner sits fully inside the center slab and overlaps the photos slightly, matching the reference.

- [ ] **Step 2: Add the title text**

Create a bold condensed all-caps text layer:

```text
THE AI BUBBLE
```

Suggested treatment:

```text
Color: white
Weight: black/bold
Tracking: slightly tight
Alignment: centered
```

Expected: the title fills the banner strongly with no wrapping and high contrast.

### Task 5: Rebuild the lower credit block

**Files:**
- Modify: `Paper document "TECHNOLGIA" / artboard "Thumbnail — The AI Bubble" (node id: 1-0)`

- [ ] **Step 1: Add the arrow and WITH row**

Create a lower-center row with a small white arrow mark and the word:

```text
WITH
```

Expected: the row sits above the host nameplate with clean spacing and a lighter visual weight than the title.

- [ ] **Step 2: Add the green host nameplate**

Insert a green rectangle centered below the `WITH` row.

Suggested dimensions:

```text
Width: about 380px
Height: about 92px
```

Expected: the plate resembles the reference’s bright green label block.

- [ ] **Step 3: Add the host names**

Create a centered white all-caps text layer:

```text
TADIWA & ELVIS
```

Expected: the host names read clearly inside the green plate and align to the title axis.

### Task 6: Polish and verify

**Files:**
- Modify: `Paper document "TECHNOLGIA" / artboard "Thumbnail — The AI Bubble" (node id: 1-0)`
- Test: `Paper screenshot of node 1-0`

- [ ] **Step 1: Fine-tune spacing and visual balance**

Adjust logo, slab width, title size, and credit spacing until the thumbnail matches the reference at a glance.

Expected: the top logo, central title, and lower credit feel locked to one vertical axis.

- [ ] **Step 2: Capture a verification screenshot**

Run a Paper screenshot on node `1-0`.
Expected: the final composition clearly resembles the supplied reference and remains editable.

- [ ] **Step 3: Document any remaining fidelity gaps**

If any mismatch remains because of source asset differences, note it explicitly in the handoff.
