# Procedural terrain height function using combined noise patterns
# No mesh rendering - collision only via HeightMapShape3D chunks
extends RefCounted
class_name ProceduralTerrain

## Noise layer configuration
@export var seed_value: int = 12345

## Base terrain (large features)
var base_scale: float = 0.002          ## Scale for base terrain (lower = larger features)
var base_amplitude: float = 50.0       ## Height amplitude in meters

## Hills layer
var hills_scale: float = 0.01          ## Scale for hills
var hills_amplitude: float = 15.0      ## Hills height

## Detail layer (small bumps)
var detail_scale: float = 0.05         ## Scale for detail
var detail_amplitude: float = 3.0      ## Detail height

## Ridged noise (mountains/ridges)
var ridged_scale: float = 0.005        ## Scale for ridges
var ridged_amplitude: float = 30.0     ## Ridge height
var ridged_power: float = 2.0          ## Sharpness of ridges
var enable_ridged: bool = true

## Voronoi (rocky/cellular features)
var voronoi_scale: float = 0.008       ## Scale for voronoi
var voronoi_amplitude: float = 10.0    ## Voronoi height
var enable_voronoi: bool = false

## Terracing (optional plateau effect)
var enable_terracing: bool = false
var terrace_count: float = 8.0         ## Number of terrace levels

## Domain warping (makes terrain more organic)
var enable_domain_warp: bool = true
var warp_scale: float = 0.003
var warp_amplitude: float = 50.0       ## How much to warp coordinates

## Flatten zones – registered by the feature spawner so terrain is level
## under placed objects.  Each entry is a Dictionary:
##   { cx: float, cz: float, radius: float, height: float, blend: float, id: int }
var _flatten_zones: Dictionary = {}              ## id -> zone dict
var _next_zone_id: int = 0
var _flatten_grid: Dictionary = {}               ## Vector2i cell -> Array[int] (zone ids)
var _flatten_grid_cell: float = 64.0             ## spatial grid cell size (metres)

# Internal noise generators
var _noise_base: FastNoiseLite
var _noise_hills: FastNoiseLite
var _noise_detail: FastNoiseLite
var _noise_ridged: FastNoiseLite
var _noise_warp_x: FastNoiseLite
var _noise_warp_z: FastNoiseLite
var _noise_voronoi: FastNoiseLite

func _init(p_seed: int = 12345) -> void:
	seed_value = p_seed
	_setup_noise_generators()

func _setup_noise_generators() -> void:
	# Base terrain - smooth, large features
	_noise_base = FastNoiseLite.new()
	_noise_base.seed = seed_value
	_noise_base.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_noise_base.fractal_type = FastNoiseLite.FRACTAL_FBM
	_noise_base.fractal_octaves = 4
	_noise_base.fractal_lacunarity = 2.0
	_noise_base.fractal_gain = 0.5
	_noise_base.frequency = base_scale
	
	# Hills - medium features
	_noise_hills = FastNoiseLite.new()
	_noise_hills.seed = seed_value + 1
	_noise_hills.noise_type = FastNoiseLite.TYPE_PERLIN
	_noise_hills.fractal_type = FastNoiseLite.FRACTAL_FBM
	_noise_hills.fractal_octaves = 3
	_noise_hills.frequency = hills_scale
	
	# Detail - high frequency noise
	_noise_detail = FastNoiseLite.new()
	_noise_detail.seed = seed_value + 2
	_noise_detail.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_noise_detail.fractal_type = FastNoiseLite.FRACTAL_FBM
	_noise_detail.fractal_octaves = 2
	_noise_detail.frequency = detail_scale
	
	# Ridged noise - for mountains
	_noise_ridged = FastNoiseLite.new()
	_noise_ridged.seed = seed_value + 3
	_noise_ridged.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_noise_ridged.fractal_type = FastNoiseLite.FRACTAL_RIDGED
	_noise_ridged.fractal_octaves = 4
	_noise_ridged.frequency = ridged_scale
	
	# Domain warp noises (offset X and Z independently)
	_noise_warp_x = FastNoiseLite.new()
	_noise_warp_x.seed = seed_value + 100
	_noise_warp_x.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_noise_warp_x.frequency = warp_scale
	
	_noise_warp_z = FastNoiseLite.new()
	_noise_warp_z.seed = seed_value + 101
	_noise_warp_z.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_noise_warp_z.frequency = warp_scale
	
	# Voronoi for rocky/cellular terrain
	_noise_voronoi = FastNoiseLite.new()
	_noise_voronoi.seed = seed_value + 4
	_noise_voronoi.noise_type = FastNoiseLite.TYPE_CELLULAR
	_noise_voronoi.cellular_distance_function = FastNoiseLite.DISTANCE_EUCLIDEAN
	_noise_voronoi.cellular_return_type = FastNoiseLite.RETURN_DISTANCE
	_noise_voronoi.frequency = voronoi_scale

