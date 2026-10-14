#!/usr/bin/env python3
"""Validate a cockpit run against its files, not just its success messages.

Usage: python game/cockpit/tests/verify_visual_run.py <capture-directory>
This verifies acquisition/capture evidence. Visual appearance still requires
opening the screenshots; a nonempty PNG is not proof of good graphics.
"""
from __future__ import annotations
import argparse
import json
from pathlib import Path
from typing import Any
from PIL import Image

REQUIRED_CAPTURES = (
    '01_daylight', '02_blackout', '03_defcon', '04_gameplay',
    '05_paper_chart', '06_bearing_only_rwr', '07_returns_only_radar',
    '08_gameplay_after_scan',
)
REQUIRED_FLAGS = (
    'intro_complete', 'second_scan_requested', 'arm_launched',
    'selected_emitter_suppressed', 'countermeasure', 'release_outside_inhibited',
)


def verify(folder: Path) -> dict[str, Any]:
    problems: list[str] = []
    try:
        report = json.loads((folder / 'game_test.json').read_text())
    except (OSError, ValueError) as exc:
        return {'ok': False, 'problems': [f'Cannot read game_test.json: {exc}']}
    if not isinstance(report, dict):
        return {'ok': False, 'problems': ['game_test.json must be a JSON object']}
    for key in ('timeout', 'capture_error', 'radar_error'):
        if report.get(key):
            problems.append(f'{key}: {report[key]}')
    for key in REQUIRED_FLAGS:
        if report.get(key) is not True:
            problems.append(f'Expected successful interaction: {key}')
    declared = report.get('captures', [])
    if not isinstance(declared, list) or not all(isinstance(x, str) for x in declared):
        declared = []
        problems.append('Capture list must contain filenames')
    checked: dict[str, list[int]] = {}
    for name in sorted(set(REQUIRED_CAPTURES) | set(declared)):
        if Path(name).name != name or '/' in name or '\\' in name:
            problems.append('Capture name must not contain a path')
            continue
        path = folder / (name + '.png')
        if name not in declared:
            problems.append(f'Capture was not recorded: {name}')
        try:
            with Image.open(path) as image:
                image.verify()
            with Image.open(path) as image:
                width, height = image.size
                if width < 640 or height < 360:
                    problems.append(f'Unexpected capture dimensions: {name} {width}x{height}')
                checked[name] = [width, height]
        except (OSError, ValueError) as exc:
            problems.append(f'Missing/invalid screenshot {name}: {exc}')
    first = report.get('first_frame', {})
    second = report.get('second_frame', {})
    if first.get('id') == second.get('id') or first.get('id') is None:
        problems.append('Expected two distinct completed acquisition IDs')
    if second.get('center') != report.get('selected_center'):
        problems.append('Second acquisition does not match the clicked chart region')
    if report.get('paper_position_start') == report.get('paper_position_end'):
        problems.append('Paper movement was not demonstrated')
    if report.get('screen_order') != ['RWR', 'RAW_RADAR', 'ROLLING_CHART']:
        problems.append('Instrument layout differs from the approved layout')
    rwr_keys = report.get('rwr_keys', [])
    if set(rwr_keys) - {'id', 'bearing', 'strength', 'tracking'}:
        problems.append('Receiver interface leaks data beyond bearing/strength')
    return {'ok': not problems, 'problems': problems, 'verified_screenshots': checked,
            'scope': 'Files and recorded interactions, not visual or physical realism'}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    args = parser.parse_args()
    result = verify(args.directory)
    print(json.dumps(result, indent=2))
    return 0 if result['ok'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
