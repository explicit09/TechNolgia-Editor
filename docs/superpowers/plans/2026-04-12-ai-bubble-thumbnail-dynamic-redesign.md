# AI Bubble Thumbnail Dynamic Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rebuild the existing Paper thumbnail artboard into a more dramatic, asymmetric composition while keeping the current hosts, title, and green/black brand system.

**Architecture:** Reuse the current host-photo nodes and rebuild the compositional layers above them in a new order so the slab, title, logo, and credit block feel more dynamic. Use fewer, clearer top-level layers so alignment, hierarchy, and overlap stay easy to tune directly in Paper.

**Tech Stack:** Paper design tools, existing Paper image assets, local redesign spec

---

### Task 1: Audit the current Paper layer state

**Files:**
- Modify: `docs/superpowers/plans/2026-04-12-ai-bubble-thumbnail-dynamic-redesign.md`
- Inspect: `Paper document "TECHNOLGIA" / artboard "Thumbnail — The AI Bubble" (node id: 1-0)`

- [ ] **Step 1: Capture the current artboard screenshot**

Run a Paper screenshot on node `1-0`.
Expected: a stable thumbnail with the cleaned logo, centered slab, current title banner, and the restored right-host photo.

- [ ] **Step 2: Confirm the reusable image nodes**

Keep these nodes as the reusable base assets:

```text
1C-0  Left Host Photo
24-1  Right Host Photo
```

Expected: host imagery is preserved while the graphic stack remains replaceable.

- [ ] **Step 3: Mark the current graphic stack as replaceable**

Replaceable nodes:

```text
1H-1  Left Glow
1J-1  Side Glow Left
1K-1  Side Glow Right
2A-1  Center Slab
2C-1  Right Glow
2D-1  Title Banner
2E-1  Title Text
2G-1  With Row
2L-1  Hosts Plate
2M-1  Hosts Text
2O-1  Top Logo
```

Expected: only the two host-image nodes are protected from deletion.

### Task 2: Clear the current graphic stack

**Files:**
- Modify: `Paper document "TECHNOLGIA" / artboard "Thumbnail — The AI Bubble" (node id: 1-0)`

- [ ] **Step 1: Delete the current slab, text, logo, and glow layers**

Delete only these nodes:

```text
1H-1
1J-1
1K-1
2A-1
2C-1
2D-1
2E-1
2G-1
2L-1
2M-1
2O-1
```

Expected: the artboard contains only the two host-photo nodes.

- [ ] **Step 2: Re-check the artboard children**

Expected: exactly `1C-0` and `24-1` remain before reconstruction begins.

### Task 3: Rebuild the dynamic base composition

**Files:**
- Modify: `Paper document "TECHNOLGIA" / artboard "Thumbnail — The AI Bubble" (node id: 1-0)`

- [ ] **Step 1: Reposition the host-photo panels**

Update the host-photo placement to create imbalance:

```text
Left host remains broad and calmer on the left edge
Right host shifts slightly inward to feel more engaged with center
```

Suggested target:

```text
Left photo: keep at left edge, full height
Right photo: move inward by roughly 20–40px compared with the current crop
```

Expected: the board no longer reads as perfectly split down the middle.

- [ ] **Step 2: Add a narrower, more tapered center slab**

Insert a new top-level slab with:

```text
Width reduced by roughly 10–15%
Stronger taper than the current version
Slight offset instead of dead-center placement
Dark green-black gradient
```

Expected: the slab supports the composition without dominating it.

- [ ] **Step 3: Add restrained atmospheric overlays**

Insert soft green glow and edge-darkening overlays around the photo edges and lower corners.

Expected: the hosts separate more clearly from the background while the slab blends into the portraits more naturally.

### Task 4: Rebuild the title and logo for the new geometry

**Files:**
- Modify: `Paper document "TECHNOLGIA" / artboard "Thumbnail — The AI Bubble" (node id: 1-0)`

- [ ] **Step 1: Add a more assertive title banner**

Insert a black title banner that overlaps the composition asymmetrically rather than sitting in a centered safe block.

Expected: the title cut feels more intentional and energetic.

- [ ] **Step 2: Add the title text**

Create:

```text
THE AI BUBBLE
```

Expected: the title remains the clear hero and spans the banner strongly without fighting the host faces.

- [ ] **Step 3: Re-add the cleaned logo near the top**

Place the logo as a topmost layer after the slab is in place.

Expected: the logo reads clearly without being buried by the center geometry.

### Task 5: Rebuild the lower credit block as a secondary element

**Files:**
- Modify: `Paper document "TECHNOLGIA" / artboard "Thumbnail — The AI Bubble" (node id: 1-0)`

- [ ] **Step 1: Add the `WITH` row**

Create the arrow-plus-`WITH` line and keep it clearly secondary to the title.

Expected: the row reads cleanly but does not compete with the hero banner.

- [ ] **Step 2: Add a smaller green host-name plate**

Insert a slightly smaller green plate than the current version.

Expected: `TADIWA & ELVIS` feels sharper and more premium, not bulky.

- [ ] **Step 3: Add the host names**

Create:

```text
TADIWA & ELVIS
```

Expected: the lower block is readable, deliberate, and clearly secondary.

### Task 6: Polish and verify against the redesign goals

**Files:**
- Modify: `Paper document "TECHNOLGIA" / artboard "Thumbnail — The AI Bubble" (node id: 1-0)`
- Test: `Paper screenshot of node 1-0`

- [ ] **Step 1: Fine-tune asymmetry, depth, and overlap**

Adjust:

```text
slab width
slab offset
right-host inward crop
title overlap
credit-block size
edge darkness and glow intensity
```

Expected: the final composition feels more dynamic than the previous centered version.

- [ ] **Step 2: Capture a verification screenshot**

Run a Paper screenshot on node `1-0`.
Expected: the thumbnail reads as a stronger, more premium, more dynamic episode cover while keeping the existing identity.

- [ ] **Step 3: Record any remaining fidelity limits**

If any limitation remains because of Paper layer behavior or the underlying photo assets, note it explicitly in the handoff.
