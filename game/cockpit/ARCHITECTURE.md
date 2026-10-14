# RAVEN TWO: component boundaries

> Current exploration changes (heading-up bottom-center paper, locked acquisitions, whole-image resolving, approximate-range RWR and user-marked coordinate rounds) are described in `../../docs/PLAYABILITY.md`. Older measurements and original finite-mode contracts below are historical; the latest user corrections supersede them.


This is a small playable prototype, not a framework. Keep components together
when they have one job; split them when unrelated state starts sharing a lifecycle.
Do not solve maintainability by moving every method into another file.

## Data flow

```text
mouse / keys
    |
    v
cockpit_game.gd ------------------------- radar_link.gd
    |                                       |
    | commands                              | frozen pose + selected area + quality
    v                                       v
mission_state.gd                       private Python worker
    |       |                           (approved radar image formation)
    |       +-- navigation_route.gd          |
    |       +-- mission_tuning.gd             +-- image bytes + acquisition metadata
    |
    +-- bearing / strength only --> receiver_scope.gd --> left instrument
    +-- player route / chart intel -> paper_chart.gd ---> right rolling paper
    +-- radio / outcome events ----> flight_overlay.gd
    +-- visible instrument values -> cockpit_rig.gd

intro_sequence.gd -- phase snapshot / cue events --> controller --> lights / audio
cockpit_hardware.gd -- primitive meshes and moving controls --> cockpit_rig.gd
```

The image in the center CRT is only the returned radar texture through the
unchanged phosphor shader. Navigation, warnings, labels and mission UI do not
paint into that texture.

## Responsibilities

| Module | Owns | Must not own |
| --- | --- | --- |
| `cockpit_game.gd` | Composition, user intent, view updates, audio routing, lifecycle | Combat calculations, test scripts, radar implementation |
| `mission_state.gd` | Fictional game state, stores, pressure/damage, release/egress, event log | Scene nodes, file paths, textures, keyboard events |
| `navigation_route.gd` | Player waypoint queue, steering heading, crossing detection | Enemy intelligence or radar contacts |
| `mission_tuning.gd` / `default_mission.tres` | Explicit game-balancing values | Runtime results or physical weapon specifications |
| `intro_sequence.gd` | Deterministic intro timeline and once-only cue transitions | Camera, lights, sounds, mission effects |
| `flight_overlay.gd` | Captions, help/radio journal, debrief view and button signals | Mission mutation or enemy positions |
| `cockpit_rig.gd` | Native cockpit, live instrument surfaces, lamps/needles, projected hit tests | Mission progression and command permissions |
| `cockpit_hardware.gd` | Knobs, switch guards, keys, bezel, small metalwork | Flight state or weapon behavior |
| `paper_chart.gd` | Chart projection, scroll, uncertain areas, player-entered route | Exact SAM coordinates |
| `receiver_scope.gd` | Bearing traces and relative-strength indicator | Range or reconstructed target location |
| `radar_link.gd` | Owned process, request IDs, IPC, returned texture | Ground scene generation or flight state |
| `backend/mission_worker.py` | Mission world, chart generation, selected-area radar acquisition | Player UI or combat outcomes |
| `tests/cockpit_visual_driver.gd` | Projected input, capture, automated flight, measurement | Normal gameplay; loaded only with a test flag |

The controller and mesh builder have more lines than their old compressed forms
because statements are formatted normally. Line count is not a proxy for design
quality. The useful separation is that state/timeline/navigation are now runnable
and testable without a cockpit or GPU.

## Key contracts

1. **RWR privacy:** its contacts contain only `id`, `bearing`, `strength`,
   `tracking`. Do not pass through a mission-emitter dictionary.
2. **Paper is not radar:** it receives public uncertainty circles and the pilot's
   route. The drawn route is navigation selected by the player, not detected SAM
   positions. The scan frame is confined to paper.
3. **Acquisition is frozen:** the radar request contains one position/area/mode.
   A changed course does not silently warp an already stored radar image.
4. **One owned worker:** `radar_link` serializes requests and stops its child on
   restart/exit. Do not spawn a worker for every scan or add network dependencies.
5. **Reference imagery stays protected:** do not change the approved renderer,
   the phosphor shader or the RWR output schema to hide geometry/test failures.
6. **Terminal outcomes are terminal:** failure takes priority over egress if both
   happen in one update. A completed mission cannot consume stores again.
7. **Pause has reasons:** manual pause and modal help are independent. Closing
   help cannot release a user's manual pause. Modal/debrief input must not click
   through onto the 3D console.
8. **Deterministic timeline:** intro cues occur on time crossings, once each;
   skipped or large frames cannot duplicate authorization.
