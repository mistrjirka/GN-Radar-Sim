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
@export var default_radar_rcs: float = 2.0       ## Default RCS for spawned features
@export var default_radar_specular: bool = true  ## Default specular reflection

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
		var height: float = _terrain.get_height(world_x, world_z)
		world_pos.y = height
		
		var feature: Node3D = _spawn_single_feature(world_pos)
		if feature:
			features.append(feature)
			placed_positions.append(world_pos)
	
	_spawned_features[cell] = features

func _spawn_single_feature(world_pos: Vector3) -> Node3D:
	"""Spawn a single feature at the given position"""
	if feature_scenes.is_empty():
		return null
	
	# Select feature based on weights
	var roll: float = _rng.randf()
	var cumulative: float = 0.0
	var selected_idx: int = 0
	
	for i in range(feature_weights.size()):
		cumulative += feature_weights[i]
		if roll <= cumulative:
			selected_idx = i
			break
	
	# Instantiate scene
	var scene: PackedScene = feature_scenes[min(selected_idx, feature_scenes.size() - 1)]
	if not scene:
		return null
	
	var instance: Node3D = scene.instantiate()
	instance.global_position = world_pos
	
	# Random rotation around Y axis
	instance.rotation.y = _rng.randf() * TAU
	
	# Apply radar metadata to collision children
	_apply_radar_metadata(instance)
	
	add_child(instance)
	emit_signal("feature_spawned", instance, world_pos)
	
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

func force_spawn_at(world_pos: Vector3, scene_index: int = 0) -> Node3D:
	"""Manually spawn a specific feature at a position"""
	if scene_index < 0 or scene_index >= feature_scenes.size():
		return null
	
	var scene: PackedScene = feature_scenes[scene_index]
	if not scene:
		return null
	
	# Adjust Y to terrain height
	var height: float = _terrain.get_height(world_pos.x, world_pos.z)
	world_pos.y = height
	
	var instance: Node3D = scene.instantiate()
	instance.global_position = world_pos
	
	_apply_radar_metadata(instance)
	add_child(instance)
	emit_signal("feature_spawned", instance, world_pos)
	
	# Track in nearest cell
	var cell: Vector2i = _world_to_cell(world_pos)
	if not _spawned_features.has(cell):
		_spawned_features[cell] = []
	_spawned_features[cell].append(instance)
	
	return instance
