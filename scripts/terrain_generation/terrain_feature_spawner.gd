# Spawns features (objects, structures) on procedural terrain
# Works with TerrainChunkManager to place objects at correct height
extends Node3D
class_name TerrainFeatureSpawner

const ProceduralTerrainClass = preload("res://scripts/terrain_generation/procedural_terrain.gd")
const TerrainChunkManagerClass = preload("res://scripts/terrain_generation/terrain_chunk_manager.gd")

signal feature_spawned(feature: Node3D, world_pos: Vector3)
signal feature_despawned(feature: Node3D)

@export_category("Feature Library")
## Array of PackedScene resources to spawn
@export var feature_scenes: Array[PackedScene] = []
## Weights for each feature (higher = more likely). Same order as feature_scenes.
@export var feature_weights: Array[float] = []

@export_category("Spawning Rules")
@export var spawn_density: float = 0.001         ## Features per square meter (0.001 = 1 per 1000m²)
@export var min_spacing: float = 50.0            ## Minimum distance between features
@export var max_slope_deg: float = 15.0          ## Max terrain slope for placement
@export var spawn_radius: float = 1500.0         ## Spawn features within this radius of target
@export var despawn_radius: float = 2000.0       ## Despawn features beyond this radius
@export var spawn_seed: int = 54321              ## Seed for deterministic spawning

@export_category("Target")
@export var target_node_path: NodePath           ## Node to follow (aircraft) 
@export var terrain_manager_path: NodePath       ## Path to TerrainChunkManager
var target_node: Node3D = null                   ## Direct reference (set via code)
var terrain_manager_node: Node3D = null          ## Direct reference (set via code)

@export_category("Radar Properties")
@export var default_radar_rcs: float = 0.5       ## Default RCS for spawned features (ground terrain is 0.3)
@export var default_radar_specular: bool = true  ## Default specular reflection

@export_category("Terrain Flattening")
@export var flatten_under_features: bool = true  ## Flatten terrain under spawned features
@export var flatten_blend_factor: float = 1.0     ## Blend distance as multiplier of footprint radius (1.0 = smooth, 0.5 = tighter)
@export var flatten_padding: float = 2.0          ## Extra meters added to footprint radius

@export_category("Performance")
@export var features_per_frame: int = 2          ## Max features to spawn per frame
@export var check_interval: float = 0.5          ## Seconds between spawn checks

# Internal state
var _terrain_manager: TerrainChunkManagerClass
var _terrain: ProceduralTerrainClass
var _target: Node3D
var _spawned_features: Dictionary = {}           ## Vector2i (cell) -> Array[Node3D]
var _cell_size: float = 100.0                    ## Grid cell size for spatial hashing
var _pending_cells: Array[Vector2i] = []         ## Cells waiting to spawn features
var _check_timer: float = 0.0
var _rng: RandomNumberGenerator
var _scene_aabb_cache: Dictionary = {}           ## int (scene index) -> AABB  (actual model bounds)
var _feature_zone_ids: Dictionary = {}           ## Node3D instance_id -> int (flatten zone id)

func _ready() -> void:
	_rng = RandomNumberGenerator.new()
	_rng.seed = spawn_seed
	
	# Try direct references first, then paths
	if target_node:
		_target = target_node
	elif target_node_path:
		_target = get_node_or_null(target_node_path)
	
	if terrain_manager_node:
		_terrain_manager = terrain_manager_node
		if _terrain_manager:
			_terrain = _terrain_manager.get_terrain()
	elif terrain_manager_path:
		_terrain_manager = get_node_or_null(terrain_manager_path)
		if _terrain_manager:
			_terrain = _terrain_manager.get_terrain()
	
	if not _target:
		push_warning("[TerrainFeatureSpawner] No target node set")
	if not _terrain_manager:
		push_warning("[TerrainFeatureSpawner] No terrain manager set")
	
	# Normalize weights
	_normalize_weights()
	
	# Pre-compute actual AABB for every scene in the library
	_cache_all_scene_aabbs()