9. **Small simulation substeps:** state uses at most 50ms steps and swept waypoint
   crossing. The 30/144Hz test checks approximate trajectory agreement, not bitwise
   floating-point identity across frame rates.
10. **Complete reset:** `setup` must clear prior timers, stores, events and route;
    calling it on a used state is supported and tested.

## Typical changes

### Change pacing without rewriting the cockpit

Open `default_mission.tres` in Godot, or make a copy and assign it to the exported
`mission_tuning` property on the main scene. Edit turn/climb speed, waypoint
capture radius, fuel or placeholder threat/store parameters there. Keep claims
about real aircraft and weapon performance out of these game values.

### Add a gameplay mechanic

Implement state changes in `mission_state.gd` or a small cohesive state component.
Expose a command and an event. Add headless tests before wiring input and lamps.
The view should react to results, never decide them.

### Improve cockpit graphics

Edit `cockpit_rig.gd` for layout/light and `cockpit_hardware.gd` for physical
controls. Leave the radar texture untouched. Keep each control's hit rectangle
stable and verify it with projected mouse input after changing the mesh.

### Add large procedural areas later

Generalize the worker's world/area provider behind the existing request protocol.
The paper projection and public scene bounds will then need a versioned contract.
Do not scatter `2000`/world-limit replacements across arbitrary input/UI code.
The current finite 2km map is intentionally retained in this iteration.

## Tests and visual proof

```sh
python game/cockpit/tests/run_checks.py
python game/cockpit/tests/run_checks.py --visual --render-every-frame \
  --output "$PWD/.radar_runtime/cockpit_checks"
```

The second command requires a graphical desktop. It performs native radar scans,
clicks the actual projected chart/buttons, checks waypoints and pause behavior,
then flies the same mission to release and egress without moving the aircraft by
teleportation. It checks the debrief and writes the scene/instrument screenshots.
This is an **automated command-driven playthrough**, not a claim that a human
finished a balanced campaign.

Capture success is recorded only after a nonempty image was written. Background
windows may skip normal draws; the harness explicitly calls a native draw for
capture. `--render-every-frame` forces a render submission each test iteration,
so the reported loop interval cannot be mistaken for a headless/no-render test.
It can add work relative to a normal foreground game. JSON separates forced draw
count, normal draw count, loop intervals and radar calculation times. PNG writing
is synchronous and may dominate the maximum interval. These measurements are not
an isolated GPU benchmark.

## Formatting

The edited GDScript files use `gdformat` 4.5.0. This tool is development-only.

```sh
uvx --from gdtoolkit==4.5.0 gdformat --check \
  game/cockpit/cockpit_game.gd game/cockpit/cockpit_rig.gd \
  game/cockpit/cockpit_hardware.gd game/cockpit/mission_state.gd \
  game/cockpit/mission_tuning.gd game/cockpit/navigation_route.gd \
  game/cockpit/intro_sequence.gd game/cockpit/flight_overlay.gd \
  game/cockpit/paper_chart.gd game/cockpit/tests/test_flight_systems.gd \
  game/cockpit/tests/cockpit_visual_driver.gd
```

Tests and screenshots belong outside gameplay state. Generated runs and source
recovery snapshots are stored under the Git-ignored `.radar_runtime/` directory.

## Endless exploration extension

The current default is endless exploration; the old finite providers are retained for regression. Responsibilities added without moving terrain or flight mathematics into the UI:

| Module | Responsibility |
| --- | --- |
| `backend/endless_terrain.py` | World-coordinate terrain/material functions; no tile RNG or UI |
| `backend/endless_features.py` | Deterministic geographic feature ownership, bounded metadata cache |
| `backend/endless_world.py` | Assemble local radar fields and continuous chart sheets |
| `backend/chart_stream.py` | Lower-priority sheet-generation request channel |
| `radar_mailbox.gd` | Background disk transport and pixel decoding for both channels |
| `world_stream.gd` | Prefetch, installed-sheet state, retry and global/local conversion |
| `heading_control.gd` | Bounded angular velocity/acceleration toward a command |
| `chart_mechanism.gd` | Four native moving guide bars; geometry, not paper ink |

Main-thread scene objects are never mutated by Python or by the mailbox. A chart request is not considered installed until its complete image and manifest arrive. Rebasing changes local coordinates, not the stored global acquisition pose. The physical selector belongs to the instrument: paper rolls underneath it. Exact world points and chart overlaps are regression-tested.

See `docs/ENDLESS_FLIGHT.md` for the current measured implementation and `docs/USER_REQUESTS.md` for latest user intent. Old finite-scenario descriptions above are historical.
