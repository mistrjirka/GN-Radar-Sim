# Cockpit code boundaries

> Current exploration changes (heading-up bottom-center paper, locked acquisitions, whole-image resolving, approximate-range RWR and user-marked coordinate rounds) are described in `PLAYABILITY.md`. Older measurements and original finite-mode contracts below are historical; the latest user corrections supersede them.


The design requirements are in [USER_REQUESTS.md](USER_REQUESTS.md). Runtime controls and measured build status belong in [the cockpit README](../game/cockpit/README.md). This document describes the code, not additional user requirements.

## Runtime flow

```text
mouse / keys -> cockpit_game -> mission_state -> filtered instrument data
                   |                 |
                   |                 +-> navigation_route / mission_tuning
                   +-> intro_sequence -> rig lights, shutters, audio cues
                   +-> flight_overlay (notes, radio journal, flight record)
                   +-> radar_link -> Python mission_worker -> approved_renderer
                                           |
                                   frozen scan + grayscale bytes
```

`cockpit_game.gd` connects components and translates input into intent. It should not grow a second renderer, duplicate mission rules, or contain screenshot-test sequencing.

## Component responsibilities

| Component | Owns | Must not own |
| --- | --- | --- |
| `mission_state.gd` | Mission lifecycle, inventories, fictional threat pressure, radio journal, flight record | Godot scene nodes, file paths, player input events, drawing |
| `mission_tuning.gd` and `default_mission.tres` | Editable prototype constants | Sensor physics or confirmed real-world performance claims |
| `navigation_route.gd` | Ordered player-entered fixes, heading and waypoint crossing | Enemy positions, radar targeting or scan selection |
| `intro_sequence.gd` | Timeline state and one-shot cues | Lights, camera, audio players or scene loading |
| `cockpit_rig.gd` | Native geometry, physical controls, lamps, camera and live instrument surfaces | Win/fail rules, radar computation |
| `paper_chart.gd` | World-to-paper projection, rolling chart, uncertain intel, player route and scan frame | Exact unobserved emitter locations |
| `receiver_scope.gd` | Bearing traces, brightness and strength meter | Emitter range or world coordinates |
| `flight_overlay.gd` | Captions, flight notes, radio-history display and debrief | Mutating mission state; it emits button intent instead |
| `radar_link.gd` | Owned worker lifecycle, request IDs and completed texture handoff | Synchronous multi-second radar work on the main thread |
| `backend/mission_worker.py` | Scene preparation, chart generation, selected-area acquisition | Direct manipulation of cockpit UI nodes |
| `tests/cockpit_visual_driver.gd` | Screenshot and projected-click integration tests, only under `--cockpit-test` | Ordinary gameplay behavior |

These are a few explicit script boundaries, not an event-bus framework. Keep local logic local until it has a genuinely separate responsibility.

## Invariants to preserve

- The center CRT displays radar returns only. Route, selection frame and intelligence annotations stay on paper.
- The RWR receives the narrow `receiver_contacts()` result: ID, bearing, strength and tracking. Do not pass the full emitter dictionary to its renderer.
- A completed radar frame retains its acquisition position, region, quality and request ID. Chart movement must not imply that stored radar returns are live.
- The approved source-preserving renderer and its image fixture remain the visual regression baseline. More complex processing is not automatically a better replacement.
- Mission rules are provisional game mechanics. Terrain scale, weapon timings and inventories have not become design requirements just because they exist in code.
- Pausing or opening notes stops mission progression; closing notes must not override an independently requested pause.
- Restart clears previous route, journal, stores, warning state and timers. Repeated intro completion must not issue the mission order twice.

## Verification before reporting a change

Run the relevant pure-state tests, the existing cockpit backend tests, and the original radar regressions when acquisition changes. Import the Godot project to catch parse/resource failures. Use a separate capture directory per visual run so screenshots cannot be mistaken for a newer build.

Open actual screenshots after execution: normal station, rolling chart, receiver and raw radar. For navigation/UI changes also inspect the pencilled route, flight notes and debrief. Mark synthetic state tests separately from a genuinely flown mission. A process exit code alone is not a visual acceptance test.

Report what changed, what was exercised, and what remains provisional. Keep measured scan time, frame intervals, screenshot-encoding pauses and terrain-generation time separate.

## Endless open-flight mechanism (latest)

The normal game selects `endless`; finite `sortie` and `reference` remain optional. See `ENDLESS_FLIGHT.md` for current behavior.

- `endless_terrain.py` evaluates double-precision geographic coordinates into local height/material fields. `endless_features.py` owns deterministic feature cells with bounded metadata caching. `endless_world.py` produces selected radar patches and rolling chart sheets, not an unbounded in-memory atlas.
- `chart_stream.py` services background sheet requests between radar jobs. `radar_mailbox.gd` owns file publication/status/image reads on its thread; `radar_link.gd` creates textures on the main thread and retains strict request IDs for each channel.
- `world_stream.gd` prefetches chart sections, transforms public chart/private state coordinates separately, and follows floating-origin shifts. It does not generate terrain or decide enemy visibility.
- `heading_control.gd` changes turn rate gradually; `mission_state.gd` owns current/commanded headings and the double global origin. Setting a direction does not assign the actual heading.
- `chart_mechanism.gd` builds four physical bars. `paper_chart.gd` supplies their positions and computes the geographic area under them; no selector is added to the radar image.
- Resolution and area labels belong to the bezel. They select explicit lower/higher-detail calculations, not a fake wait timer. The approved renderer and receiver schema stay protected.

The perpetual-exploration mode bypasses fuel/mission-boundary termination and lethal damage as a provisional mechanism-testing choice. Finite modes keep their previous gameplay rules and tests.