func _cache_all_scene_aabbs() -> void:
	"""Instantiate each scene once, add to tree, measure the real AABB in WORLD space, then free it.
	Using world-space AABB is critical for imported scenes (like Sketchfab GLTF)
	that have axis-swap rotations in their root transform."""
	for i in range(feature_scenes.size()):
		var scene: PackedScene = feature_scenes[i]
		if not scene:
			continue
		var instance: Node3D = scene.instantiate()
		# Add to tree temporarily so Godot processes all transforms
		add_child(instance)
		# Place at origin for measurement — world AABB will directly give us offsets
		instance.global_position = Vector3.ZERO
		# Force transform update
		instance.force_update_transform()
		
		# Compute the AABB in WORLD SPACE (not root-local!) by walking all VisualInstance3Ds
		var aabb: AABB = _get_world_space_aabb(instance)
		
		if aabb.size.length() < 0.01:
			# Last resort fallback
			aabb = AABB(Vector3(-1, 0, -1), Vector3(2, 2, 2))
			push_warning("[FeatureSpawner] Scene %d has no meshes — using fallback AABB" % i)
		
		_scene_aabb_cache[i] = aabb
		instance.queue_free()
		print("[FeatureSpawner] Scene %d world AABB: pos=%s  size=%s" % [i, aabb.position, aabb.size])
		print("[FeatureSpawner]   bottom_y=%.3f  top_y=%.3f  xz_extent=%.1f×%.1f" % [
			aabb.position.y, aabb.position.y + aabb.size.y, aabb.size.x, aabb.size.z])

func _get_world_space_aabb(root: Node3D) -> AABB:
	"""Compute merged AABB in WORLD space from all VisualInstance3D children.
	The instance must be in the tree. Root should be at global_position = ZERO."""
	var result: Array = [AABB(), false]  # [aabb, has_any]
	_collect_world_aabbs(root, result)
	return result[0]

func _collect_world_aabbs(node: Node, result: Array) -> void:
	"""Recursively collect visual AABBs transformed to world space."""
	if node is VisualInstance3D:
		var vi: VisualInstance3D = node as VisualInstance3D
		var mesh_aabb: AABB = vi.get_aabb()
		if mesh_aabb.size.length() > 0.001:
			# Transform AABB from node-local into world space
			var world_aabb: AABB = _transform_aabb(mesh_aabb, vi.global_transform)
			if not result[1]:
				result[0] = world_aabb
				result[1] = true
			else:
				result[0] = result[0].merge(world_aabb)
	
	for child in node.get_children():
		_collect_world_aabbs(child, result)

func _compute_recursive_aabb(node: Node3D, parent_xform: Transform3D) -> AABB:
	"""Walk the scene tree and merge all MeshInstance3D AABBs in local-root space."""
	var combined: AABB = AABB()
	var has_any: bool = false
	var node_xform: Transform3D = parent_xform * node.transform
	
	if node is MeshInstance3D and node.mesh:
		var mesh_aabb: AABB = node.mesh.get_aabb()
		# Transform mesh AABB corners into root space
		var transformed: AABB = _transform_aabb(mesh_aabb, node_xform)
		if not has_any:
			combined = transformed
			has_any = true
		else:
			combined = combined.merge(transformed)
	
	for child in node.get_children():
		if child is Node3D:
			var child_aabb: AABB = _compute_recursive_aabb(child, node_xform)
			if child_aabb.size != Vector3.ZERO:
				if not has_any:
					combined = child_aabb
					has_any = true
				else:
					combined = combined.merge(child_aabb)
	
	return combined

func _transform_aabb(aabb: AABB, xform: Transform3D) -> AABB:
	"""Transform an AABB by a Transform3D by transforming all 8 corners."""
	var corners: Array[Vector3] = []
	for ix in [0.0, 1.0]:
		for iy in [0.0, 1.0]:
			for iz in [0.0, 1.0]:
				var corner: Vector3 = aabb.position + aabb.size * Vector3(ix, iy, iz)
				corners.append(xform * corner)
	
	var result: AABB = AABB(corners[0], Vector3.ZERO)
	for c_idx in range(1, corners.size()):
		result = result.expand(corners[c_idx])
	return result

