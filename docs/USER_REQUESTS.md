# User requests — bomber radar game

Recorded 2026-10-14 from the user's requests and corrections in the development conversation. This is a design record, not a claim that every item is implemented. Wording below is paraphrased except for the short quotations. Update this file when the user changes a requirement; keep implementation progress in `game/cockpit/README.md` and test reports.

## The game the user wants

The player is the **weapons officer in a bomber**, with the pilot visible ahead. Turn the radar simulation into an atmospheric, playable cockpit game rather than leaving it as a technical demo.

The opening sequence is: a view out of the cockpit, a sudden bright flash, protective shutters closing over the windows, then complete darkness. The player looks toward the pilot; a red **DEFCON 1** warning illuminates behind/near him. Ground control orders release of the aircraft's nuclear payload against a predesignated fictional target. Main gameplay takes place in the shut, mostly dark cockpit under red background/emergency lighting.

Navigate a procedurally generated map toward the objective. Avoid SAM sites or fire back using ARM weapons. The exact missile mechanics are deliberately deferred: use simple, replaceable gameplay rules where the user has not yet decided. Do not turn temporary rules into final design decisions.

## The three instruments — latest layout wins

**Left: radar warning receiver. Center: ground-mapping radar. Right: rolling paper map.**

The first description put paper on the left and RWR on the right. The later correction explicitly put the rolling paper map on the **right**, and the user subsequently approved the implemented left-RWR/center-radar/right-paper cockpit. The earlier layout and generated concept image are not the current layout specification.

### Center radar: the image, not a digital interface

The user asked for “basically purely display from the radar” and “no squares around it unless I decide later.” Draw radar returns on a phosphor screen. Do not add selection rectangles, target boxes, crosshairs, exact target labels, coordinate readouts, or menus over the radar image. Physical switches, labels and lamps can live on the surrounding panel.

Preserve the finally approved radar appearance. It must look like ground-mapping radar, not LiDAR, an optical map with noise, or a smooth collection of white blobs. Terrain clutter should have structure; bridges, warehouse faces and SAM equipment must be readable. Bright-reflector sidelobes and multipath-like effects are welcome when credible and useful, not as justification for numerical artifacts.

Earlier experiments used black-and-white imagery. The subsequent cockpit request adds a phosphor display: monochrome return intensity can be tinted for the CRT. That is not permission for multicolored target overlays.

### Right map: physical moving paper

Use an illuminated, mechanical scrolling chart inspired by the supplied analog moving-map photograph: paper, rollers and backlighting, not another glass digital display. Roll the paper according to actual flight movement/path.

Let the player move a square or another scan-selection shape **on the paper map**, then press a button to scan that geographic area. The exact selector shape is not final. The selection belongs on the chart, not on the radar CRT.

Mark **suspected** SAM areas with broad circles and uncertainty. Do not reveal precise site locations through the intelligence markings. The user did not request a live enemy-position minimap.

### Left receiver: bearing and strength, not range

The first concept-art RWR was rejected as not looking like an RWR. Use an older-style, believable dedicated warning instrument. Show signal direction/bearing and strength, but **no estimated world position or distance** of the emitter. Do not present range-positioned contacts like a modern tactical map.

The specific historical receiver model, exact symbology and hardware layout have not been selected. The current fictional bearing traces and separate strength meter are an implementation choice, not a specification for a named real receiver.

## Terrain, models and integration

Integrate the accepted simulator into the existing Godot game on **homer**, in `~/programovani/GN-Radar-Sim`. Keep previous work accessible instead of replacing it with an unrelated demo.

Improve procedural terrain generation and use shared world data for normal-camera views and radar acquisition. The user wants to travel through a generated map, not only inspect a static test patch. A streamed long-distance map is a future implementation option; no particular streaming algorithm or map size has been specified.

Bring the **earlier preferred vehicle and radar models** into Godot, and inspect their radar signatures too. The requested test arrangement includes one central radar with roughly six surrounding launchers, warehouses, and a bridge over a river. Retain recognizable object geometry and compare how terrain, dimensions and material choices affect the radar returns.

Provide a validation screen that recreates previously tested terrain and compares against the earlier images. Distinguish unchanged-reference replay from the expected image changes caused by different models, terrain or radar settings. A model or scene change must not be described as pixel-identical merely because the renderer stayed the same.

## Performance and acquisition

The user explicitly corrected the initial streaming assumption: **approximately one radar frame every 10 seconds**, with configurable resolution and computation time that depends on that resolution. A 20-fps radar feed is not required. The cockpit, flight controls and paper map should remain interactive while a scan is calculated.

Normal computers or GPUs should be a feasible target. A slower reference implementation is acceptable during research, followed by optimization. Measure actual computation and transfer latency; separate terrain generation/cache time, scan time, screenshot encoding and frame time. Do not present one machine's timings as universal guarantees.

## What the user approved, and what was rejected

The user preferred the original Gemini SAM imagery and the earlier coherent bridge/warehouse structure. Repeatedly rejected: smoothing/blob-shaped returns, missing occlusion, visible back-facing walls, unexplained radial/diagonal streaks, and claims of realism based only on a more elaborate algorithm.

The decisive approval was for the **`realism_revision` source-preserving/statistical radar candidate**: “That is finally what I wanted.” That approved appearance was subsequently integrated into Godot. Do not silently return to the earlier raw-pulse/FP64 experimental renderer simply because it sounds more physical. Preserve the approved reference and test any replacement against it.

