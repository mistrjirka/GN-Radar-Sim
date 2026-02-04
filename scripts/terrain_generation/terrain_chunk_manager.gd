# Manages procedural terrain chunks around a target (aircraft)
# Generates collision-only chunks using HeightMapShape3D (no mesh rendering)
extends Node3D
class_name TerrainChunkManager

const ProceduralTerrainClass = preload("res://scripts/terrain_generation/procedural_terrain.gd")

signal chunk_loaded(chunk_pos: Vector2i)
signal chunk_unloaded(chunk_pos: Vector2i)

@export_category("Terrain Settings")
@export var terrain_seed: int = 12345
@export var chunk_size: float = 256.0            ## Size of each chunk in meters
@export var load_radius: float = 2000.0          ## Distance to load chunks around target
@export var unload_radius: float = 2500.0        ## Distance to unload chunks (hysteresis)
@export var heightmap_resolution: int = 65       ## Samples per chunk side (power of 2 + 1)

@export_category("Target")
@export var target_node_path: NodePath           ## Node to follow (aircraft)

@export_category("Performance")
@export var chunks_per_frame: int = 1            ## Max chunks to generate per frame
@export var collision_layer: int = 1             ## Physics collision layer for terrain
@export var collision_mask: int = 0xFFFFFFFF     ## Physics collision mask

@export_category("Debug")
@export var debug_draw_chunks: bool = false      ## Draw chunk boundaries

# Internal state
var _terrain: ProceduralTerrainClass
var _target: Node3D
var _chunks: Dictionary = {}                     ## Vector2i -> StaticBody3D
var _pending_chunks: Array[Vector2i] = []        ## Chunks waiting to be generated
var _target_chunk: Vector2i = Vector2i.ZERO      ## Current chunk the target is in

func _ready() -> void:
	_terrain = ProceduralTerrainClass.new(terrain_seed)
	
	if target_node_path:
		_target = get_node_or_null(target_node_path)
	
	if not _target:
		push_warning("[TerrainChunkManager] No target node set - terrain won't update")

func get_terrain() -> ProceduralTerrainClass:
	"""Get the terrain height function for object placement"""
	return _terrain

func set_terrain_params(params: Dictionary) -> void:
	"""Configure terrain noise parameters"""
	if params.has("base_scale"):
		_terrain.base_scale = params.base_scale
	if params.has("base_amplitude"):
		_terrain.base_amplitude = params.base_amplitude
	if params.has("hills_scale"):
		_terrain.hills_scale = params.hills_scale
	if params.has("hills_amplitude"):
		_terrain.hills_amplitude = params.hills_amplitude
	if params.has("detail_scale"):
		_terrain.detail_scale = params.detail_scale
	if params.has("detail_amplitude"):
		_terrain.detail_amplitude = params.detail_amplitude
	if params.has("enable_ridged"):
		_terrain.enable_ridged = params.enable_ridged
	if params.has("ridged_scale"):
		_terrain.ridged_scale = params.ridged_scale
	if params.has("ridged_amplitude"):
		_terrain.ridged_amplitude = params.ridged_amplitude
	if params.has("enable_voronoi"):
		_terrain.enable_voronoi = params.enable_voronoi
	if params.has("enable_domain_warp"):
		_terrain.enable_domain_warp = params.enable_domain_warp
	
	# Regenerate all chunks with new parameters
	_regenerate_all_chunks()

func _regenerate_all_chunks() -> void:
	"""Clear and regenerate all loaded chunks"""
	for chunk_pos in _chunks.keys():
		_unload_chunk(chunk_pos)
	_chunks.clear()
	_pending_chunks.clear()

func _process(_delta: float) -> void:
	if not _target:
		return
	
	var target_pos: Vector3 = _target.global_position
	_target_chunk = _world_to_chunk(target_pos)
	
	# Queue chunks that need loading
	_update_chunk_loading(target_pos)
	
	# Unload distant chunks
	_update_chunk_unloading(target_pos)
	
	# Process pending chunk generation
	_process_pending_chunks()

func _world_to_chunk(world_pos: Vector3) -> Vector2i:
	"""Convert world position to chunk coordinates"""
	return Vector2i(
		int(floor(world_pos.x / chunk_size)),
		int(floor(world_pos.z / chunk_size))
	)

func _chunk_to_world_center(chunk_pos: Vector2i) -> Vector3:
	"""Get world center of a chunk"""
	return Vector3(
		(chunk_pos.x + 0.5) * chunk_size,
		0.0,
		(chunk_pos.y + 0.5) * chunk_size
	)

