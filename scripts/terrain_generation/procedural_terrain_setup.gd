# Example setup showing how to integrate procedural terrain with DBS radar
# Add this node as a child of your main scene (World)
extends Node3D
class_name ProceduralTerrainSetup

## Configure these in the inspector or via code
@export var terrain_seed: int = 42
@export var chunk_size: float = 128.0
@export var load_radius: float = 2000.0
@export var heightmap_resolution: int = 130

## Feature library - add PackedScene resources here
@export var feature_scenes: Array[PackedScene] = []
@export var feature_density: float = 0.0005  ## Features per m² (0.0005 = 1 per 2000m²)

var _chunk_manager: Node3D
var _feature_spawner: Node3D

func _ready() -> void:
	# Wait for parent to be ready
	call_deferred("_setup_terrain")

func _setup_terrain() -> void:
	# Find the aircraft/player node (wherever the DBS radar is)
	var aircraft: Node3D = _find_aircraft()
	if not aircraft:
		push_error("[ProceduralTerrainSetup] Could not find aircraft node!")
		return
	
	# Create terrain chunk manager
	var ChunkManagerScript = load("res://scripts/terrain_generation/terrain_chunk_manager.gd")
	_chunk_manager = ChunkManagerScript.new()
	_chunk_manager.name = "TerrainChunkManager"
	_chunk_manager.terrain_seed = terrain_seed
	_chunk_manager.chunk_size = chunk_size
	_chunk_manager.load_radius = load_radius
	_chunk_manager.heightmap_resolution = heightmap_resolution
	# Use direct node reference instead of path (path doesn't work before add_child)
	_chunk_manager.target_node = aircraft
	add_child(_chunk_manager)
	print("[ProceduralTerrainSetup] Aircraft found: ", aircraft.name, " at ", aircraft.global_position)
	
	# Wait for chunk manager to initialize
	await get_tree().process_frame
	
	# Create feature spawner if we have scenes to spawn
	if not feature_scenes.is_empty():
		var SpawnerScript = load("res://scripts/terrain_generation/terrain_feature_spawner.gd")
		_feature_spawner = SpawnerScript.new()
		_feature_spawner.name = "FeatureSpawner"
		_feature_spawner.feature_scenes = feature_scenes
		_feature_spawner.spawn_density = feature_density
		# Use direct references
		_feature_spawner.target_node = aircraft
		_feature_spawner.terrain_manager_node = _chunk_manager
		add_child(_feature_spawner)
	
	print("[ProceduralTerrainSetup] Terrain system ready!")
	print("  - Chunk size: ", chunk_size, "m")
	print("  - Load radius: ", load_radius, "m")
	print("  - Heightmap resolution: ", heightmap_resolution, "x", heightmap_resolution)

func _find_aircraft() -> Node3D:
	# Try common paths
	var paths: Array[String] = [
		"../DBSRadar",       # If DBS radar is sibling
		"../Node3D",         # Generic name
		"../Player",         # If using player scene
	]
	
	for path in paths:
		var node: Node = get_node_or_null(path)
		if node is Node3D:
			return node
	
	# Search by script - look for DBS radar script
	return _find_node_with_script(get_parent(), "node_3d_dbs.gd")

func _find_node_with_script(root: Node, script_name: String) -> Node3D:
	if root is Node3D:
		var script = root.get_script()
		if script and script.resource_path.ends_with(script_name):
			return root
	
	for child in root.get_children():
		var found = _find_node_with_script(child, script_name)
		if found:
			return found
	
	return null

func get_terrain() -> RefCounted:
	"""Get the terrain height function for external use"""
	if _chunk_manager:
		return _chunk_manager.get_terrain()
	return null

func get_height_at(x: float, z: float) -> float:
	"""Convenience function to get terrain height"""
	if _chunk_manager:
		return _chunk_manager.get_height_at(x, z)
	return 0.0

# Terrain configuration presets
func apply_preset_mountains() -> void:
	"""High ridged mountains"""
	if not _chunk_manager:
		return
	_chunk_manager.set_terrain_params({
		"base_amplitude": 80.0,
		"enable_ridged": true,
		"ridged_amplitude": 60.0,
		"hills_amplitude": 20.0,
	})

func apply_preset_rolling_hills() -> void:
	"""Gentle rolling terrain"""
	if not _chunk_manager:
		return
	_chunk_manager.set_terrain_params({
		"base_amplitude": 30.0,
		"enable_ridged": false,
		"hills_amplitude": 15.0,
		"detail_amplitude": 2.0,
	})

func apply_preset_flat_desert() -> void:
	"""Mostly flat with small dunes"""
	if not _chunk_manager:
		return
	_chunk_manager.set_terrain_params({
		"base_amplitude": 10.0,
		"enable_ridged": false,
		"hills_amplitude": 5.0,
		"detail_amplitude": 1.0,
	})