func set_seed(new_seed: int) -> void:
	seed_value = new_seed
	_setup_noise_generators()

func get_height(world_x: float, world_z: float) -> float:
	"""Get terrain height at world coordinates. This is the main function."""
	var x: float = world_x
	var z: float = world_z
	
	# Apply domain warping for more organic shapes
	if enable_domain_warp:
		var warp_x: float = _noise_warp_x.get_noise_2d(x, z) * warp_amplitude
		var warp_z: float = _noise_warp_z.get_noise_2d(x, z) * warp_amplitude
		x += warp_x
		z += warp_z
	
	# Combine noise layers
	var height: float = 0.0
	
	# Base terrain (returns -1 to 1, scale to amplitude)
	height += _noise_base.get_noise_2d(x, z) * base_amplitude
	
	# Hills
	height += _noise_hills.get_noise_2d(x, z) * hills_amplitude
	
	# Detail (always on)
	height += _noise_detail.get_noise_2d(x, z) * detail_amplitude
	
	# Ridged mountains
	if enable_ridged:
		var ridged: float = _noise_ridged.get_noise_2d(x, z)
		# Ridged noise is already processed by FastNoiseLite, but we can sharpen it
		ridged = pow(abs(ridged), ridged_power) * sign(ridged)
		height += ridged * ridged_amplitude
	
	# Voronoi features
	if enable_voronoi:
		var voronoi: float = _noise_voronoi.get_noise_2d(x, z)
		height += voronoi * voronoi_amplitude
	
	# Optional terracing
	if enable_terracing:
		height = _apply_terracing(height)
	
	# Apply flatten zones (features placed on terrain)
	height = _apply_flatten_zones(world_x, world_z, height)
	
	return height

func _apply_flatten_zones(world_x: float, world_z: float, natural_height: float) -> float:
	"""Blend terrain toward flat zone heights where features are placed.
	Uses spatial grid for fast lookup + smooth hermite blending."""
	if _flatten_zones.is_empty():
		return natural_height
	
	# Determine which grid cell this point is in and check neighbours
	var gx: int = int(floor(world_x / _flatten_grid_cell))
	var gz: int = int(floor(world_z / _flatten_grid_cell))
	
	var result: float = natural_height
	var checked_ids: Dictionary = {}  # avoid double-checking zones that span cells
	
	for dx in range(-1, 2):
		for dz in range(-1, 2):
			var key: Vector2i = Vector2i(gx + dx, gz + dz)
			var ids = _flatten_grid.get(key)
			if ids == null:
				continue
			for zone_id in ids:
				if checked_ids.has(zone_id):
					continue
				checked_ids[zone_id] = true
				
				var zone: Dictionary = _flatten_zones.get(zone_id)
				if zone == null:
					continue
				
				var ddx: float = world_x - zone.cx
				var ddz: float = world_z - zone.cz
				var dist_sq: float = ddx * ddx + ddz * ddz
				
				var outer: float = zone.radius + zone.blend
				if dist_sq >= outer * outer:
					continue
				
				var dist: float = sqrt(dist_sq)
				var t: float
				if dist <= zone.radius:
					t = 1.0
				else:
					var s: float = (dist - zone.radius) / zone.blend
					t = 1.0 - s * s * (3.0 - 2.0 * s)
				
				result = lerpf(result, zone.height, t)
	
	return result

func add_flatten_zone(cx: float, cz: float, radius: float, height: float, blend_dist: float = -1.0) -> int:
	"""Register a flat zone.  Returns a unique id for later removal.
	blend_dist defaults to radius (so total influence = 2 × radius)."""
	if blend_dist < 0.0:
		blend_dist = radius
	var id: int = _next_zone_id
	_next_zone_id += 1
	var zone: Dictionary = {"cx": cx, "cz": cz, "radius": radius, "height": height, "blend": blend_dist, "id": id}
	_flatten_zones[id] = zone
	_register_zone_in_grid(zone)
	return id

func remove_flatten_zone(zone_id: int) -> void:
	"""Remove a previously registered flatten zone by its id."""
	if _flatten_zones.has(zone_id):
		var zone: Dictionary = _flatten_zones[zone_id]
		_unregister_zone_from_grid(zone)
		_flatten_zones.erase(zone_id)