func _normalize_weights() -> void:
	"""Ensure weights array matches scenes and is normalized"""
	while feature_weights.size() < feature_scenes.size():
		feature_weights.append(1.0)
	
	var total: float = 0.0
	for w in feature_weights:
		total += w
	
	if total > 0.0:
		for i in range(feature_weights.size()):
			feature_weights[i] /= total

func _process(delta: float) -> void:
	if not _target or not _terrain:
		return
	
	_check_timer += delta
	if _check_timer >= check_interval:
		_check_timer = 0.0
		_update_spawning()
	
	# Process pending spawns
	_process_pending_spawns()

func _world_to_cell(world_pos: Vector3) -> Vector2i:
	"""Convert world position to spatial cell"""
	return Vector2i(
		int(floor(world_pos.x / _cell_size)),
		int(floor(world_pos.z / _cell_size))
	)

func _cell_to_world_center(cell: Vector2i) -> Vector3:
	"""Get world center of a cell"""
	return Vector3(
		(cell.x + 0.5) * _cell_size,
		0.0,
		(cell.y + 0.5) * _cell_size
	)

func _update_spawning() -> void:
	"""Check which cells need features spawned/despawned"""
	var target_pos: Vector3 = _target.global_position
	var target_cell: Vector2i = _world_to_cell(target_pos)
	
	# Calculate cell radius
	var cells_radius: int = int(ceil(spawn_radius / _cell_size))
	
	# Queue cells for spawning
	for dx in range(-cells_radius, cells_radius + 1):
		for dz in range(-cells_radius, cells_radius + 1):
			var cell: Vector2i = target_cell + Vector2i(dx, dz)
			
			# Skip if already processed or pending
			if _spawned_features.has(cell) or cell in _pending_cells:
				continue
			
			# Check distance
			var cell_center: Vector3 = _cell_to_world_center(cell)
			var dist: float = Vector2(target_pos.x - cell_center.x, target_pos.z - cell_center.z).length()
			
			if dist <= spawn_radius:
				_pending_cells.append(cell)
	
	# Despawn distant features
	var to_despawn: Array[Vector2i] = []
	for cell in _spawned_features.keys():
		var cell_center: Vector3 = _cell_to_world_center(cell)
		var dist: float = Vector2(target_pos.x - cell_center.x, target_pos.z - cell_center.z).length()
		
		if dist > despawn_radius:
			to_despawn.append(cell)
	
	for cell in to_despawn:
		_despawn_cell(cell)

func _process_pending_spawns() -> void:
	"""Spawn features in pending cells (limited per frame)"""
	var spawned: int = 0
	
	while not _pending_cells.is_empty() and spawned < features_per_frame:
		var cell: Vector2i = _pending_cells.pop_front()
		
		if _spawned_features.has(cell):
			continue
		
		_spawn_features_in_cell(cell)
		spawned += 1

