#!/usr/bin/env python3
"""Repeatable cockpit checks; refuses to call a missing PNG a successful capture.

Run with the same Python environment used by play-cockpit.sh.
  python game/cockpit/tests/run_checks.py
  python game/cockpit/tests/run_checks.py --visual --output /absolute/capture/path

The visual run needs a usable desktop DISPLAY. It flies a complete fictional
mission using normal game commands and checks real scans, chart clicks and egress.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys

REPO = Path(__file__).resolve().parents[3]
TESTS = [
    ('mission', ['godot', '--headless', '--path', '.', '--script', 'game/cockpit/tests/test_mission.gd'], 20),
    ('flight_systems', ['godot', '--headless', '--path', '.', '--script', 'game/cockpit/tests/test_flight_systems.gd'], 35),
    ('cockpit_backend', [sys.executable, '-m', 'unittest', 'discover', '-s', 'game/cockpit/tests', '-v'], 9),
    ('approved_radar', [sys.executable, '-m', 'unittest', 'discover', '-s', 'game/radar/tests', '-v'], 11),
]


def run(name: str, command: list[str], output: Path, env: dict, timeout: int = 180) -> str:
    print(f'RUN {name}', flush=True)
    result = subprocess.run(command, cwd=REPO, env=env, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout)
    (output / f'{name}.log').write_text(result.stdout)
    errors = [line for line in result.stdout.splitlines()
              if 'SCRIPT ERROR:' in line or 'ERROR:' in line or 'FAIL ' in line]
    if result.returncode or errors:
        raise RuntimeError(f'{name} failed (exit {result.returncode}): {errors[:5]}; see {output}')
    return result.stdout


def verify_visual(output: Path) -> dict:
    data = json.loads((output / 'game_test.json').read_text())
    for field in ('intro_complete', 'second_scan_requested', 'arm_launched', 'countermeasure',
                  'selected_emitter_suppressed', 'release_outside_inhibited',
                  'route_via_projected_clicks', 'help_preserves_pause', 'debrief_visible'):
        if data.get(field) is not True:
            raise AssertionError(f'Visual check failed: {field}')
    if data.get('timeout') or data.get('capture_error') or data.get('radar_error'):
        raise AssertionError('Visual run reported a timeout, image or radar error')
    if not data.get('full_flight_debrief', {}).get('survived'):
        raise AssertionError('Automated normal-state flight did not reach egress')
    expected = ['01_daylight', '01b_flash', '02_blackout', '03_defcon', '04_gameplay',
                '05_paper_chart', '06_bearing_only_rwr', '07_returns_only_radar',
                '08_gameplay_after_scan', '09_pencilled_route', '10_flight_notes', '11_mission_debrief']
    for name in expected:
        p = output / f'{name}.png'
        if name not in data.get('captures', []) or not p.exists() or p.stat().st_size < 1000:
            raise AssertionError(f'Requested capture was not written: {name}')
    # Source radar is the original bytes, not a digital overlay or retouched image.
    allowed = {'id', 'bearing', 'strength', 'tracking'}
    if not set(data.get('rwr_keys', [])).issubset(allowed):
        raise AssertionError('RWR leaked fields outside its bearing-only interface')
    return data


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--visual', action='store_true')
    parser.add_argument('--render-every-frame', action='store_true',
                        help='Force every test frame to draw even if its desktop window is obscured')
    parser.add_argument('--output', type=Path, default=REPO / '.radar_runtime' / 'cockpit_checks')
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ, OPENBLAS_NUM_THREADS='1', OMP_NUM_THREADS='4')
    before = {str(p.relative_to(REPO)): hashlib.sha256(p.read_bytes()).hexdigest()
              for p in [REPO/'game/radar/backend/approved_renderer.py',
                        REPO/'game/cockpit/shaders/phosphor.gdshader',
                        REPO/'game/cockpit/receiver_scope.gd']}
    summary = {'checks': {}, 'protected_source_hashes': before}
    for name, command, expected_count in TESTS:
        text = run(name, command, output, env)
        if name in ('mission', 'flight_systems'):
            tag = 'MISSION_TESTS' if name == 'mission' else 'FLIGHT_SYSTEM_TESTS'
            line = next(line for line in text.splitlines() if line.startswith(tag+' '))
            result = json.loads(line[len(tag)+1:])
            if result.get('failed') != 0 or result.get('passed') != expected_count:
                raise AssertionError(f'Unexpected check count for {name}: {result}')
        else:
            match = re.search(r'Ran (\d+) tests', text)
            if not match or int(match.group(1)) != expected_count or not text.rstrip().endswith('OK'):
                raise AssertionError(f'Test suite did not confirm expected count: {name}')
        summary['checks'][name] = expected_count
        print(f'PASS {name}: {expected_count}', flush=True)
    if args.visual:
        command = ['godot', '--path', '.', '--resolution', '1600x900', '--max-fps', '60',
                   '--audio-driver', 'Dummy', '--', '--cockpit-test', '--capture-dir='+str(output)]
        if args.render_every_frame:
            command.append('--render-every-frame')
        run('native_playthrough', command, output, env, timeout=200)
        summary['visual'] = verify_visual(output)
    for relative, digest in before.items():
        if hashlib.sha256((REPO/relative).read_bytes()).hexdigest() != digest:
            raise AssertionError(f'Protected source changed during tests: {relative}')
    summary['total_checks'] = sum(summary['checks'].values())
    (output/'validation_summary.json').write_text(json.dumps(summary, indent=2))
    print(f'PASS {summary["total_checks"]} checks; evidence in {output}', flush=True)


if __name__ == '__main__':
    main()