func _update_chunk_loading(target_pos: Vector3) -> void:
	"""Queue chunks within load radius"""
	var chunks_radius: int = int(ceil(load_radius / chunk_size))
	
	for dx in range(-chunks_radius, chunks_radius + 1):
		for dz in range(-chunks_radius, chunks_radius + 1):
			var chunk_pos: Vector2i = _target_chunk + Vector2i(dx, dz)
			
			# Skip if already loaded or pending
			if _chunks.has(chunk_pos) or chunk_pos in _pending_chunks:
				continue
			
			# Check if within load radius
			var chunk_center: Vector3 = _chunk_to_world_center(chunk_pos)
			var dist: float = Vector2(target_pos.x - chunk_center.x, target_pos.z - chunk_center.z).length()
			
			if dist <= load_radius:
				_pending_chunks.append(chunk_pos)

func _update_chunk_unloading(target_pos: Vector3) -> void:
	"""Unload chunks beyond unload radius"""
	var to_unload: Array[Vector2i] = []
	
	for chunk_pos in _chunks.keys():
		var chunk_center: Vector3 = _chunk_to_world_center(chunk_pos)
		var dist: float = Vector2(target_pos.x - chunk_center.x, target_pos.z - chunk_center.z).length()
		
		if dist > unload_radius:
			to_unload.append(chunk_pos)
	
	for chunk_pos in to_unload:
		_unload_chunk(chunk_pos)

func _process_pending_chunks() -> void:
	"""Generate queued chunks (limited per frame)"""
	var generated: int = 0
	
	while not _pending_chunks.is_empty() and generated < chunks_per_frame:
		var chunk_pos: Vector2i = _pending_chunks.pop_front()
		
		# Double-check it's not already loaded
		if _chunks.has(chunk_pos):
			continue
		
		_generate_chunk(chunk_pos)
		generated += 1

func _generate_chunk(chunk_pos: Vector2i) -> void:
	"""Generate a collision-only terrain chunk"""
	var chunk_center: Vector3 = _chunk_to_world_center(chunk_pos)
	
	# Generate heightmap data
	var height_data: PackedFloat32Array = _terrain.sample_heightmap(
		chunk_center.x, chunk_center.z,
		chunk_size, heightmap_resolution
	)
	
	# Create HeightMapShape3D
	var shape: HeightMapShape3D = HeightMapShape3D.new()
	shape.map_width = heightmap_resolution
	shape.map_depth = heightmap_resolution
	shape.map_data = height_data
	
	# Create collision shape
	var collision: CollisionShape3D = CollisionShape3D.new()
	collision.shape = shape
	
	# Scale to match world size (HeightMapShape3D is 1 unit per sample)
	var scale_factor: float = chunk_size / float(heightmap_resolution - 1)
	collision.scale = Vector3(scale_factor, 1.0, scale_factor)
	
	# Position at chunk corner (HeightMapShape3D starts at origin)
	collision.position = Vector3(
		-chunk_size * 0.5,
		0.0,
		-chunk_size * 0.5
	)
	
	# Create StaticBody3D for the chunk
	var body: StaticBody3D = StaticBody3D.new()
	body.name = "TerrainChunk_%d_%d" % [chunk_pos.x, chunk_pos.y]
	body.position = chunk_center
	body.collision_layer = collision_layer
	body.collision_mask = collision_mask
	
	# Set terrain metadata for radar
	body.set_meta("radar_rcs", 0.3)         # Terrain is less reflective
	body.set_meta("radar_specular", false)  # Diffuse reflection
	
	body.add_child(collision)
	add_child(body)
	
	_chunks[chunk_pos] = body
	emit_signal("chunk_loaded", chunk_pos)

func _unload_chunk(chunk_pos: Vector2i) -> void:
	"""Remove a terrain chunk"""
	if not _chunks.has(chunk_pos):
		return
	
	var body: StaticBody3D = _chunks[chunk_pos]
	body.queue_free()
	_chunks.erase(chunk_pos)
	
	emit_signal("chunk_unloaded", chunk_pos)

func get_height_at(world_x: float, world_z: float) -> float:
	"""Get terrain height at world coordinates"""
	return _terrain.get_height(world_x, world_z)

func get_position_on_terrain(world_x: float, world_z: float) -> Vector3:
	"""Get full position on terrain surface"""
	return Vector3(world_x, _terrain.get_height(world_x, world_z), world_z)

func get_loaded_chunk_count() -> int:
	"""Get number of currently loaded chunks"""
	return _chunks.size()

func get_pending_chunk_count() -> int:
	"""Get number of chunks waiting to generate"""
	return _pending_chunks.size()

func force_update() -> void:
	"""Force immediate chunk update (useful after teleporting)"""
	while not _pending_chunks.is_empty():
		var chunk_pos: Vector2i = _pending_chunks.pop_front()
		if not _chunks.has(chunk_pos):
			_generate_chunk(chunk_pos)
