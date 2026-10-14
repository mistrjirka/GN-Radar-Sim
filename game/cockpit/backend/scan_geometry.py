"""Fictional forward scan envelope shared with the Godot input guard.

Validate before allocating terrain. Offline reference rendering can omit a
heading; every live endless-mode acquisition is required to provide one.
"""
import json
import math
from pathlib import Path

LIMITS = json.loads((Path(__file__).resolve().parents[1] / 'scan_limits.json').read_text())


def validate_forward_scan(pose, heading, center, extent):
    if len(pose) != 3 or len(center) != 2:
        raise ValueError('SCAN INHIBITED: invalid position')
    values = [*pose, *center, heading, extent]
    if not all(math.isfinite(float(v)) for v in values) or not 400 <= extent <= 4000:
        raise ValueError('SCAN INHIBITED: invalid area')
    east, north = math.sin(heading), math.cos(heading)
    slope = math.tan(math.radians(LIMITS['half_angle_degrees']))
    for sx in (-1, 1):
        for sy in (-1, 1):
            dx = float(center[0]) - float(pose[0]) + (sx*north+sy*east)*extent/2
            dy = float(center[1]) - float(pose[1]) + (-sx*east+sy*north)*extent/2
            ahead = dx * east + dy * north
            if ahead < LIMITS['minimum_forward_m']:
                raise ValueError('SCAN INHIBITED: area too close or behind aircraft')
            if abs(dx * north - dy * east) > ahead * slope:
                raise ValueError('SCAN INHIBITED: turn toward selected area')
            if math.hypot(dx, dy) > LIMITS['maximum_ground_range_m']:
                raise ValueError('SCAN INHIBITED: area out of range')
