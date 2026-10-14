#!/usr/bin/env python3
"""
Airborne Ground-Mapping Radar Simulator V6.5
(Eliminates the MP_B2 order=1 vs MP_WALL order=0 Halo Leakage Bug!)

Root cause of the 4-wall dotted outline in V6.2 - V6.4:
  - In V6.4 lines 462-464, 'MP_B2' (set to 18.0 on all 4 walls) was sampled with bilinear
    interpolation (order=1), creating a halo around all 4 walls where MP_B2 > 0, while
    'MP_WALL' was sampled with nearest-neighbor (order=0), which rounded to 0 on that halo!
  - Line 533 ('mp_gate = np.where(MP_WALL > 0.5, wall_lobe, 1.0)') then set mp_gate = 1.0
    all around the halo of all 4 walls, and 'phase_interf_2 = cos(4*pi*dR_2/0.35)' chopped
    that leaked 4-wall halo into periodic white dots ('• • • •') around every building!

How V6.5 fixes it permanently:
  - Removes building walls from 'mp_bounce2 / mp_bounce3' completely!
  - Instead, building wall multipath is driven directly by the computed 'wall_return'
    (which is already 0.0 on non-facing/non-broadside walls). Zero mask mismatches possible!

Run: python radar_simulator_v6_5_perfect_walls.py
"""

import time
import numpy as np
from scipy.ndimage import map_coordinates, gaussian_filter, gaussian_filter1d, convolve1d
import matplotlib.pyplot as plt

MAT_WATER    = 0
MAT_ROAD     = 1
MAT_SOIL     = 2
MAT_FOREST   = 3
MAT_CONCRETE = 4
MAT_METAL    = 5
MAT_FIELD    = 6


def generate_fractal_noise_2d(shape, rng, octaves_m, weights, dx):
    out = np.zeros(shape, dtype=np.float32)
    for scale_m, w in zip(octaves_m, weights):
        sigma_px = max(0.8, scale_m / dx)
        raw = rng.normal(0.0, 1.0, size=shape).astype(np.float32)
        layer = gaussian_filter(raw, sigma=sigma_px, mode="reflect")
        layer /= (np.std(layer) + 1e-6)
        out += w * layer
    return out


def ridge_fn(noise_arr, power=1.6, scale=2.6):
    return np.maximum(0.0, 1.0 - np.abs(noise_arr) / scale) ** power