The user later approved the first playable cockpit build and authorized continued development. This approves its direction, not every provisional weapon number, art asset or implementation limitation.

## How development should be done

The user explicitly requested maintainable code, not a “spaghetti mess.” Keep responsibilities understandable and separate where they genuinely differ: mission state, cockpit presentation, chart projection, receiver display, radar acquisition and validation. Do not add frameworks or abstractions just for their own sake.

Take screenshots periodically, **open and inspect them**, then iterate on the visuals. Review the exact images being shown to the user. A successful render command, a file existing, or an automated test passing does not establish that an image looks correct. Show genuine game captures when reporting implemented work; label AI-generated concept art separately.

The user asked for subagent/code audits when investigating the bad radar results. Use independent review where it helps, verify findings against the code and tests, and do not imply that an audit alone validated visual or physical correctness.

For physics and rendering investigations, the earlier explicit requests included:
- pure terrain/renderer crossover comparisons: use each scene with the other renderer, preserve the original renderer's decisions/constants, map materials transparently, and separate strict swaps from later tuning;
- inspect both scenes and multiple variants, not only the best-looking crop;
- test different elevation angles and check shadow movement;
- inspect isolated point responses, distinguish physical sidelobes from sampling/precision bugs, and correct earlier conclusions when evidence changes;
- use real normal-camera **renders**, not generated AI images, when comparing the terrain;
- transfer screenshots from the connected computer into the chat and verify the files are actually viewable.

Finally: **write the requests down** so they survive future work and do not depend on remembering this conversation. This file is that record.

## Explicitly open or provisional

Not settled by the user: missile/seeker trajectories, ARM timing, damage and countermeasure probabilities, inventories, weapon ranges, nuclear delivery mechanics, flight dynamics, exact target size, terrain scale/streaming, mission length, progression, and campaign structure.

Current implementation names and numbers—including RAVEN TWO, target ZULU, a 2km test region, available range settings, key bindings, a simple release-zone trigger and timed emitter suppression—are **developer placeholders** unless the user later makes them requirements. Reduced-flash mode, egress/win/fail states, receiver trace style and local speech assets are useful current choices, not independent user demands.

Do not silently fill these gaps with real-world weapon specifications or infer final mechanics from the concept image.

## Acceptance checklist for future changes

1. The latest left-RWR / center-radar / right-paper layout remains intact.
2. The CRT contains only radar returns; the selection frame remains on paper.
3. The map moves with the aircraft and intelligence circles do not reveal exact emitter positions.
4. The receiver display gets bearing/strength, not hidden simulation positions/ranges.
5. Radar geometry, materials and selected geographic area remain connected to the shared scene.
6. Reference images, geometry tests and affected gameplay checks are run; new screenshots are visually inspected.
7. User requests, measured status and provisional mechanics remain separate in documentation.
8. Prototype limitations and known visual issues are reported without claiming they are fixed.

### Change record

- 2026-10-14: collected the requests above from the supplied development conversation, including the screen-layout correction, approved image direction, screenshot-review practice and maintainability request. This is a curated record of the available conversation, not a verbatim archive of every prior exchange.

## Continuation: larger game and smooth play

- The user reaffirmed that the plan goes beyond the cockpit tech demo: continue the actual procedural journey, uncertain threats and complete mission loop.
- During this continuation the user explicitly asked to look for freezes during all gameplay phases and avoid lag. Measure real frame intervals around loading, radar replacement, UI transitions and completion. Keep screenshot-encoding stalls separate from normal play.
- The current 12 × 18 km finite region, suggested routes and provisional pacing are implementation choices, not newly claimed user requirements. Preserve the approved radar and reference mode while testing this expansion.

- 2026-10-14 (terrain/performance follow-up): explicitly prioritize procedural terrain, investigate faster scanning without losing the approved appearance, and measure/fix freezes across gameplay stages rather than relying on average FPS. Keep calculations, transfer, main-thread work and screenshot costs separate.

## Latest correction: endless mechanism first

The user explicitly replaces the finite sortie requirement for current development: the default game should be endless procedural flight, with new terrain generated continuously and meaningful visual quality. Keep bounded memory/work, not a giant finite map disguised as infinite. The finite mission remains optional regression content.

Make scan resolution visible/selectable at the radar instrument, trading slower detailed scans against faster coarse scans. Keep area size separately adjustable. The paper selector must have exactly four edge-to-edge physical bars: two horizontal, two vertical, intersecting to define the square and extending to the instrument sides. Show mechanical sliders, not a floating digital rectangle.

The player chooses the direction the aircraft should fly. The commanded heading is not the current heading: the aircraft must turn progressively and follow a curved path, with no instantaneous rotation.

## Infinite exploration clarification — latest request supersedes finite sortie

- For now the playable mode should be infinite procedural exploration: prove continuous world generation with reasonable landscape quality, not a finite objective-to-egress mission. Keep prior scenarios accessible.
- Show a usable resolution selector on the radar hardware, with faster/coarser and slower/finer choices. Continue to keep the actual radar CRT free of overlays unless explicitly changed.
- Make scan-area width adjustable independently of resolution. Four mechanical guides span the paper edge-to-edge: two vertical, two horizontal, forming the acquisition square where they intersect. These are physical guide members, not a floating digital rectangle.
- The player chooses the direction for the pilot to fly. The aircraft must turn gradually; commanded heading and actual heading must not snap together.
- Prior requirements still apply: inspect actual screenshots, keep code maintainable, preserve accepted radar imagery, and measure any streaming/scan hitches.