func clear_flatten_zones() -> void:
	"""Remove all flatten zones."""
	_flatten_zones.clear()
	_flatten_grid.clear()

func get_flatten_zone_count() -> int:
	"""Get number of registered flatten zones."""
	return _flatten_zones.size()

func get_flatten_grid_cell_count() -> int:
	"""Get number of occupied spatial grid cells."""
	return _flatten_grid.size()

func _register_zone_in_grid(zone: Dictionary) -> void:
	"""Insert a zone into all grid cells it touches."""
	var outer: float = zone.radius + zone.blend
	var min_gx: int = int(floor((zone.cx - outer) / _flatten_grid_cell))
	var max_gx: int = int(floor((zone.cx + outer) / _flatten_grid_cell))
	var min_gz: int = int(floor((zone.cz - outer) / _flatten_grid_cell))
	var max_gz: int = int(floor((zone.cz + outer) / _flatten_grid_cell))
	for gx in range(min_gx, max_gx + 1):
		for gz in range(min_gz, max_gz + 1):
			var key: Vector2i = Vector2i(gx, gz)
			if not _flatten_grid.has(key):
				_flatten_grid[key] = []
			_flatten_grid[key].append(zone.id)

func _unregister_zone_from_grid(zone: Dictionary) -> void:
	"""Remove a zone from all grid cells."""
	var outer: float = zone.radius + zone.blend
	var min_gx: int = int(floor((zone.cx - outer) / _flatten_grid_cell))
	var max_gx: int = int(floor((zone.cx + outer) / _flatten_grid_cell))
	var min_gz: int = int(floor((zone.cz - outer) / _flatten_grid_cell))
	var max_gz: int = int(floor((zone.cz + outer) / _flatten_grid_cell))
	for gx in range(min_gx, max_gx + 1):
		for gz in range(min_gz, max_gz + 1):
			var key: Vector2i = Vector2i(gx, gz)
			if _flatten_grid.has(key):
				_flatten_grid[key].erase(zone.id)
				if _flatten_grid[key].is_empty():
					_flatten_grid.erase(key)

func _apply_terracing(height: float) -> float:
	"""Create plateau/terrace effect"""
	var normalized: float = height / (base_amplitude + hills_amplitude + detail_amplitude + ridged_amplitude)
	var terraced: float = round(normalized * terrace_count) / terrace_count
	return terraced * (base_amplitude + hills_amplitude + detail_amplitude + ridged_amplitude)

func get_normal(world_x: float, world_z: float, sample_dist: float = 1.0) -> Vector3:
	"""Get surface normal at world coordinates using finite differences"""
	var h_center: float = get_height(world_x, world_z)
	var h_right: float = get_height(world_x + sample_dist, world_z)
	var h_forward: float = get_height(world_x, world_z + sample_dist)
	
	# Calculate normal from height differences
	var tangent_x: Vector3 = Vector3(sample_dist, h_right - h_center, 0.0)
	var tangent_z: Vector3 = Vector3(0.0, h_forward - h_center, sample_dist)
	
	return tangent_z.cross(tangent_x).normalized()

func get_slope(world_x: float, world_z: float) -> float:
	"""Get slope angle in radians (0 = flat, PI/2 = vertical)"""
	var normal: Vector3 = get_normal(world_x, world_z)
	return acos(normal.dot(Vector3.UP))

func is_flat_enough(world_x: float, world_z: float, max_slope_deg: float = 15.0) -> bool:
	"""Check if terrain is flat enough for object placement"""
	return rad_to_deg(get_slope(world_x, world_z)) <= max_slope_deg

func sample_heightmap(center_x: float, center_z: float, size: float, resolution: int) -> PackedFloat32Array:
	"""Generate a heightmap array for HeightMapShape3D
	
	Args:
		center_x, center_z: World position of chunk center
		size: Size of chunk in world units (square)
		resolution: Number of samples per side (must be power of 2 + 1, e.g., 65, 129, 257)
	
	Returns:
		PackedFloat32Array with resolution * resolution height values
	"""
	var data: PackedFloat32Array = PackedFloat32Array()
	data.resize(resolution * resolution)
	
	var half_size: float = size * 0.5
	var step: float = size / float(resolution - 1)
	
	var idx: int = 0
	for z_idx in range(resolution):
		for x_idx in range(resolution):
			var world_x: float = center_x - half_size + x_idx * step
			var world_z: float = center_z - half_size + z_idx * step
			data[idx] = get_height(world_x, world_z)
			idx += 1
	
	return data