class RadarTestWorldV6_5:
    def __init__(self, size_m=2000.0, N=1536, seed=42):
        self.size_m = size_m
        self.N = N
        self.dx = size_m / N  # 1.302m per pixel
        self.rng = np.random.default_rng(seed)

        lin = np.linspace(-size_m / 2, size_m / 2, N, dtype=np.float32)
        self.X, self.Y = np.meshgrid(lin, lin)

        self.height               = np.zeros((N, N), dtype=np.float32)
        self.smooth_h_for_normals = np.zeros((N, N), dtype=np.float32)
        self.mat_id               = np.full((N, N), MAT_SOIL, dtype=np.int32)
        self.soil_rough           = np.ones((N, N), dtype=np.float32)
        self.furrow_az            = np.zeros((N, N), dtype=np.float32)
        self.furrow_str           = np.zeros((N, N), dtype=np.float32)

        # Two-way dihedral reflectors (bridge rails, vehicle chassis, riverbanks)
        self.dihedral_str  = np.zeros((N, N), dtype=np.float32)
        self.dihedral_az   = np.zeros((N, N), dtype=np.float32)

        # One-Way Outward Vector Field (wall_nx, wall_ny) for Building Walls
        self.wall_nx       = np.zeros((N, N), dtype=np.float32)
        self.wall_ny       = np.zeros((N, N), dtype=np.float32)

        self.trihedral_str = np.zeros((N, N), dtype=np.float32)

        # Non-wall multipath (Bridge over water, SAM pits, Powerline towers)
        self.mp_height     = np.zeros((N, N), dtype=np.float32)
        self.mp_bounce2    = np.zeros((N, N), dtype=np.float32)
        self.mp_bounce3    = np.zeros((N, N), dtype=np.float32)

        self._build_scene()
        self._compute_normals()

    def _add_building_with_oneway_walls(self, cx, cy, half_l, half_w, rot_rad, height_wall=14.0, roof_ridge=3.0, hvac_list=()):
        X, Y = self.X, self.Y
        cos_r, sin_r = np.cos(rot_rad), np.sin(rot_rad)
        xr =  (X - cx) * cos_r + (Y - cy) * sin_r
        yr = -(X - cx) * sin_r + (Y - cy) * cos_r

        b_mask = (np.abs(xr) <= half_l) & (np.abs(yr) <= half_w)
        roof_pitch = roof_ridge * (1.0 - np.abs(yr) / half_w)
        self.height[b_mask] += height_wall + roof_pitch[b_mask]
        self.smooth_h_for_normals[b_mask] += roof_pitch[b_mask]
        self.mat_id[b_mask] = MAT_CONCRETE

        # 4 Outward-Facing Vertical Walls stored ONLY in (wall_nx, wall_ny)
        # Never touches mp_bounce2/mp_bounce3 -> zero halo leakage!
        wall_thickness = 1.6
        w_south = (np.abs(yr + half_w) < wall_thickness) & (np.abs(xr) <= half_l - 1.5)
        w_north = (np.abs(yr - half_w) < wall_thickness) & (np.abs(xr) <= half_l - 1.5)
        w_west  = (np.abs(xr + half_l) < wall_thickness) & (np.abs(yr) <= half_w - 1.5)
        w_east  = (np.abs(xr - half_l) < wall_thickness) & (np.abs(yr) <= half_w - 1.5)

        wall_specs = [
            (w_south, rot_rad - np.pi / 2.0),
            (w_north, rot_rad + np.pi / 2.0),
            (w_west,  rot_rad + np.pi),
            (w_east,  rot_rad + 0.0),
        ]
        wall_rcs = 95.0
        for w_mask, outward_az in wall_specs:
            self.wall_nx[w_mask] = wall_rcs * np.cos(outward_az)
            self.wall_ny[w_mask] = wall_rcs * np.sin(outward_az)

        # Subtle Rooftop HVAC Chiller Units
        for hx_off, hy_off in hvac_list:
            hvac_mask = (np.abs(xr - hx_off) < 1.5) & (np.abs(yr - hy_off) < 1.5)
            self.height[hvac_mask] += 2.2
            self.mat_id[hvac_mask] = MAT_METAL
            self.trihedral_str[hvac_mask] = 4.8

    def _build_scene(self):
        X, Y = self.X, self.Y
        dx = self.dx

        # 1. Domain-Warped Multifractal Terrain
        warp_x = 38.0 * generate_fractal_noise_2d((self.N, self.N), self.rng, (180.0, 75.0), (0.65, 0.35), dx)
        warp_y = 38.0 * generate_fractal_noise_2d((self.N, self.N), self.rng, (180.0, 75.0), (0.65, 0.35), dx)
        XW, YW = X + warp_x, Y + warp_y

        base_noise = generate_fractal_noise_2d(
            (self.N, self.N), self.rng,
            octaves_m=(240.0, 115.0, 52.0, 22.0, 9.0),
            weights=(0.45, 0.25, 0.16, 0.09, 0.05),
            dx=dx
        )
        crease_noise = generate_fractal_noise_2d(
            (self.N, self.N), self.rng,
            octaves_m=(140.0, 65.0, 28.0),
            weights=(0.50, 0.32, 0.18),
            dx=dx
        )
        hills = 26.0 * base_noise + 12.0 * ridge_fn(crease_noise, power=1.6, scale=2.6) + 24.0

        # Craggy NW Mountain Massif
        r_hill1 = np.hypot((XW + 450.0) / 215.0, (YW - 430.0) / 165.0)
        r_hill2 = np.hypot((XW + 290.0) / 170.0, (YW - 530.0) / 145.0)
        ridge_base = 138.0 * np.exp(-r_hill1**2) + 102.0 * np.exp(-r_hill2**2)

        canyon_n1 = generate_fractal_noise_2d((self.N, self.N), self.rng, (65.0, 28.0, 11.0), (0.55, 0.30, 0.15), dx)
        canyon_n2 = generate_fractal_noise_2d((self.N, self.N), self.rng, (32.0, 14.0, 6.0),  (0.55, 0.30, 0.15), dx)
        ridged_canyons = 0.65 * ridge_fn(canyon_n1, power=1.8, scale=2.5) + 0.35 * ridge_fn(canyon_n2, power=2.0, scale=2.5)
        ridge = ridge_base * (0.55 + 0.68 * ridged_canyons)

        # SAM Tactical Plateau at SW (X=-500, Y=-450)
        plateau_r = np.hypot(XW + 500.0, YW + 450.0)
        plateau   = 48.0 / (1.0 + np.exp((plateau_r - 250.0) / 24.0))

        self.height = np.maximum(2.0, hills + ridge + plateau).astype(np.float32)

        # 2. Natural River Valley with Warped Terraces
        bank_warp = 18.0 * generate_fractal_noise_2d((self.N, self.N), self.rng, (110.0, 38.0, 14.0), (0.55, 0.30, 0.15), dx)
        river_center_x = 175.0 * np.sin(Y / 360.0) + 0.22 * Y
        river_dist_raw = np.abs(X - river_center_x)
        river_dist     = np.abs((X + 0.35 * bank_warp) - river_center_x)

        gully_cut = 0.35 * np.maximum(0.0, crease_noise / 2.2)
        denom = np.maximum(40.0, 115.0 + 35.0 * bank_warp / 18.0)
        terrace_t = np.clip((river_dist - 58.0) / denom, 0.0, 1.0)
        valley_profile = (terrace_t ** 0.75) * (1.0 - gully_cut * np.exp(-((river_dist - 85.0) / 35.0)**2))
        self.height *= np.clip(valley_profile, 0.0, 1.0)

        is_water = river_dist < 58.0
        self.mat_id[is_water] = MAT_WATER
        self.height[is_water] = 0.0

        dy_riv = -(175.0 / 360.0) * np.cos(Y / 360.0) - 0.22
        bank_norm_az = np.arctan2(dy_riv, np.ones_like(dy_riv))
        scarp_mod = np.clip(0.6 + 0.4 * crease_noise, 0.15, 1.4)
        is_bank = (river_dist >= 58.0) & (river_dist < 61.5)
        self.dihedral_str[is_bank] = 6.5 * scarp_mod[is_bank]
        self.dihedral_az[is_bank]  = bank_norm_az[is_bank]

        # 3. Subtle Agricultural Field Parcels
        n_seeds = 24
        seed_x = self.rng.uniform(-950.0, 950.0, size=n_seeds)
        seed_y = self.rng.uniform(-950.0, 950.0, size=n_seeds)
        seed_rough = self.rng.uniform(0.72, 1.32, size=n_seeds).astype(np.float32)
        seed_az    = self.rng.choice([0.0, np.pi / 2.0, np.deg2rad(32.0), np.deg2rad(-58.0)], size=n_seeds).astype(np.float32)
        seed_bragg = self.rng.uniform(0.12, 0.38, size=n_seeds).astype(np.float32)

        d2_min1 = np.full((self.N, self.N), 1e12, dtype=np.float32)
        nearest_id = np.zeros((self.N, self.N), dtype=np.int32)
        for s_i in range(n_seeds):
            d2 = (XW - seed_x[s_i])**2 + (YW - seed_y[s_i])**2
            closer = d2 < d2_min1
            d2_min1 = np.where(closer, d2, d2_min1)
            nearest_id = np.where(closer, s_i, nearest_id)

        is_farmland = (~is_water) & (river_dist > 75.0) & (self.height < 68.0) & (X > -150.0)
        self.mat_id[is_farmland]     = MAT_FIELD
        self.soil_rough[is_farmland] = seed_rough[nearest_id[is_farmland]]
        self.furrow_az[is_farmland]  = seed_az[nearest_id[is_farmland]]
        self.furrow_str[is_farmland] = seed_bragg[nearest_id[is_farmland]]

        self.soil_rough = gaussian_filter(self.soil_rough, sigma=2.0)
        soil_micro = np.clip(1.0 + 0.22 * crease_noise, 0.65, 1.45)
        self.soil_rough *= soil_micro

        # 4. Authentic Individual Tree-Crown Forests
        edge_warp = 42.0 * generate_fractal_noise_2d(
            (self.N, self.N), self.rng, octaves_m=(95.0, 40.0), weights=(0.7, 0.3), dx=dx
        )
        dist_f1 = np.minimum.reduce([
            -180.0 - (X + edge_warp),
            (Y + edge_warp) - (-140.0),
            250.0 - (Y - edge_warp)
        ])
        dist_f2 = np.minimum(
            (X + edge_warp) - 240.0,
            -110.0 - (Y + edge_warp)
        )
        forest_sdf = np.maximum(dist_f1, dist_f2)
        road_corridor = (np.abs(Y - 60.0) < 13.5) | ((np.abs(X + 500.0) < 12.0) & (Y < 60.0) & (Y > -450.0))

        crown_field = generate_fractal_noise_2d(
            (self.N, self.N), self.rng,
            octaves_m=(16.0, 5.5, 2.6),
            weights=(0.20, 0.50, 0.30),
            dx=dx
        )
        border_taper = np.clip(forest_sdf / 38.0, 0.0, 1.0)
        tree_threshold = 0.75 - 0.95 * border_taper
        has_tree = (forest_sdf > 0.0) & (~is_water) & (~road_corridor) & (crown_field > tree_threshold)

        crown_excess = np.clip((crown_field - tree_threshold) / 1.1, 0.0, 1.4)
        tree_h = (10.5 * np.sqrt(crown_excess) * (0.60 + 0.40 * border_taper)).astype(np.float32)

        self.mat_id[has_tree] = MAT_FOREST
        self.height[has_tree] += tree_h[has_tree]

        # 5. Paved Roads + Bridge Causeway
        embankment_zone = (np.abs(Y - 60.0) < 10.0) & (river_dist_raw >= 58.0) & (river_dist_raw < 145.0)
        embank_blend = np.clip(1.0 - np.abs(Y - 60.0) / 10.0, 0.0, 1.0) * np.clip((145.0 - river_dist_raw) / 85.0, 0.0, 1.0)
        self.height[embankment_zone] = (
            self.height[embankment_zone] * (1.0 - embank_blend[embankment_zone])
            + 22.0 * embank_blend[embankment_zone]
        )

        road_ew = (np.abs(Y - 60.0) < 5.2) & (~is_water)
        road_ns = (np.abs(X + 500.0) < 4.5) & (Y < 60.0) & (Y > -450.0) & (~is_water)
        self.mat_id[road_ew | road_ns] = MAT_ROAD

        self.smooth_h_for_normals = self.height.copy()

        # 6. Sleek Steel Box-Girder & Truss Bridge with 3-Bounce Multipath Physics
        bridge_box = (np.abs(Y - 60.0) < 5.2) & (river_dist_raw < 63.0)
        self.height[bridge_box] = 22.0
        self.smooth_h_for_normals[bridge_box] = 22.0
        self.mat_id[bridge_box] = MAT_ROAD

        rail_n = (np.abs((Y - 60.0) - 4.4) < 1.1) & (river_dist_raw < 63.0)
        rail_s = (np.abs((Y - 60.0) + 4.4) < 1.1) & (river_dist_raw < 63.0)
        rails  = rail_n | rail_s
        self.mat_id[rails]        = MAT_METAL
        self.height[rails]        = 24.2
        self.dihedral_str[rails]  = 32.0
        self.dihedral_az[rails]   = np.pi / 2.0
        self.trihedral_str[rails] = 7.5

        truss_posts = rails & (np.abs(((X - river_center_x) % 16.0) - 8.0) < 1.1)
        self.trihedral_str[truss_posts] = 22.0
        self.dihedral_str[truss_posts]  = 24.0
        self.dihedral_az[truss_posts]   = 0.0

        over_water_bridge = bridge_box & is_water
        self.mp_height[over_water_bridge]  = 22.0
        self.mp_bounce2[over_water_bridge] = 20.0
        self.mp_bounce3[over_water_bridge] = 8.0

        for px_off in [-34.0, 0.0, 34.0]:
            pier = (np.abs((X - river_center_x) - px_off) < 2.2) & (np.abs(Y - 60.0) < 5.5) & is_water
            self.trihedral_str[pier] = 42.0
            self.mp_bounce2[pier]    = 45.0

        # 7. Industrial Compound: Service Roads & 3 Warehouses with Pure Vector-Field Walls
        yard_road_ns = (np.abs(X - 368.0) < 5.0) & (Y >= 60.0) & (Y <= 290.0)
        yard_loop_1  = (np.abs(Y - 285.0) < 14.0) & (X >= 365.0) & (X <= 475.0)
        yard_loop_2  = (np.abs(Y - 185.0) < 14.0) & (X >= 365.0) & (X <= 475.0)
        yard_spur_c  = (np.abs((Y - 185.0) - 0.55 * (X - 465.0)) < 8.0) & (X >= 460.0) & (X <= 575.0)
        self.mat_id[yard_road_ns | yard_loop_1 | yard_loop_2 | yard_spur_c] = MAT_ROAD

        self._add_building_with_oneway_walls(
            cx=420.0, cy=285.0, half_l=42.0, half_w=20.0, rot_rad=0.0,
            hvac_list=[(-22.0, -4.0), (8.0, 5.0), (26.0, -3.0)]
        )
        self._add_building_with_oneway_walls(
            cx=420.0, cy=185.0, half_l=42.0, half_w=20.0, rot_rad=0.0,
            hvac_list=[(-18.0, 4.0), (16.0, -5.0)]
        )
        self._add_building_with_oneway_walls(
            cx=565.0, cy=235.0, half_l=42.0, half_w=20.0, rot_rad=np.deg2rad(32.0),
            hvac_list=[(-16.0, -4.0), (14.0, 3.5)]
        )

        # 8. SAM Air-Defense Battery
        sx, sy = -500.0, -450.0
        r_sam_center = np.hypot(X - sx, Y - sy)
        ring_track = (np.abs(r_sam_center - 92.0) < 3.2)
        self.mat_id[ring_track] = MAT_ROAD

        radar_mask = r_sam_center < 5.5
        self.height[radar_mask] += 11.0
        self.mat_id[radar_mask] = MAT_METAL
        self.trihedral_str[radar_mask] = 165.0
        self.mp_height[radar_mask]     = 11.0
        self.mp_bounce2[radar_mask]    = 35.0

        for k in range(6):
            ang = k * (np.pi / 3.0) + np.deg2rad(15.0)
            vx = sx + 130.0 * np.cos(ang)
            vy = sy + 130.0 * np.sin(ang)

            proj_along = (X - sx) * np.cos(ang) + (Y - sy) * np.sin(ang)
            proj_perp  = np.abs(-(X - sx) * np.sin(ang) + (Y - sy) * np.cos(ang))
            spur_track = (proj_along > 15.0) & (proj_along < 115.0) & (proj_perp < 2.6)
            self.mat_id[spur_track] = MAT_ROAD

            r_berm = np.hypot(X - vx, Y - vy)
            berm_mask = (r_berm > 13.0) & (r_berm < 21.5)
            berm_profile = np.sin(np.clip((r_berm - 13.0) / 8.5, 0.0, 1.0) * np.pi)
            self.height[berm_mask] += 4.5 * berm_profile[berm_mask]
            self.smooth_h_for_normals[berm_mask] += 4.5 * berm_profile[berm_mask]

            vxr =  (X - vx) * np.cos(ang) + (Y - vy) * np.sin(ang)
            vyr = -(X - vx) * np.sin(ang) + (Y - vy) * np.cos(ang)
            veh_mask = (np.abs(vxr) < 5.5) & (np.abs(vyr) < 2.6)
            self.height[veh_mask] += 3.8
            self.mat_id[veh_mask] = MAT_METAL
            self.dihedral_str[veh_mask]  = 80.0
            self.dihedral_az[veh_mask]   = ang + np.pi / 2.0
            self.trihedral_str[veh_mask] = 42.0
            self.mp_height[veh_mask]     = 5.5
            self.mp_bounce2[veh_mask]    = 22.0
            self.mp_bounce3[veh_mask]    = 9.0

        hvx, hvy = -370.0, 560.0
        h_mask = (np.abs(X - hvx) < 5.5) & (np.abs(Y - hvy) < 2.6)
        self.height[h_mask] += 4.0
        self.mat_id[h_mask] = MAT_METAL
        self.trihedral_str[h_mask] = 105.0
        self.mp_height[h_mask]     = 5.0
        self.mp_bounce2[h_mask]    = 20.0

        # 9. High-Voltage Lattice Steel Transmission Towers
        for t_step in range(-4, 5):
            tx = -120.0 + t_step * 185.0
            ty =  110.0 + t_step * 155.0
            if (-920 < tx < 920) and (-920 < ty < 920):
                dist_riv_pylon = np.abs(tx - (175.0 * np.sin(ty / 360.0) + 0.22 * ty))
                if dist_riv_pylon > 68.0:
                    pylon = (np.abs(X - tx) < 2.4) & (np.abs(Y - ty) < 2.4)
                    self.height[pylon] += 28.0
                    self.mat_id[pylon] = MAT_METAL
                    self.trihedral_str[pylon] = 68.0
                    self.mp_height[pylon]     = 22.0
                    self.mp_bounce2[pylon]    = 18.0

        self.height = np.nan_to_num(self.height, nan=10.0, posinf=200.0, neginf=0.0)

    def _compute_normals(self):
        dz_dy, dz_dx = np.gradient(self.smooth_h_for_normals, self.dx, self.dx)
        is_forest = (self.mat_id == MAT_FOREST)
        dz_dx = np.where(is_forest, dz_dx * 0.45, dz_dx)
        dz_dy = np.where(is_forest, dz_dy * 0.45, dz_dy)

        norm = np.sqrt(dz_dx**2 + dz_dy**2 + 1.0)
        self.nx = (-dz_dx / norm).astype(np.float32)
        self.ny = (-dz_dy / norm).astype(np.float32)
        self.nz = ( 1.0   / norm).astype(np.float32)


