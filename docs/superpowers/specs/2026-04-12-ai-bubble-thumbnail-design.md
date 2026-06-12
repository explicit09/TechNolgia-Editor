# AI Bubble Thumbnail Design

## Goal

Overwrite the existing `Thumbnail — The AI Bubble` Paper artboard with an almost exact recreation of the supplied reference image while reusing the local host-photo and logo assets that already exist on the board.

## Scope

In scope:

- Rebuild the current `1280x720` thumbnail artboard in Paper
- Reuse the existing left host photo, right host photo, and `TECHNOLGIA` logo image assets
- Match the reference composition, text hierarchy, color treatment, and atmosphere as closely as the available assets allow

Out of scope:

- Creating new source photography or logo assets
- Changing the episode title or host names
- Creating alternate thumbnail variants

## Approved Direction

Use a clean rebuild on the existing artboard instead of incrementally adjusting the current layout.

Reasoning:

- The current artboard structure is materially different from the reference
- A rebuild produces tighter alignment and cleaner masking
- Reusing the existing asset nodes preserves editability without tracing the entire reference as a flat image

## Layout

The final composition uses three dominant zones:

1. A full-height left photo panel
2. A full-height right photo panel
3. A centered dark trapezoid slab that overlaps both photo panels

Supporting elements:

- `TECHNOLGIA` logo near the top center
- Large black horizontal title banner across the middle
- Lower center credit area with a small arrow, `WITH`, and a green host-name plate
- Soft green glow and haze near the lower corners and side edges

## Asset Treatment

### Left Photo

- Reuse the existing left host photo asset already present on the artboard
- Scale/crop to fill the left side edge-to-edge
- Position to preserve the subject's face and microphone framing similar to the reference

### Right Photo

- Reuse the existing right host photo asset already present on the artboard
- Scale/crop to fill the right side edge-to-edge
- Position to preserve the subject's face and desk/mic framing similar to the reference

### Logo

- Reuse the existing `TECHNOLGIA` logo asset
- Keep it centered near the top of the dark center area
- Preserve the logo as an image layer rather than redrawing it as text

## Typography

### Main Title

- Text: `THE AI BUBBLE`
- Style: bold, condensed, white, all caps
- Placement: centered inside a solid black horizontal banner spanning the center composition

### Credit Row

- Small white arrow glyph followed by `WITH`
- Separate green rectangular nameplate below for `TADIWA & ELVIS`
- White condensed all-caps text for the host names

## Color and Atmosphere

- Center slab: near-black with subtle green influence
- Title banner: solid black
- Nameplate: saturated green matching the reference mood
- Lighting: green ambient glow/fog concentrated in lower corners and side edges
- Contrast: center kept darker than photo sides so logo, title, and credit remain legible

## Layering Strategy

From back to front:

1. Left and right photo panels
2. Dark center trapezoid slab
3. Atmosphere/glow overlays
4. Top logo
5. Title banner
6. Title text
7. Credit arrow and `WITH`
8. Green host-name plate
9. Host-name text

## Constraints

- Overwrite the existing artboard rather than duplicating it
- Keep the result fully editable in Paper
- Do not introduce extra decorative elements not present in the reference
- Match the reference composition as closely as practical with the existing assets

## Validation

The design is successful when:

- The thumbnail reads as the same composition at a glance as the supplied reference
- The title, logo, and host-credit hierarchy align on the center axis
- The left/right photo balance and the dark center slab match the reference proportions
- The green atmosphere enhances the image without reducing readability