func sample_heightmap_threadsafe(center_x: float, center_z: float, size: float, resolution: int) -> PackedFloat32Array:
	"""Thread-safe version of sample_heightmap.
	Takes a snapshot of flatten zones before sampling so no locking is needed
	during the (expensive) height computation loop."""
	# Snapshot mutable state (fast – typically <50 entries)
	var fz_copy: Dictionary = _flatten_zones.duplicate(true)
	var fg_copy: Dictionary = _flatten_grid.duplicate(true)
	
	var data: PackedFloat32Array = PackedFloat32Array()
	data.resize(resolution * resolution)
	
	var half_size: float = size * 0.5
	var step: float = size / float(resolution - 1)
	
	var idx: int = 0
	for z_idx in range(resolution):
		for x_idx in range(resolution):
			var world_x: float = center_x - half_size + x_idx * step
			var world_z: float = center_z - half_size + z_idx * step
			var h: float = _get_base_height(world_x, world_z)
			h = _apply_flatten_zones_from(world_x, world_z, h, fz_copy, fg_copy)
			data[idx] = h
			idx += 1
	
	return data

func _get_base_height(world_x: float, world_z: float) -> float:
	"""Compute height from noise layers only (no flatten zones).
	Thread-safe: only reads immutable noise generators."""
	var x: float = world_x
	var z: float = world_z
	
	if enable_domain_warp:
		var warp_x: float = _noise_warp_x.get_noise_2d(x, z) * warp_amplitude
		var warp_z: float = _noise_warp_z.get_noise_2d(x, z) * warp_amplitude
		x += warp_x
		z += warp_z
	
	var height: float = 0.0
	height += _noise_base.get_noise_2d(x, z) * base_amplitude
	height += _noise_hills.get_noise_2d(x, z) * hills_amplitude
	height += _noise_detail.get_noise_2d(x, z) * detail_amplitude
	
	if enable_ridged:
		var ridged: float = _noise_ridged.get_noise_2d(x, z)
		ridged = pow(abs(ridged), ridged_power) * sign(ridged)
		height += ridged * ridged_amplitude
	
	if enable_voronoi:
		var voronoi: float = _noise_voronoi.get_noise_2d(x, z)
		height += voronoi * voronoi_amplitude
	
	if enable_terracing:
		height = _apply_terracing(height)
	
	return height

func _apply_flatten_zones_from(world_x: float, world_z: float, natural_height: float, zones: Dictionary, grid: Dictionary) -> float:
	"""Blend toward flatten zones using explicit zone/grid data (thread-safe)."""
	if zones.is_empty():
		return natural_height
	
	var gx: int = int(floor(world_x / _flatten_grid_cell))
	var gz: int = int(floor(world_z / _flatten_grid_cell))
	var result: float = natural_height
	var checked_ids: Dictionary = {}
	
	for dx in range(-1, 2):
		for dz in range(-1, 2):
			var key: Vector2i = Vector2i(gx + dx, gz + dz)
			var ids = grid.get(key)
			if ids == null:
				continue
			for zone_id in ids:
				if checked_ids.has(zone_id):
					continue
				checked_ids[zone_id] = true
				var zone: Dictionary = zones.get(zone_id)
				if zone == null:
					continue
				var ddx: float = world_x - zone.cx
				var ddz: float = world_z - zone.cz
				var dist_sq: float = ddx * ddx + ddz * ddz
				var outer: float = zone.radius + zone.blend
				if dist_sq >= outer * outer:
					continue
				var dist: float = sqrt(dist_sq)
				var t: float
				if dist <= zone.radius:
					t = 1.0
				else:
					var s: float = (dist - zone.radius) / zone.blend
					t = 1.0 - s * s * (3.0 - 2.0 * s)
				result = lerpf(result, zone.height, t)
	
	return result

func find_random_placement_position(center: Vector3, radius: float, max_slope_deg: float = 15.0, max_attempts: int = 50) -> Vector3:
	"""Find a random position suitable for object placement
	
	Returns Vector3.INF if no suitable position found
	"""
	for _i in range(max_attempts):
		var angle: float = randf() * TAU
		var dist: float = randf() * radius
		var x: float = center.x + cos(angle) * dist
		var z: float = center.z + sin(angle) * dist
		
		if is_flat_enough(x, z, max_slope_deg):
			var y: float = get_height(x, z)
			return Vector3(x, y, z)
	
	return Vector3.INF

func get_height_and_normal(world_x: float, world_z: float) -> Dictionary:
	"""Get both height and normal in one call (more efficient)"""
	var h: float = get_height(world_x, world_z)
	var n: Vector3 = get_normal(world_x, world_z)
	return {"height": h, "normal": n}