class OpticalCameraRendererV6_5:
    def __init__(self, world: RadarTestWorldV6_5):
        self.world = world

    def compute_sun_lit_rgb(self, sun_az_deg=135.0, sun_el_deg=38.0):
        w = self.world
        vis_h = w.height

        rgb = np.zeros((w.N, w.N, 3), dtype=np.float32)
        palette = {
            MAT_WATER:    np.array([0.11, 0.27, 0.44]),
            MAT_ROAD:     np.array([0.26, 0.27, 0.29]),
            MAT_SOIL:     np.array([0.46, 0.42, 0.31]),
            MAT_FOREST:   np.array([0.15, 0.33, 0.14]),
            MAT_CONCRETE: np.array([0.66, 0.65, 0.62]),
            MAT_METAL:    np.array([0.78, 0.80, 0.84]),
            MAT_FIELD:    np.array([0.41, 0.44, 0.29]),
        }
        for mat_id, col in palette.items():
            rgb[w.mat_id == mat_id] = col

        is_fld = (w.mat_id == MAT_FIELD)
        fld_mod = np.clip(0.85 + 0.18 * w.soil_rough[is_fld], 0.75, 1.2)[..., None]
        rgb[is_fld] *= fld_mod

        rock_factor = np.clip((vis_h - 65.0) / 85.0, 0.0, 1.0)[..., None]
        soil_mask = (w.mat_id == MAT_SOIL)
        rgb[soil_mask] = (1.0 - rock_factor[soil_mask]) * rgb[soil_mask] + rock_factor[soil_mask] * np.array([0.55, 0.52, 0.49])

        az_r = np.deg2rad(sun_az_deg)
        el_r = np.deg2rad(sun_el_deg)
        sun_dx, sun_dy, sun_dz = np.cos(el_r) * np.cos(az_r), np.cos(el_r) * np.sin(az_r), np.sin(el_r)
        ndotl = np.clip(w.nx * sun_dx + w.ny * sun_dy + w.nz * sun_dz, 0.0, 1.0)

        sun_shadow = np.ones((w.N, w.N), dtype=np.float32)
        step_px = 3.0
        dx_px = -sun_dx / np.hypot(sun_dx, sun_dy) * step_px
        dy_px = -sun_dy / np.hypot(sun_dx, sun_dy) * step_px
        dz_per_step = (step_px * w.dx) * np.tan(el_r)

        yy, xx = np.meshgrid(np.arange(w.N, dtype=np.float32), np.arange(w.N, dtype=np.float32), indexing="ij")
        cur_x, cur_y, cur_z = xx.copy(), yy.copy(), vis_h.copy()

        for _ in range(55):
            cur_x += dx_px
            cur_y += dy_px
            cur_z += dz_per_step
            valid = (cur_x >= 0) & (cur_x < w.N - 1) & (cur_y >= 0) & (cur_y < w.N - 1)
            sample_h = map_coordinates(vis_h, [cur_y, cur_x], order=1, mode="nearest")
            occluded = valid & (sample_h > cur_z + 0.4)
            sun_shadow[occluded] = 0.32

        illum = 0.30 + 0.75 * ndotl * sun_shadow
        lit_rgb = rgb * illum[..., None]

        is_vehicle = (w.mat_id == MAT_METAL) & (w.X < -250.0) & (w.Y < -200.0)
        lit_rgb[is_vehicle] = np.array([0.96, 0.56, 0.14])

        return np.clip(lit_rgb, 0.0, 1.0), vis_h


