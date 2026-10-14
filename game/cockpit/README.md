# RAVEN TWO — playable bomber sortie

> **Current default: endless exploration.** The latest request supersedes the finite sortie below. Run `./play-cockpit.sh` for continuous generated terrain, four physical scan guides, visible resolution controls and gradual heading commands. See [ENDLESS_FLIGHT.md](../../docs/ENDLESS_FLIGHT.md) for current controls, limits and validation. `--sortie` and `--reference` retain the older scenarios.


> **Current default: endless open flight.** Terrain and paper continue generating without a mission edge. The radar bezel has visible RES/AREA settings, the paper has four native mechanical guide bars, and heading commands produce gradual turns. See [ENDLESS_FLIGHT.md](../../docs/ENDLESS_FLIGHT.md) for current controls and limits. Use `--sortie` or `--reference` for the finite scenarios described below.


> **Latest terrain/performance update:** The default now uses the 12 × 18 km procedural sortie, with exact-output CPU scan acceleration and background chart decoding. See [the measured report](../../docs/TERRAIN_AND_PERFORMANCE.md). Earlier 2 km descriptions below are historical; use `--reference` for that scene.


Project: `~/programovani/GN-Radar-Sim` on **homer**. Branch: `jirka-cockpit-game`.
Requirements and corrections: [`docs/USER_REQUESTS.md`](../../docs/USER_REQUESTS.md).

```sh
cd ~/programovani/GN-Radar-Sim
./play-cockpit.sh
```

The normal launch now starts a **12 × 18 km seeded sortie**, not the old stationary 2km patch. To retain the previous cockpit test scenario:

```sh
./play-cockpit.sh -- --reference
```

The original terrain/radar validation lab remains available through `./play-radar.sh`. No cloud service, language model or MCP server runs inside the game.

## Current game loop

The player is the weapons officer behind the pilot. The exterior view, single flash, physical closing shutters, blackout, red lighting, DEFCON 1 and radio order are retained. Reduced-flash mode is on by default.

After the order, **B** opens a paper sortie briefing. It contains the terrain, charted objective/egress, uncertain intelligence circles, and two pencilled route suggestions. A suggestion is not a guaranteed safe route or a path computed from hidden enemy positions. The player can accept it or enter navigation fixes directly on the moving paper.

The new region has continuous seeded relief, river crossings, fields, woodland, warehouses and seven emplacements with six launchers around each radar. Two further intelligence reports need not contain a site. Only uncertain circles—not exact emitter coordinates—reach the chart/briefing views. Their number and the region dimensions are current prototype choices, not final user-specified balance.

Fly toward ZULU, use radar/RWR/chart together, avoid or suppress threats using the existing provisional rules, complete the manual game objective, then reach egress. Flight notes retain the received radio journal; the final flight record shows distance, time, scans, stores, damage and remaining fuel.

The latest automated mission runs flew the entire route through ordinary state updates without teleporting the aircraft or granting free stores. Test harnesses may accelerate simulation time; they are not claims of a manually played campaign.

## Instruments

**Left — RWR:** bearing traces plus relative strength. Its interface contains ID, bearing, strength and tracking only. No target position, estimated range or modern tactical map.

**Center — radar:** the approved statistical image-formation renderer, tinted by the existing phosphor shader. No target boxes, crosshairs, coordinates or menus inside the CRT. Stored returns remain from the frozen acquisition pose until a new frame arrives. Physical FRAME/STORED/TX lamps communicate the state outside the image.

**Right — paper:** terrain contours, river/roads, uncertain threat circles, player-entered route and a paper-only selection frame. The sheet and rollers move with flight. Paper scale and radar-area size are independent. The full-region briefing is separate from the three instrument faces.

## Controls

| Input | Action |
| --- | --- |
| B | Open/close sortie briefing; give a pencilled route to the pilot |
| Click paper | Move radar scan selection |
| Shift-click paper | Replace the pilot's route |
| Ctrl+Shift-click / Delete | Append a fix / remove the last fix |
| Z | Change paper scale without changing radar resolution or selected area |
| Wheel over paper / RANGE | Cycle scan extent: 600, 1000, 1600, 2000, 3200 or 4000m in sortie mode |
| Space / SCAN | Acquire the selected geographic area |
| 1 / 2 / 3 | Survey / map / detail instrument response |
| A/D · Q/E · W/S | Command heading · altitude · speed |
| C · M · F · X | Select emitter · master arm · placeholder ARM · countermeasure |
| Enter | Complete the authorized game objective inside the designated area |
| F1/F2/F3 · F4 | Inspect an instrument · return to normal view |
| Right-drag | Look around |
| H or Esc · P | Flight notes · pause |
| Backspace · F8 | Skip intro · reduced-flash option |
| R · N | Replay seed · new seed |

