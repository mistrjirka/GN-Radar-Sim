> Latest user correction: endless open flight is now the default. The finite-region milestones below are historical; current implementation is described in `ENDLESS_FLIGHT.md`.

# Bomber game: progression from the user's design

Requirements live in `USER_REQUESTS.md`; this is an implementation roadmap, not a replacement specification. Runtime constants remain provisional.

## Current playable chain

The weapons officer sees the exterior, flash, closing shutters, blackout, DEFCON 1 and the received order. The three instruments stay in the approved layout: bearing/strength-only RWR, returns-only radar CRT, rolling physical chart. The player chooses an area on paper and requests an actual radar acquisition.

The new sortie region is 12 × 18 km rather than the earlier 2km inspection patch. Terrain noise is keyed to global coordinates. Scan requests generate the needed terrain/material/reflector patch instead of stretching the old map or constructing a huge fine-resolution atlas. There are seeded SAM emplacements, bridge crossings, warehouses, a charted objective and an egress destination. The paper atlas and radar read the same procedural terrain definitions.

A briefing sheet exposes only public geography, offset suspected areas and pencilled route suggestions. The player can use those suggestions or enter fixes manually. Route following, threat pressure, finite ARM/countermeasures, manual objective completion, egress, and an end-of-flight record form the current loop. None of the two suggested routes is guaranteed safe.

## Completed milestones and acceptance evidence

| User intent | Implemented next step | Evidence to retain |
| --- | --- | --- |
| More than a stationary tech demo | Finite seeded region and complete return flight | `test_sortie_mission.gd`, flown route records |
| Paper moves with flight | Region-aware projection and independent paper scale | Chart round trips and in-game captures |
| Radar scans the selected place | On-demand real world fields anywhere in the region | `test_sortie_region.py`, distinct-region scans |
| Uncertain enemy intelligence | Public briefing excludes exact site records | Public-data and chart-invariance tests |
| Maintainable code | World noise, features, mission state, UI and background loading are separate | `ARCHITECTURE.md` |
| No gameplay freezes | Wall-frame trace with event spans, screenshots disabled | `frame_probe.gd`, `performance_driver.gd`, trace summaries |
| Review visual quality | Capture and open actual cockpit, briefing and flight record images | Separate new capture directories |

## Still intentionally open

1. Combat remains the simple abstract mechanic authorized for prototyping. Do not invent final missile flight/seeker rules or real weapon delivery procedures.
2. This is a finite sortie region, not an infinite world or campaign. The cockpit exterior and pilot artwork remain first-pass.
3. The new terrain generator must continue to be judged visually against the approved radar style. An unchanged renderer does not make a changed terrain scene pixel-identical to the old fixture.
4. The statistical/2.5D radar does not trace every rendered wheel, lattice bar or radome electromagnetically. Off-patch occlusion and long-range scenery remain approximation limits.
5. Suggested routes and current timings are developer choices. Manual playtesting across more seeds, difficulty tuning, richer radio exchanges and in-world controls remain subsequent work.
6. Frame-time measurements apply to the tested host, viewport, renderer and run. Screenshot readback/encoding is intentionally excluded from normal-game profiling and must not be silently dropped from capture-run reports.

## Next after this pass

Use ordinary playthroughs to tune route tradeoffs and the amount of information available from radar/RWR/chart together. Improve cockpit model/material detail without adding digital target markers or losing the accepted instrument readability. Keep the short reference scene accessible for image regressions.