class CoherentMultipathRadarEngineV6_5:
    def __init__(self, world: RadarTestWorldV6_5):
        self.world = world
        self.mat_gamma  = np.array([0.80, 0.45, 0.35, 0.16, 0.18, 0.95, 0.32], dtype=np.float32)
        self.mat_slope  = np.array([0.045, 0.07, 0.28, 0.55, 0.22, 0.12, 0.25], dtype=np.float32)
        self.mat_diff_A = np.array([0.002, 0.005, 0.12, 0.20, 0.065, 0.32, 0.11], dtype=np.float32)
        self.mat_nu     = np.array([2.0,  1.8,  1.5,  0.75, 1.6,  1.2,  1.45], dtype=np.float32)

    def _world_to_grid_coords(self, x, y):
        w = self.world
        gx = (x + w.size_m / 2.0) / (w.size_m / (w.N - 1))
        gy = (y + w.size_m / 2.0) / (w.size_m / (w.N - 1))
        return np.vstack([gy[None, ...], gx[None, ...]])

    def render_radar_patch(self, ac_pos=(0.0, -2400.0, 1450.0), looks=4, n_az=1400, n_rg=1600):
        t0 = time.perf_counter()
        w = self.world
        ac_x, ac_y, ac_z = ac_pos

        los_center_az = np.arctan2(0.0 - ac_y, 0.0 - ac_x)

        boundary_pts = np.linspace(-w.size_m / 2.0, w.size_m / 2.0, 64)
        bx, by = np.meshgrid(boundary_pts, boundary_pts)
        b_dx, b_dy = bx - ac_x, by - ac_y
        b_rg = np.hypot(b_dx, b_dy)
        b_rel_az = (np.arctan2(b_dy, b_dx) - los_center_az + np.pi) % (2 * np.pi) - np.pi

        rg_min = max(80.0, float(np.min(b_rg)) - 45.0)
        rg_max = float(np.max(b_rg)) + 45.0
        az_min = los_center_az + float(np.min(b_rel_az)) - 0.02
        az_max = los_center_az + float(np.max(b_rel_az)) + 0.02

        n_r_slant = n_rg
        az_vec = np.linspace(az_min, az_max, n_az, dtype=np.float32)
        rg_vec = np.linspace(rg_min, rg_max, n_rg, dtype=np.float32)
        AZ, RG = np.meshgrid(az_vec, rg_vec, indexing="ij")

        WX = ac_x + RG * np.cos(AZ)
        WY = ac_y + RG * np.sin(AZ)
        coords_2d = self._world_to_grid_coords(WX, WY)

        MAT     = map_coordinates(w.mat_id,        coords_2d, order=0, mode="nearest")
        # Use sharp height (order=0) on discrete concrete buildings so vertical walls don't become 45-deg bilinear ramps!
        H_lin   = map_coordinates(w.height,        coords_2d, order=1, mode="nearest")
        H_near  = map_coordinates(w.height,        coords_2d, order=0, mode="nearest")
        H_surf  = np.where(MAT == MAT_CONCRETE, H_near, H_lin)

        NX      = map_coordinates(w.nx,            coords_2d, order=1, mode="nearest")
        NY      = map_coordinates(w.ny,            coords_2d, order=1, mode="nearest")
        NZ      = map_coordinates(w.nz,            coords_2d, order=1, mode="nearest")
        SOIL_R  = map_coordinates(w.soil_rough,    coords_2d, order=1, mode="nearest")
        FUR_AZ  = map_coordinates(w.furrow_az,     coords_2d, order=0, mode="nearest")
        FUR_STR = map_coordinates(w.furrow_str,    coords_2d, order=1, mode="nearest")
        DIH_STR = map_coordinates(w.dihedral_str,  coords_2d, order=1, mode="nearest")
        DIH_AZ  = map_coordinates(w.dihedral_az,   coords_2d, order=0, mode="nearest")

        WNX     = map_coordinates(w.wall_nx,       coords_2d, order=1, mode="nearest")
        WNY     = map_coordinates(w.wall_ny,       coords_2d, order=1, mode="nearest")

        TRI_STR = map_coordinates(w.trihedral_str, coords_2d, order=1, mode="nearest")
        MP_H    = map_coordinates(w.mp_height,     coords_2d, order=0, mode="nearest")
        MP_B2   = map_coordinates(w.mp_bounce2,    coords_2d, order=1, mode="nearest")
        MP_B3   = map_coordinates(w.mp_bounce3,    coords_2d, order=1, mode="nearest")

        # 1. Exact Per-Ray Horizon Shadow Sweep
        R_slant = np.sqrt(RG**2 + (ac_z - H_surf)**2)
        dep_slope = (ac_z - H_surf) / RG
        running_min_slope = np.minimum.accumulate(dep_slope, axis=1)
        is_shadowed = dep_slope > (running_min_slope + 8e-5)
        is_shadowed[:, 0] = False

        # 2. Direct Backscatter + Subtle Agricultural Furrow Bragg Resonance
        look_dx = (WX - ac_x) / R_slant
        look_dy = (WY - ac_y) / R_slant
        look_dz = (H_surf - ac_z) / R_slant

        cos_theta = np.clip(-(look_dx * NX + look_dy * NY + look_dz * NZ), 0.01, 1.0)
        sin_theta = np.sqrt(1.0 - cos_theta**2)
        tan_theta = sin_theta / cos_theta

        gamma  = self.mat_gamma[MAT]
        slope  = self.mat_slope[MAT]
        diff_A = self.mat_diff_A[MAT] * SOIL_R
        nu     = self.mat_nu[MAT]

        bragg_lobe = np.sinc(3.5 * np.sin(AZ - FUR_AZ))**2
        diff_A *= (1.0 + FUR_STR * bragg_lobe)

        sigma0 = (
            ((gamma**2) / (slope**2 * cos_theta**4 + 1e-4)) * np.exp(-(tan_theta**2) / (slope**2))
            + diff_A * (cos_theta**nu)
        )

        # A) Two-way dihedrals (Bridge girders, vehicles, riverbanks)
        sin_d_az = np.sin(AZ - DIH_AZ)
        dihedral_lobe_2way = np.sinc(7.5 * sin_d_az)**2
        grazing_term = (2.0 * cos_theta * sin_theta)**2
        sigma0 += DIH_STR * dihedral_lobe_2way * (0.2 + 0.8 * grazing_term)

        # B) One-Way Building Walls via Outward Vector Field (WNX, WNY)
        wall_mag = np.hypot(WNX, WNY)
        has_wall = (wall_mag > 0.5) & (~is_shadowed)
        wall_return = np.zeros_like(sigma0)
        if np.any(has_wall):
            ux = WNX[has_wall] / wall_mag[has_wall]
            uy = WNY[has_wall] / wall_mag[has_wall]
            ray_x = np.cos(AZ[has_wall])
            ray_y = np.sin(AZ[has_wall])

            dot_out   = ray_x * ux + ray_y * uy
            cross_out = ray_x * uy - ray_y * ux

            # Front-facing wall check: radar ray must oppose outward normal (dot_out < -0.25)
            front_face_gate = np.where(dot_out < -0.25, (-dot_out) ** 2.0, 0.0)
            # Subtle radar-facing L-wall edge visibility (0.015) + intense broadside sinc^2 flash
            w_lobe = front_face_gate * (0.015 + 0.985 * (np.sinc(7.5 * cross_out) ** 2))
            w_ret  = wall_mag[has_wall] * w_lobe * (0.2 + 0.8 * grazing_term[has_wall])
            wall_return[has_wall] = w_ret
            sigma0[has_wall] += w_ret

        sigma0 += TRI_STR * (0.4 + 0.6 * cos_theta)
        sigma0 = np.where(is_shadowed, 0.0, sigma0)

        d_rg = (rg_max - rg_min) / n_rg
        sigma0 *= (d_rg / 1.55)

        # 3. Sub-Bin Linear Slant-Range Splatting
        r_s_min = float(np.min(R_slant)) - 30.0
        r_s_max = float(np.max(R_slant)) + 55.0
        r_float = np.clip((R_slant - r_s_min) / (r_s_max - r_s_min) * (n_r_slant - 2), 0.0, n_r_slant - 2.001)
        r_idx0  = r_float.astype(np.int32)
        r_frac  = r_float - r_idx0

        az_row_idx = np.arange(n_az, dtype=np.int32)[:, None]
        az_broad   = np.broadcast_to(az_row_idx, r_idx0.shape)

        polar_slant_img = np.zeros((n_az, n_r_slant), dtype=np.float32)
        np.add.at(polar_slant_img, (az_broad, r_idx0),     sigma0 * (1.0 - r_frac))
        np.add.at(polar_slant_img, (az_broad, r_idx0 + 1), sigma0 * r_frac)

        # 4A. Non-Wall Multipath Splatting (Bridge over water, SAM pits, Powerline towers)
        has_mp = (MP_B2 > 0.05) & (~is_shadowed)
        if np.any(has_mp):
            r_1st   = R_slant[has_mp]
            h_mp    = MP_H[has_mp]
            sin_dep = np.abs(ac_z - H_surf[has_mp]) / r_1st
            az_mp   = az_broad[has_mp]

            dR_2 = h_mp * sin_dep * 0.65
            phase_interf_2 = 0.5 + 0.5 * np.cos(4.0 * np.pi * dR_2 / 0.35)
            pwr_2 = MP_B2[has_mp] * (d_rg / 1.55) * phase_interf_2
            r2_f  = np.clip((r_1st + dR_2 - r_s_min) / (r_s_max - r_s_min) * (n_r_slant - 2), 0.0, n_r_slant - 2)
            np.add.at(polar_slant_img, (az_mp, r2_f.astype(np.int32)), pwr_2)

            dR_3 = h_mp * sin_dep * 1.35
            pwr_3 = MP_B3[has_mp] * (d_rg / 1.55) * w.rng.exponential(1.0, size=np.sum(has_mp)).astype(np.float32)
            r3_f  = np.clip((r_1st + dR_3 - r_s_min) / (r_s_max - r_s_min) * (n_r_slant - 2), 0.0, n_r_slant - 2)
            np.add.at(polar_slant_img, (az_mp, r3_f.astype(np.int32)), pwr_3)

        # 4B. FIXED V6.5: Building Wall Multipath Driven Directly by Active 'wall_return' (Zero Halo Leakage!)
        active_wall_mp = wall_return > 2.0
        if np.any(active_wall_mp):
            r_w1    = R_slant[active_wall_mp]
            sin_dep = np.abs(ac_z - H_surf[active_wall_mp]) / r_w1
            az_w    = az_broad[active_wall_mp]
            dR_w2   = 5.0 * sin_dep
            pwr_w2  = 0.18 * wall_return[active_wall_mp] * (d_rg / 1.55)
            rw2_f   = np.clip((r_w1 + dR_w2 - r_s_min) / (r_s_max - r_s_min) * (n_r_slant - 2), 0.0, n_r_slant - 2)
            np.add.at(polar_slant_img, (az_w, rw2_f.astype(np.int32)), pwr_w2)

        # 5. Multi-Look Gamma Speckle + Matched Filter PSF + Aperture Diffraction Sidelobes
        speckle = w.rng.gamma(shape=looks, scale=1.0 / looks, size=polar_slant_img.shape).astype(np.float32)
        polar_slant_img *= speckle

        polar_slant_img = gaussian_filter1d(polar_slant_img, sigma=0.45, axis=0)
        polar_slant_img = gaussian_filter1d(polar_slant_img, sigma=0.45, axis=1)

        strong_peaks = np.maximum(0.0, polar_slant_img - 32.0)
        k_half = 24
        u = np.linspace(-2.5, 2.5, 2 * k_half + 1)
        taper = 0.54 + 0.46 * np.cos(np.pi * u / 2.5)
        psf_1d = ((np.sinc(u) * taper)**2).astype(np.float32)
        polar_slant_img += 0.08 * (
            convolve1d(strong_peaks, psf_1d, axis=0, mode="constant") +
            convolve1d(strong_peaks, psf_1d, axis=1, mode="constant")
        )

        r_norm = np.linspace(0.8, 1.35, n_r_slant, dtype=np.float32)[None, :]
        polar_slant_img += 0.026 * r_norm * w.rng.exponential(1.0, size=polar_slant_img.shape).astype(np.float32)

        # 6. Bilinear Ground-Range Reprojection
        R_flat_ground = np.sqrt((w.X - ac_x)**2 + (w.Y - ac_y)**2 + (ac_z - 22.0)**2)
        AZ_ground     = los_center_az + ((np.arctan2(w.Y - ac_y, w.X - ac_x) - los_center_az + np.pi) % (2 * np.pi) - np.pi)

        az_coord = (AZ_ground - az_min) / (az_max - az_min) * (n_az - 1)
        r_coord  = (R_flat_ground - r_s_min) / (r_s_max - r_s_min) * (n_r_slant - 1)
        ground_img = map_coordinates(polar_slant_img, np.vstack([az_coord[None, ...], r_coord[None, ...]]), order=1, mode="nearest")

        dt_ms = (time.perf_counter() - t0) * 1000.0
        return ground_img, dt_ms


