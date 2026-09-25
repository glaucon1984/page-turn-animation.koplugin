# Page Turn Animation for KOReader

KOReader page-turn animation plugin for E-Ink devices, currently tuned around the Kindle Paperwhite 4 / Rex display path.

The installable plugin folder is `page-turn-animation.koplugin`. Its KOReader plugin ID is `pageturnanimation`.

Version **0.1.0** provides a fast configurable-step reveal with straight,
diagonal, several curved edge shapes, a mathematical reference-like hybrid,
and a GIF-derived page-flip mode.

## Installation

Copy the `page-turn-animation.koplugin` folder into KOReader's `plugins` directory and restart KOReader.

## How it works

For a normal one-page turn:

1. KOReader handles navigation and renders the destination page normally.
2. Page Turn Animation snapshots the old framebuffer before paint and captures the completed destination framebuffer immediately before the first physical refresh.
3. The destination is revealed in a configurable number of temporal steps: **3, 6, 12, 18, or 24**. The default remains **6**.
4. Each step submits only **one E-Ink update**. Straight mode uses a full-height strip. Shaped modes calculate the edge in 24 horizontal bands in RAM, then refresh one bounding rectangle around all newly revealed pixels.
5. After the animation the exact destination framebuffer is restored.
6. Normally one full-screen `refreshUI()` / AUTO settle is performed. Optionally, **Full clean refresh afterwards** replaces that settle with `refreshFull()` for stronger ghost cleanup. Before a flashing settle the plugin waits for every reveal update it submitted to finish on the panel, so the flash starts after the animation visibly ends. The **New chapter** setting can limit the cleanup to chapter boundaries, or replace the animation there with a plain flash.

### Rapid consecutive turns

Animation steps are scheduled individually, so KOReader can process input between
frames. If another eligible one-page turn arrives before the current one ends,
the plugin keeps the earlier turn alive underneath a new page layer. Each layer
continues to its own completion, and the framebuffer is composited from the
oldest page upward on every frame. This creates the intended layered,
quickly-turned-pages look instead of stopping the first animation in place.

The overlap is a framebuffer-level effect. The PW4 E-Ink controller can still
serialize or wait for individual waveform updates, particularly with AUTO/GC16;
DU or A2 usually gives the most responsive rapid-turn behavior, with more
ghosting tradeoffs.

## Reveal shapes

### Straight vertical

One vertical reveal edge moves across the page.

### Diagonal — bottom first

The bottom edge leads while the top lags, producing a diagonal page-turn edge. The lead is strongest around the middle of the animation and disappears at the end so top and bottom finish aligned.

### Curved bottom flip

Most of the edge remains close to vertical while the lower part bends sharply ahead. Fourth-power vertical weighting concentrates the lead near the bottom; the temporal envelope brings the edge back together at completion.

The shaped modes still issue only one physical panel update per animation step; the extra geometry is calculated in the framebuffer before each update.

### Reference-like hybrid

A mathematical approximation of the supplied hand-made outline. It combines a
small early lead with a soft middle bulge across the vertical edge profile.

### GIF-derived

**GIF page flip** uses the sampled outline as a moving boundary. It uses the
same interruptible scheduling as the mathematical shapes and can continue
under a later page turn.

## Page-turn animation settings

### Reveal shape

- **Straight vertical (default)**
- **Diagonal — bottom first**
- **Curved bottom flip**
- **Curved bottom flip 2**
- **Curved bottom flip 3**
- **Reference-like hybrid**
- **GIF page flip (experimental)**

### Waveform

- **AUTO / UI (default)** — uses `Screen:refreshUI()` for each reveal step. On Kindle Rex this is KOReader's AUTO/UI waveform path.
- **DU / Fast** — uses `Screen:refreshFast()`.
- **A2** — uses `Screen:refreshA2()`. Very fast on PW4 but can produce more ghosting.

### Scheduling

- **Free-running (default)** — submit a reveal step, then wait the configured delay.
- **Fixed interval** — target absolute step times from the start so rendering/submit overhead does not accumulate.

### Animation steps

Available values: **3, 6, 12, 18, and 24**. **6** is the default.

More steps make each reveal strip narrower and submit more E-Ink updates. With the same strip delay, more steps also increase the nominal animation duration.

### Strip delay

Available values: 0, 5, 10, 20, 30, 40, 50, 60, 80, and 100 ms. **40 ms** is the default.

### Full clean refresh afterwards

Disabled by default.

- **Off:** after the configured reveal updates, restore the exact destination and perform a full-screen `refreshUI()` / AUTO settle.
- **On:** restore the exact destination and call full-screen `refreshFull()` instead. This is intended for aggressive modes such as A2 when ghost cleanup matters more than the extra latency or visible flash.

Reveal updates are queued on the E-Ink controller asynchronously, and with many animation steps the panel is still drawing strips after the last one was submitted. Before a flashing `refreshFull()` the plugin therefore waits for every marker it submitted (not only the most recent one, which is all the framebuffer driver checks on its own), so the flash begins after the animation visibly finished. This wait blocks the UI loop for the remaining panel time, which is why the flashing settle is slower than the plain UI settle.

### New chapter

Chooses what happens when a one-page turn lands in a different chapter, in either direction. Every other page turn is unaffected.

- **Animate like any other page (default):** chapter boundaries are treated like any other page turn.
- **Animate, then full clean refresh:** play the animation, wait for the panel to finish every reveal step, then settle with full-screen `refreshFull()` instead of the UI/AUTO settle. Clears accumulated ghosting a few times per book without flashing on every page, at the cost of a slower chapter turn. If a second turn is stacked on top of a chapter turn before it finishes, the cleanup is still performed once the whole stack settles.
- **Refresh instead of animating:** skip the animation entirely on chapter boundaries. The plugin leaves the page repaint alone and promotes it to a flashing full refresh, exactly like KOReader's own **Always flash on chapter boundaries** option does. This is the fastest way to get a clean screen; the flash itself acts as the chapter-change transition. A reveal that is still running when the boundary is crossed is cancelled by the flash.

A chapter is a table-of-contents entry, using the same view of the ToC as KOReader's chapter navigation and progress-bar markers: ToC depths hidden with **Progress bars → chapter markers** are ignored here too. Documents without a ToC never trigger it.

Note that KOReader's own **Always flash on chapter boundaries** and its periodic full refresh are requests for a full refresh on the intercepted page repaint, which this plugin replaces with its own animation and settle. Use this setting (or **Full clean refresh afterwards**) to get a full refresh on animated turns.

## Menu

1. **Animate normal page turns**
2. **Page-turn animation settings**
   - Reveal shape
   - Waveform
   - Scheduling
   - Animation steps
   - Strip delay
   - Full clean refresh afterwards
   - New chapter
3. **Test animated next page**
4. **Test animated previous page**
5. **update plugin**

## Normal navigation

KOReader still handles taps, swipes, page-turn keys, RTL/inverse reading order, and document navigation normally. Page Turn Animation only records the direction for eligible one-page turns and performs the transition later in the framebuffer repaint lifecycle.

Internal `no_page_turn` calls and multi-page jumps are left alone.

## Self-update

**update plugin** remains the final menu item. It updates only `page-turn-animation.koplugin` from this repository's `main` branch, verifies revision/blob integrity, syntax-checks downloaded Lua, stages the replacement, retains a rollback backup, and offers to restart KOReader.
## Attribution

This plugin is based on the KOReader page-animation plugin found in the [r/kindlejailbreak Reddit thread](https://old.reddit.com/r/kindlejailbreak/comments/1um8v2i/page_animation_for_kpw4_koreader/).