## World and radar boundaries

`SortieRegion` stores a small seeded region description. Global-coordinate noise, roads, buildings and emplacement records generate actual selected-area height/material/reflector fields when requested. The sampler is independent of crop order; it does not repeat or stretch the old map. A three-patch memory cache is bounded. The paper atlas uses the same terrain definitions but never rasterizes the private emitter list.

The renderer and its old approved image fixture are unchanged. A new region necessarily produces different images; that is not described as an exact replay of the old terrain. `--reference` and the original radar lab retain the regression path.

The model remains **statistical/2.5D**, not a full electromagnetic mesh simulation. Vehicle dimensions and mast signatures are represented by physical footprint/height/material proxies; small lattice and wheel details are approximate. Shadows from terrain outside the requested measurement patch are not a full long-range scene solution.

The region is finite, not an infinite streamed campaign. Fine geometry is generated only for the radar patch; it is not all held as a giant high-resolution 3D atlas. The cockpit's initial exterior artwork and pilot remain first-pass assets.

Image grids are capped at 1536² samples. A 4000m area therefore has coarser world sampling than a 2000m area; selecting Detail cannot recover geometry lost to that coarser grid. Narrower scans resolve smaller structures better.

## Smooth-play work

Radar generation remains in one privately owned Python worker. Completed scans are transferred as raw grayscale bytes rather than decoded PNG images on the game thread. Request publication, status and raw-frame reads also run in the owned background mailbox. Paper texture decoding now has its own owned background loader; Godot only creates/uploads the completed texture on the main thread. Ordinary play does not save screenshots or frame traces.

The initial profiler found a 70ms frame on chart arrival, with 52ms in synchronous chart decoding/preparation. Moving decoding off-thread reduced the corresponding measured run's worst frame to 28.5ms; normal flight/UI frames stayed below 19ms on the tested machine. Detailed final measurements, scope and remaining startup work are recorded in `docs/PERFORMANCE.md`.

Screenshots synchronously read back/encode the viewport and can stall test runs. Performance runs disable all captures. Do not compare their frame maxima without noting this difference.

## Code ownership

- `cockpit_game.gd`: connects input, mission and presentation; no terrain generation.
- `mission_state.gd`, `navigation_route.gd`: pure game state and player-authored route.
- `mission_tuning.gd`, `default_mission.tres`, `sortie_mission.tres`: provisional balancing constants.
- `intro_sequence.gd`: one-shot intro timeline; no rendering logic.
- `cockpit_rig.gd`, `cockpit_hardware.gd`: physical meshes, lights and switches.
- `paper_chart.gd`, `receiver_scope.gd`: narrowly filtered instrument data.
- `sortie_briefing.gd`, `briefing_chart.gd`: public briefing and route-choice intent.
- `flight_overlay.gd`: notes, received radio and flight record.
- `chart_loader.gd`: background paper decode and owned-thread cleanup.
- `radar_link.gd`, `radar_mailbox.gd`: worker lifecycle, background file transport and frame handoff.
- `backend/mission_worker.py`: protocol and scenario/scan orchestration.
- `backend/sortie_region.py`, `region_noise.py`, `region_features.py`: region definition, coordinate fields and physical features.
- `tests/`: unit, full-sortie, visual and frame-time drivers; loaded only by explicit test flags.

## Verification commands

```sh
godot --headless --path . --check-only --script game/cockpit/cockpit_game.gd
godot --headless --path . --script game/cockpit/tests/test_mission.gd
godot --headless --path . --script game/cockpit/tests/test_resume_invariants.gd
godot --headless --path . --script game/cockpit/tests/test_chart_loading.gd
python -m unittest discover -s game/cockpit/tests -p 'test_*.py' -v
python -m unittest discover -s game/radar/tests -v

# Previous reference-scene clicks, real scans and screenshots.
godot --path . -- --cockpit-test --capture-dir=/absolute/path/reference_run
python game/cockpit/tests/verify_visual_run.py /absolute/path/reference_run

# New full sortie (test-time acceleration; no position teleports).
godot --path . -- --sortie-test --capture-dir=/absolute/path/sortie_run

# Real-time frame profile: repeated scans/menus; NO screenshots.
godot --path . -- --performance-test --perf-seconds=90 --capture-dir=/absolute/path/profile
python game/cockpit/tests/analyze_frame_trace.py /absolute/path/profile
```

Exact missile/seeker dynamics, ARM timings, damage, release and inventory rules remain fictional placeholders. Region scale, route suggestions, pacing and mission writing can be revised independently of the renderer and cockpit art.