def log_compress(img, db_min=-17.0, db_max=17.5, gamma=0.92):
    db = 10.0 * np.log10(np.maximum(img, 1e-4))
    norm = np.clip((db - db_min) / (db_max - db_min), 0.0, 1.0)
    return norm ** gamma


def crop_region(img, world_N, size_m, x_range, y_range):
    def m_to_idx(val):
        return int(np.clip((val + size_m / 2.0) / size_m * world_N, 0, world_N - 1))
    x0, x1 = m_to_idx(x_range[0]), m_to_idx(x_range[1])
    y0, y1 = m_to_idx(y_range[0]), m_to_idx(y_range[1])
    return img[y0:y1, x0:x1]


if __name__ == "__main__":
    print("Building V6.5 World (Eliminated MP_B2/MP_WALL Halo Leakage & Sharp Building Heights)...")
    world = RadarTestWorldV6_5(size_m=2000.0, N=1536, seed=42)
    cam   = OpticalCameraRendererV6_5(world)
    radar = CoherentMultipathRadarEngineV6_5(world)

    top_down_rgb, vis_h = cam.compute_sun_lit_rgb(sun_az_deg=135.0, sun_el_deg=38.0)

    pos_south = (0.0,    -2400.0, 1450.0)
    pos_sw    = (-1850.0, -1850.0, 1550.0)
    pos_low   = (-1950.0, -1950.0, 620.0)
    pos_east  = (2300.0,   100.0, 1500.0)

    sar_south, t_s = radar.render_radar_patch(pos_south, looks=4, n_az=1400, n_rg=1600)
    sar_sw,    t_w = radar.render_radar_patch(pos_sw,    looks=4, n_az=1400, n_rg=1600)
    sar_low,   t_l = radar.render_radar_patch(pos_low,   looks=4, n_az=1400, n_rg=1600)
    sar_east,  t_e = radar.render_radar_patch(pos_east,  looks=4, n_az=1400, n_rg=1600)

    print(f"V6.5 SAR South Cardinal : {t_s:6.0f} ms")
    print(f"V6.5 SAR SW Oblique 32° : {t_w:6.0f} ms")
    print(f"V6.5 SAR Low Grazing    : {t_l:6.0f} ms")
    print(f"V6.5 SAR East Flank     : {t_e:6.0f} ms")

    plt.imsave("radar_v6_5_fullres_sw_32deg.png",    log_compress(sar_sw),   cmap="gray", origin="lower")
    plt.imsave("radar_v6_5_fullres_east_view.png",   log_compress(sar_east), cmap="gray", origin="lower")
    plt.imsave("radar_v6_5_fullres_low_grazing.png", log_compress(sar_low),  cmap="gray", origin="lower")

    fig_z, axes_z = plt.subplots(3, 4, figsize=(20.0, 15.0), facecolor="#0a0d0c")

    xr_b, yr_b = (-140, 180), (-40, 160)
    row0 = [
        (crop_region(top_down_rgb,            world.N, world.size_m, xr_b, yr_b), "Optical Truth: Bridge & Eroded Banks\nSleek 10m Span + Powerline Pylon", True),
        (crop_region(log_compress(sar_south), world.N, world.size_m, xr_b, yr_b), "Bridge — 0° South View\n1st Deck + 2nd Water-Truss + 3rd Multipath Echo!", False),
        (crop_region(log_compress(sar_sw),    world.N, world.size_m, xr_b, yr_b), "Bridge — 32° SW Oblique\n3-Bounce Triplet + Pier Water Reflections", False),
        (crop_region(log_compress(sar_east),  world.N, world.size_m, xr_b, yr_b), "Bridge — 90° East-Flank View\nNatural Eroded Riverbank (No Smooth Band!)", False),
    ]

    xr_w, yr_w = (330, 660), (130, 350)
    row1 = [
        (crop_region(top_down_rgb,            world.N, world.size_m, xr_w, yr_w), "Optical Truth: Warehouse Compound\nService Roads & Clean Roofs with HVACs", True),
        (crop_region(log_compress(sar_south), world.N, world.size_m, xr_w, yr_w), "Compound — 0° South View\nONLY South Walls Flash (Zero 4-Wall Dots!)", False),
        (crop_region(log_compress(sar_sw),    world.N, world.size_m, xr_w, yr_w), "Compound — 32° SW Oblique\nCrisp L-Fronts on A/B; SW Wall of C Blazes!", False),
        (crop_region(log_compress(sar_east),  world.N, world.size_m, xr_w, yr_w), "Compound — 90° East-Flank View\nONLY East Gable Walls Flash + West Shadows!", False),
    ]

    xr_s, yr_s = (-700, -280), (-660, -240)
    row2 = [
        (crop_region(top_down_rgb,            world.N, world.size_m, xr_s, yr_s), "Optical Truth: SAM Site Infrastructure\nRing Road & Dirt Spurs to Each TEL Berm", True),
        (crop_region(log_compress(sar_south), world.N, world.size_m, xr_s, yr_s), "SAM Site — 0° South View\nOrthogonal '+' Diffraction Cross + Pit Multipath", False),
        (crop_region(log_compress(sar_sw),    world.N, world.size_m, xr_s, yr_s), "SAM Site — 32° SW Oblique\nRotated 'x' Diffraction Cross + Radial Tracks", False),
        (crop_region(log_compress(sar_low),   world.N, world.size_m, xr_s, yr_s), "SAM Site — Low Grazing (Z=620m)\nDeep Berm Shadows + Mast Multipath", False),
    ]

    for r_i, (row_data, ext) in enumerate([(row0, [*xr_b, *yr_b]), (row1, [*xr_w, *yr_w]), (row2, [*xr_s, *yr_s])]):
        for c_i, (patch, title, is_rgb) in enumerate(row_data):
            ax = axes_z[r_i, c_i]
            if is_rgb:
                ax.imshow(patch, origin="lower", extent=ext)
            else:
                ax.imshow(patch, origin="lower", cmap="gray", vmin=0.0, vmax=1.0, extent=ext, interpolation="nearest")
            ax.set_title(title, color="#ffd966" if is_rgb else "#7fffd4", fontsize=9.5, fontweight="bold")
            ax.tick_params(colors="#88aa99", labelsize=8)

    plt.tight_layout()
    plt.savefig("radar_v6_5_perfect_inspector.png", dpi=300, facecolor=fig_z.get_facecolor())
    print("Saved 'radar_v6_5_perfect_inspector.png' and full-res V6.5 PNGs!")