func _spawn_features_in_cell(cell: Vector2i) -> void:
	"""Spawn features within a cell using deterministic RNG"""
	if feature_scenes.is_empty():
		_spawned_features[cell] = []
		return
	
	# Seed RNG deterministically based on cell position
	_rng.seed = spawn_seed + cell.x * 73856093 + cell.y * 19349663
	
	# Calculate expected features for this cell
	var cell_area: float = _cell_size * _cell_size
	var expected_features: float = cell_area * spawn_density
	
	# Use Poisson-like distribution
	var feature_count: int = int(expected_features)
	if _rng.randf() < (expected_features - feature_count):
		feature_count += 1
	
	var features: Array[Node3D] = []
	var placed_positions: Array[Vector3] = []
	# Collect dirty region for batched chunk regeneration
	var dirty_min_x: float = INF
	var dirty_max_x: float = -INF
	var dirty_min_z: float = INF
	var dirty_max_z: float = -INF
	var any_flattened: bool = false
	
	for _i in range(feature_count):
		# Random position within cell
		var local_x: float = _rng.randf() * _cell_size
		var local_z: float = _rng.randf() * _cell_size
		var world_x: float = cell.x * _cell_size + local_x
		var world_z: float = cell.y * _cell_size + local_z
		
		# Check slope
		if not _terrain.is_flat_enough(world_x, world_z, max_slope_deg):
			continue
		
		# Check spacing from other features in this cell
		var world_pos: Vector3 = Vector3(world_x, 0.0, world_z)
		var too_close: bool = false
		for existing_pos in placed_positions:
			if world_pos.distance_to(existing_pos) < min_spacing:
				too_close = true
				break
		
		if too_close:
			continue
		
		# Get height and spawn
		# Query the natural (unflattened) height first for placement, then
		# the flatten zone will bring the terrain to match.
		var height: float = _terrain.get_height(world_x, world_z)
		world_pos.y = height
		
		var feature: Node3D = _spawn_single_feature(world_pos)
		if feature:
			features.append(feature)
			placed_positions.append(world_pos)
			# Expand dirty region
			if flatten_under_features and feature.has_meta("_flatten_radius"):
				var r: float = feature.get_meta("_flatten_radius")
				dirty_min_x = minf(dirty_min_x, world_x - r)
				dirty_max_x = maxf(dirty_max_x, world_x + r)
				dirty_min_z = minf(dirty_min_z, world_z - r)
				dirty_max_z = maxf(dirty_max_z, world_z + r)
				any_flattened = true
	
	_spawned_features[cell] = features
	
	# Batch-regenerate all affected chunks ONCE for this cell
	if any_flattened and _terrain_manager:
		var center_x: float = (dirty_min_x + dirty_max_x) * 0.5
		var center_z: float = (dirty_min_z + dirty_max_z) * 0.5
		var half_w: float = (dirty_max_x - dirty_min_x) * 0.5
		var half_h: float = (dirty_max_z - dirty_min_z) * 0.5
		var influence: float = maxf(half_w, half_h)
		_terrain_manager.regenerate_chunks_near(center_x, center_z, influence)

func _spawn_single_feature(world_pos: Vector3, override_idx: int = -1) -> Node3D:
	"""Spawn a single feature at the given position"""
	if feature_scenes.is_empty():
		return null
	
	# Select feature based on weights
	var selected_idx: int = 0
	if override_idx >= 0:
		selected_idx = override_idx
	else:
		var roll: float = _rng.randf()
		var cumulative: float = 0.0
		for i in range(feature_weights.size()):
			cumulative += feature_weights[i]
			if roll <= cumulative:
				selected_idx = i
				break
	
	selected_idx = mini(selected_idx, feature_scenes.size() - 1)
	
	# Instantiate scene
	var scene: PackedScene = feature_scenes[selected_idx]
	if not scene:
		return null
	
	var instance: Node3D = scene.instantiate()
	
	# Random rotation around Y axis
	instance.rotation.y = _rng.randf() * TAU
	
	# --- Use cached AABB to compute footprint and correct Y offset ---
	var aabb: AABB = _scene_aabb_cache.get(selected_idx, AABB(Vector3.ZERO, Vector3(1, 1, 1)))
	
	# Footprint radius = half-diagonal of the XZ extent (covers any rotation)
	var half_x: float = aabb.size.x * 0.5
	var half_z: float = aabb.size.z * 0.5
	var footprint_radius: float = sqrt(half_x * half_x + half_z * half_z) + flatten_padding
	
	# Register flatten zone BEFORE placing, so subsequent get_height() calls
	# (including chunk regeneration) produce a flat surface here.
	if flatten_under_features and _terrain:
		var zone_id: int = _terrain.add_flatten_zone(
			world_pos.x, world_pos.z,
			footprint_radius,
			world_pos.y,
			footprint_radius * flatten_blend_factor
		)
		instance.set_meta("_flatten_zone_id", zone_id)
		# Debug: sample heights in a ring around the zone to verify flattening
		var h_center: float = _terrain.get_height(world_pos.x, world_pos.z)
		var h_edge: float = _terrain.get_height(world_pos.x + footprint_radius * 0.9, world_pos.z)
		var h_outside: float = _terrain.get_height(world_pos.x + footprint_radius + footprint_radius * flatten_blend_factor + 5.0, world_pos.z)
		print("[FeatureSpawner] Zone #%d at (%.0f,%.0f) flat_h=%.1f r=%.1f  |  h_center=%.1f h_edge=%.1f h_outside=%.1f" % [
			zone_id, world_pos.x, world_pos.z, world_pos.y, footprint_radius,
			h_center, h_edge, h_outside])
	
	# Correct Y so the bottom of the model sits on the terrain surface.
	# aabb.position.y is the model's lowest Y in WORLD SPACE (measured at origin)
	var adjusted_pos: Vector3 = world_pos
	adjusted_pos.y -= aabb.position.y  # shift up so model bottom = terrain surface
	
	print("[FeatureSpawner] Spawn #%d: terrain_h=%.1f  aabb_bottom_y=%.3f  placed_y=%.1f  footprint=%.1f" % [
		_rng.seed % 10000, world_pos.y, aabb.position.y, adjusted_pos.y, footprint_radius])
	
	# Store total influence radius for batched chunk regen
	var total_influence: float = footprint_radius + footprint_radius * flatten_blend_factor
	instance.set_meta("_flatten_radius", total_influence)
	
	# Apply radar metadata to collision children
	_apply_radar_metadata(instance)
	
	add_child(instance)
	instance.global_position = adjusted_pos
	
	# Track zone id by instance
	if instance.has_meta("_flatten_zone_id"):
		_feature_zone_ids[instance.get_instance_id()] = instance.get_meta("_flatten_zone_id")
	
	emit_signal("feature_spawned", instance, adjusted_pos)
	
	return instance

func _apply_radar_metadata(node: Node) -> void:
	"""Apply radar properties to all CollisionObject3D descendants"""
	if node is CollisionObject3D:
		node.set_meta("radar_rcs", default_radar_rcs)
		node.set_meta("radar_specular", default_radar_specular)
	
	for child in node.get_children():
		_apply_radar_metadata(child)

func _despawn_cell(cell: Vector2i) -> void:
	"""Remove all features in a cell"""
	if not _spawned_features.has(cell):
		return
	
	var features: Array = _spawned_features[cell]
	for feature in features:
		if is_instance_valid(feature):
			# Remove associated flatten zone
			var iid: int = feature.get_instance_id()
			if _feature_zone_ids.has(iid) and _terrain:
				_terrain.remove_flatten_zone(_feature_zone_ids[iid])
				_feature_zone_ids.erase(iid)
			emit_signal("feature_despawned", feature)
			feature.queue_free()
	
	_spawned_features.erase(cell)

func get_spawned_count() -> int:
	"""Get total number of spawned features"""
	var count: int = 0
	for cell in _spawned_features.keys():
		count += _spawned_features[cell].size()
	return count

func clear_all() -> void:
	"""Remove all spawned features"""
	for cell in _spawned_features.keys():
		_despawn_cell(cell)
	_spawned_features.clear()
	_pending_cells.clear()
	_feature_zone_ids.clear()
	if _terrain:
		_terrain.clear_flatten_zones()

func force_spawn_at(world_pos: Vector3, scene_index: int = 0) -> Node3D:
	"""Manually spawn a specific feature at a position (uses AABB + flattening)"""
	if scene_index < 0 or scene_index >= feature_scenes.size():
		return null
	
	# Adjust Y to terrain height
	var height: float = _terrain.get_height(world_pos.x, world_pos.z)
	world_pos.y = height
	
	var feature: Node3D = _spawn_single_feature(world_pos, scene_index)
	if not feature:
		return null
	
	# Track in nearest cell
	var cell: Vector2i = _world_to_cell(world_pos)
	if not _spawned_features.has(cell):
		_spawned_features[cell] = []
	_spawned_features[cell].append(feature)
	
	return feature
