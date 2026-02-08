# Manages procedural terrain chunks around a target (aircraft)
# Generates collision chunks using HeightMapShape3D + optional debug mesh
# Supports focus-area LOD, async generation, and manual resolution override
extends Node3D
class_name TerrainChunkManager

const ProceduralTerrainClass = preload("res://scripts/terrain_generation/procedural_terrain.gd")

signal chunk_loaded(chunk_pos: Vector2i)
signal chunk_unloaded(chunk_pos: Vector2i)
signal initial_load_complete                     ## All initial chunks around target generated
signal focus_area_ready                          ## All chunks in focus area at target resolution

@export_category("Terrain Settings")
@export var terrain_seed: int = 12345
@export var chunk_size: float = 128.0            ## Size of each chunk in meters
@export var load_radius: float = 2000.0          ## Distance to load chunks around target
@export var unload_radius: float = 2500.0        ## Distance to unload chunks (hysteresis)
@export var heightmap_resolution: int = 65       ## Base resolution (samples per chunk side)

@export_category("LOD Settings")
@export var enable_lod: bool = true              ## Enable dynamic resolution based on beam width
@export var min_resolution: int = 33             ## Resolution for wide beams (low detail)
@export var max_resolution: int = 513            ## Resolution for narrow beams (high detail)
@export var beam_width_for_min_res: float = 30.0 ## Beam width (deg) where min resolution is used
@export var beam_width_for_max_res: float = 1.0  ## Beam width (deg) where max resolution is used

@export_category("Target")
@export var target_node_path: NodePath           ## Node to follow (aircraft)
var target_node: Node3D = null                   ## Direct reference (set via code)

@export_category("Performance")
@export var max_async_tasks: int = 0              ## Max concurrent background tasks (0 = auto: CPU threads - 2)
@export var collision_layer: int = 1             ## Physics collision layer for terrain
@export var collision_mask: int = 0xFFFFFFFF     ## Physics collision mask

@export_category("Debug")
@export var debug_draw_chunks: bool = false       ## Draw chunk boundaries
@export var debug_visible_terrain: bool = true    ## Render terrain as visible mesh (debug)
@export var debug_terrain_color: Color = Color(0.35, 0.55, 0.25, 1.0)  ## Terrain mesh color

var _debug_terrain_material: StandardMaterial3D
var _debug_lod_material: StandardMaterial3D        ## Material for chunks being LOD-updated (orange)

# Internal state
var _terrain: ProceduralTerrainClass
var _target: Node3D
var _chunks: Dictionary = {}                     ## Vector2i -> StaticBody3D
var _chunk_resolutions: Dictionary = {}          ## Vector2i -> int (resolution each chunk was built at)
var _target_chunk: Vector2i = Vector2i.ZERO      ## Current chunk the target is in

# Async generation state
var _generation_queue: Array[Vector2i] = []      ## Chunks waiting for async generation
var _async_pending: Dictionary = {}              ## Vector2i -> task_id (in-flight tasks)
var _async_mutex: Mutex = Mutex.new()
var _async_results: Dictionary = {}              ## Vector2i -> {data, resolution, center}

# Focus-area LOD (only chunks in beam footprint get high resolution)
var _focus_center: Vector2 = Vector2.ZERO
var _focus_radius: float = 0.0
var _focus_resolution: int = 65                  ## High-res target for focus area
var _focus_dirty: bool = false                   ## Need to apply focus changes
var _previously_focused: Dictionary = {}         ## chunk_pos -> true for chunks that were in last focus

# Manual resolution override (0 = automatic)
var _manual_resolution: int = 0
var _last_beam_width: float = 17.0

# Loading state
var _initial_load_done: bool = false
var _initial_chunks_expected: int = 0

func _ready() -> void:
	_terrain = ProceduralTerrainClass.new(terrain_seed)
	_focus_resolution = heightmap_resolution
	
	# Auto-detect thread count if not set
	if max_async_tasks <= 0:
		max_async_tasks = maxi(2, OS.get_processor_count() - 2)
	print("[ChunkManager] Using %d async tasks (%d CPU threads detected)" % [max_async_tasks, OS.get_processor_count()])
	
	# Create shared debug material
	if debug_visible_terrain:
		_debug_terrain_material = StandardMaterial3D.new()
		_debug_terrain_material.albedo_color = debug_terrain_color
		_debug_terrain_material.roughness = 0.9
		_debug_terrain_material.cull_mode = BaseMaterial3D.CULL_DISABLED
		
		_debug_lod_material = StandardMaterial3D.new()
		_debug_lod_material.albedo_color = Color(1.0, 0.5, 0.1, 1.0)  # Orange for LOD-updating
		_debug_lod_material.roughness = 0.9
		_debug_lod_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	
	# Try direct reference first, then path
	if target_node:
		_target = target_node
		print("[ChunkManager] Using direct target reference: ", _target.name)
	elif target_node_path:
		_target = get_node_or_null(target_node_path)
		if _target:
			print("[ChunkManager] Resolved target from path: ", _target.name)
	
	if not _target:
		push_warning("[ChunkManager] No target node set - terrain won't update")
	else:
		print("[ChunkManager] Target position: ", _target.global_position)

func _exit_tree() -> void:
	# Wait for all in-flight async tasks before cleanup
	for chunk_pos in _async_pending.keys():
		var task_id: int = _async_pending[chunk_pos]
		WorkerThreadPool.wait_for_task_completion(task_id)
	_async_pending.clear()

# ─── Public API ──────────────────────────────────────────────────────

func get_terrain() -> ProceduralTerrainClass:
	return _terrain

func set_beam_width(beam_width_deg: float) -> void:
	"""Update terrain LOD based on radar beam width.
	Only affects chunks inside the focus area, not the whole world."""
	if not enable_lod or _manual_resolution > 0:
		return
	_last_beam_width = beam_width_deg
	var new_res: int = _beam_width_to_resolution(beam_width_deg)
	if new_res != _focus_resolution:
		print("[ChunkManager] LOD: beam=%.1f° → focus_resolution %d (was %d)" % [beam_width_deg, new_res, _focus_resolution])
		_focus_resolution = new_res
		_focus_dirty = true

func update_focus_area(center_x: float, center_z: float, radius: float) -> void:
	"""Set the area that should be at high resolution (beam footprint).
	Chunks outside this area stay at base heightmap_resolution."""
	var new_center: Vector2 = Vector2(center_x, center_z)
	var new_radius: float = radius  # No extra margin — caller provides adequate radius
	if new_center.distance_to(_focus_center) > 10.0 or absf(new_radius - _focus_radius) > 10.0:
		_focus_center = new_center
		_focus_radius = new_radius
		_focus_dirty = true

func is_focus_ready() -> bool:
	"""True when all chunks in the focus area are at the target resolution."""
	if _focus_radius <= 0.0:
		return true
	for chunk_pos in _chunks.keys():
		if _is_chunk_in_focus(chunk_pos):
			var target_res: int = _get_chunk_target_resolution(chunk_pos)
			var current_res: int = _chunk_resolutions.get(chunk_pos, 0)
			if current_res != target_res:
				return false
	# Also check for queued/in-flight focus chunks
	for chunk_pos in _generation_queue:
		if _is_chunk_in_focus(chunk_pos):
			return false
	for chunk_pos in _async_pending.keys():
		if _is_chunk_in_focus(chunk_pos):
			return false
	return true

func is_initial_load_done() -> bool:
	return _initial_load_done

func set_manual_resolution(resolution: int) -> void:
	"""Set manual resolution override. 0 = return to automatic LOD."""
	_manual_resolution = resolution
	if resolution > 0:
		_focus_resolution = resolution
	else:
		_focus_resolution = _beam_width_to_resolution(_last_beam_width)
	_focus_dirty = true
	print("[ChunkManager] Manual LOD: %d (0=auto, current focus=%d)" % [_manual_resolution, _focus_resolution])

func step_manual_resolution(direction: int) -> int:
	"""Step resolution up (+1) or down (-1). Returns new resolution."""
	var valid: Array[int] = [17, 33, 65, 129, 257, 513]
	var current: int = _manual_resolution if _manual_resolution > 0 else _focus_resolution
	var idx: int = valid.find(current)
	if idx < 0:
		idx = valid.find(_snap_to_valid_resolution(current))
	idx = clampi(idx + direction, 0, valid.size() - 1)
	set_manual_resolution(valid[idx])
	return valid[idx]

func get_current_focus_resolution() -> int:
	return _focus_resolution

func get_meters_per_sample() -> float:
	return chunk_size / float(maxf(_focus_resolution - 1, 1.0))

func set_terrain_params(params: Dictionary) -> void:
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
	_queue_all_for_regen()

func get_height_at(world_x: float, world_z: float) -> float:
	return _terrain.get_height(world_x, world_z)

func get_position_on_terrain(world_x: float, world_z: float) -> Vector3:
	return Vector3(world_x, _terrain.get_height(world_x, world_z), world_z)

func get_loaded_chunk_count() -> int:
	return _chunks.size()

func get_pending_chunk_count() -> int:
	return _generation_queue.size() + _async_pending.size()

func regenerate_chunks_near(world_x: float, world_z: float, influence_radius: float) -> void:
	"""Queue regeneration for chunks overlapping a world-space circle."""
	var regen_count: int = 0
	for chunk_pos in _chunks.keys():
		var center: Vector3 = _chunk_to_world_center(chunk_pos)
		var half: float = chunk_size * 0.5
		var closest_x: float = clampf(world_x, center.x - half, center.x + half)
		var closest_z: float = clampf(world_z, center.z - half, center.z + half)
		var dx: float = world_x - closest_x
		var dz: float = world_z - closest_z
		if dx * dx + dz * dz <= influence_radius * influence_radius:
			_queue_chunk_regen(chunk_pos)
			regen_count += 1
	if regen_count > 0:
		print("[ChunkManager] regenerate_chunks_near(%.0f, %.0f, r=%.1f) → %d queued" % [
			world_x, world_z, influence_radius, regen_count])

# ─── Process loop ────────────────────────────────────────────────────

func _process(_delta: float) -> void:
	if not _target:
		return
	
	var target_pos: Vector3 = _target.global_position
	_target_chunk = _world_to_chunk(target_pos)
	
	_update_chunk_loading(target_pos)
	_update_chunk_unloading(target_pos)
	
	# Apply focus-area LOD changes (just queues affected chunks, doesn't block)
	if _focus_dirty:
		_apply_focus_changes()
		_focus_dirty = false
	
	# Launch async tasks for queued chunks (non-blocking)
	_dispatch_async_tasks()
	
	# Collect completed async results and build chunks on main thread
	_poll_async_results()
	
	# Track initial load completion
	if not _initial_load_done:
		if _initial_chunks_expected > 0 and _chunks.size() >= _initial_chunks_expected and _generation_queue.is_empty() and _async_pending.is_empty():
			_initial_load_done = true
			print("[ChunkManager] Initial load complete: %d chunks" % _chunks.size())
			emit_signal("initial_load_complete")

# ─── Internal helpers ────────────────────────────────────────────────

func _world_to_chunk(world_pos: Vector3) -> Vector2i:
	return Vector2i(int(floor(world_pos.x / chunk_size)), int(floor(world_pos.z / chunk_size)))

func _chunk_to_world_center(chunk_pos: Vector2i) -> Vector3:
	return Vector3((chunk_pos.x + 0.5) * chunk_size, 0.0, (chunk_pos.y + 0.5) * chunk_size)

func _update_chunk_loading(target_pos: Vector3) -> void:
	var chunks_radius: int = int(ceil(load_radius / chunk_size))
	var queued_any: bool = false
	
	for dx in range(-chunks_radius, chunks_radius + 1):
		for dz in range(-chunks_radius, chunks_radius + 1):
			var chunk_pos: Vector2i = _target_chunk + Vector2i(dx, dz)
			if _chunks.has(chunk_pos) or chunk_pos in _generation_queue or _async_pending.has(chunk_pos):
				continue
			var chunk_center: Vector3 = _chunk_to_world_center(chunk_pos)
			var dist: float = Vector2(target_pos.x - chunk_center.x, target_pos.z - chunk_center.z).length()
			if dist <= load_radius:
				_generation_queue.append(chunk_pos)
				queued_any = true
	
	if not _initial_load_done and _initial_chunks_expected == 0 and queued_any:
		_initial_chunks_expected = _generation_queue.size()
		print("[ChunkManager] Initial load: expecting %d chunks" % _initial_chunks_expected)

func _update_chunk_unloading(target_pos: Vector3) -> void:
	var to_unload: Array[Vector2i] = []
	for chunk_pos in _chunks.keys():
		var chunk_center: Vector3 = _chunk_to_world_center(chunk_pos)
		var dist: float = Vector2(target_pos.x - chunk_center.x, target_pos.z - chunk_center.z).length()
		if dist > unload_radius:
			to_unload.append(chunk_pos)
	for chunk_pos in to_unload:
		_unload_chunk(chunk_pos)

func _is_chunk_in_focus(chunk_pos: Vector2i) -> bool:
	if _focus_radius <= 0.0:
		return false
	var center: Vector3 = _chunk_to_world_center(chunk_pos)
	var half: float = chunk_size * 0.5
	var closest_x: float = clampf(_focus_center.x, center.x - half, center.x + half)
	var closest_z: float = clampf(_focus_center.y, center.z - half, center.z + half)
	var dx: float = _focus_center.x - closest_x
	var dz: float = _focus_center.y - closest_z
	return dx * dx + dz * dz <= _focus_radius * _focus_radius

func _get_chunk_target_resolution(chunk_pos: Vector2i) -> int:
	if _is_chunk_in_focus(chunk_pos):
		return _focus_resolution
	# Out-of-focus: if the chunk was previously focused and has left,
	# it should downgrade back to base. If it was never focused or
	# has already been downgraded, keep its current resolution.
	if _previously_focused.has(chunk_pos):
		# This chunk left focus — target base resolution (will be queued for downgrade)
		return heightmap_resolution
	# Never been in focus, or already at whatever it was built at
	var current: int = _chunk_resolutions.get(chunk_pos, 0)
	if current > 0:
		return current
	return heightmap_resolution

func _apply_focus_changes() -> void:
	# Cancel any in-flight async tasks whose target resolution is now stale
	_cancel_stale_async_tasks()
	# Also purge generation queue entries whose resolution already matches
	var new_queue: Array[Vector2i] = []
	for chunk_pos in _generation_queue:
		var target_res: int = _get_chunk_target_resolution(chunk_pos)
		var current_res: int = _chunk_resolutions.get(chunk_pos, 0)
		if current_res != target_res:
			new_queue.append(chunk_pos)
	_generation_queue = new_queue
	
	# Build current focus set
	var current_focus: Dictionary = {}
	for chunk_pos in _chunks.keys():
		if _is_chunk_in_focus(chunk_pos):
			current_focus[chunk_pos] = true
	
	# Downgrade chunks that LEFT focus (were focused, now aren't) back to base resolution
	for chunk_pos in _previously_focused.keys():
		if not current_focus.has(chunk_pos) and _chunks.has(chunk_pos):
			var current_res: int = _chunk_resolutions.get(chunk_pos, heightmap_resolution)
			if current_res != heightmap_resolution:
				# Force resolution back to base since rays no longer hit this chunk
				_chunk_resolutions[chunk_pos] = current_res  # keep until rebuilt
				_queue_chunk_regen(chunk_pos)
				if debug_visible_terrain and _debug_lod_material:
					_set_chunk_material(_chunks[chunk_pos], _debug_lod_material)
	
	# Update focused chunks that need higher/different resolution
	var queued: int = 0
	for chunk_pos in _chunks.keys():
		var target_res: int = _get_chunk_target_resolution(chunk_pos)
		var current_res: int = _chunk_resolutions.get(chunk_pos, heightmap_resolution)
		if current_res != target_res:
			_queue_chunk_regen(chunk_pos)
			if debug_visible_terrain and _debug_lod_material:
				_set_chunk_material(_chunks[chunk_pos], _debug_lod_material)
			queued += 1
		else:
			# Revert any orange chunks back to normal if they're now at target
			if debug_visible_terrain and _debug_terrain_material:
				_set_chunk_material(_chunks[chunk_pos], _debug_terrain_material)
	
	# Remember current focus set for next change
	_previously_focused = current_focus
	
	if queued > 0:
		print("[ChunkManager] Focus change → %d chunks queued (focus r=%.0f at %s)" % [queued, _focus_radius, _focus_center])

func _beam_width_to_resolution(beam_width_deg: float) -> int:
	var t: float = inverse_lerp(beam_width_for_max_res, beam_width_for_min_res, beam_width_deg)
	t = clamp(t, 0.0, 1.0)
	var target_res_float: float = lerp(float(max_resolution), float(min_resolution), t)
	return _snap_to_valid_resolution(int(target_res_float))

func _snap_to_valid_resolution(res: int) -> int:
	var valid: Array[int] = [17, 33, 65, 129, 257, 513]
	var best: int = valid[0]
	var best_diff: int = abs(res - best)
	for v in valid:
		var diff: int = abs(res - v)
		if diff < best_diff:
			best = v
			best_diff = diff
		if v > res:
			break
	return best

func _queue_chunk_regen(chunk_pos: Vector2i) -> void:
	if chunk_pos in _generation_queue or _async_pending.has(chunk_pos):
		return
	# Priority: LOD increases (higher res) go to front, decreases go to back
	var target_res: int = _get_chunk_target_resolution(chunk_pos)
	var current_res: int = _chunk_resolutions.get(chunk_pos, 0)
	if target_res > current_res:
		# Increasing detail — high priority, insert at front
		_generation_queue.insert(0, chunk_pos)
	else:
		# Decreasing detail or new chunk — low priority, append at back
		_generation_queue.append(chunk_pos)

func _queue_all_for_regen() -> void:
	for chunk_pos in _chunks.keys():
		_queue_chunk_regen(chunk_pos)

# ─── Async generation ───────────────────────────────────────────────

func _dispatch_async_tasks() -> void:
	while not _generation_queue.is_empty() and _async_pending.size() < max_async_tasks:
		var chunk_pos: Vector2i = _generation_queue.pop_front()
		if _async_pending.has(chunk_pos):
			continue
		var center: Vector3 = _chunk_to_world_center(chunk_pos)
		var res: int = _get_chunk_target_resolution(chunk_pos)
		# Skip if already at target resolution
		if _chunks.has(chunk_pos) and _chunk_resolutions.get(chunk_pos, 0) == res:
			# Revert color since no update needed
			if debug_visible_terrain and _debug_terrain_material and _chunks.has(chunk_pos):
				_set_chunk_material(_chunks[chunk_pos], _debug_terrain_material)
			continue
		var task_id: int = WorkerThreadPool.add_task(
			_async_sample_heightmap.bind(chunk_pos, center, res)
		)
		_async_pending[chunk_pos] = task_id

func _async_sample_heightmap(chunk_pos: Vector2i, center: Vector3, res: int) -> void:
	"""Worker thread: sample heightmap data (thread-safe)."""
	var data: PackedFloat32Array = _terrain.sample_heightmap_threadsafe(
		center.x, center.z, chunk_size, res
	)
	_async_mutex.lock()
	_async_results[chunk_pos] = {"data": data, "resolution": res, "center": center}
	_async_mutex.unlock()

func _poll_async_results() -> void:
	var completed: Array[Vector2i] = []
	for chunk_pos in _async_pending.keys():
		var task_id: int = _async_pending[chunk_pos]
		if WorkerThreadPool.is_task_completed(task_id):
			WorkerThreadPool.wait_for_task_completion(task_id)
			completed.append(chunk_pos)
	
	for chunk_pos in completed:
		_async_pending.erase(chunk_pos)
		_async_mutex.lock()
		var result: Dictionary = _async_results.get(chunk_pos, {})
		_async_results.erase(chunk_pos)
		_async_mutex.unlock()
		if result.is_empty():
			continue
		# Check if the result is still at the desired resolution —
		# if focus changed while this was in-flight, discard and re-queue
		var target_res: int = _get_chunk_target_resolution(chunk_pos)
		if result.resolution != target_res:
			_queue_chunk_regen(chunk_pos)
			continue
		if _chunks.has(chunk_pos):
			_unload_chunk(chunk_pos)
		_build_chunk(chunk_pos, result.data, result.resolution, result.center)

# ─── Chunk building (main thread only) ──────────────────────────────

func _build_chunk(chunk_pos: Vector2i, height_data: PackedFloat32Array, res: int, chunk_center: Vector3) -> void:
	var shape: HeightMapShape3D = HeightMapShape3D.new()
	shape.map_width = res
	shape.map_depth = res
	shape.map_data = height_data
	
	var collision: CollisionShape3D = CollisionShape3D.new()
	collision.shape = shape
	var scale_factor: float = chunk_size / float(res - 1)
	collision.scale = Vector3(scale_factor, 1.0, scale_factor)
	
	var body: StaticBody3D = StaticBody3D.new()
	body.name = "TerrainChunk_%d_%d" % [chunk_pos.x, chunk_pos.y]
	body.position = chunk_center
	body.collision_layer = collision_layer
	body.collision_mask = collision_mask
	body.set_meta("radar_rcs", 0.3)
	body.set_meta("radar_specular", false)
	body.add_child(collision)
	
	if debug_visible_terrain:
		var mesh_instance: MeshInstance3D = _create_terrain_mesh(height_data, res, chunk_size)
		body.add_child(mesh_instance)
	
	add_child(body)
	_chunks[chunk_pos] = body
	_chunk_resolutions[chunk_pos] = res
	
	# Revert LOD debug color back to normal after build completes
	if debug_visible_terrain and _debug_terrain_material:
		_set_chunk_material(body, _debug_terrain_material)
	
	emit_signal("chunk_loaded", chunk_pos)

func _unload_chunk(chunk_pos: Vector2i) -> void:
	if not _chunks.has(chunk_pos):
		return
	_chunks[chunk_pos].queue_free()
	_chunks.erase(chunk_pos)
	_chunk_resolutions.erase(chunk_pos)
	emit_signal("chunk_unloaded", chunk_pos)

# ─── Debug mesh ─────────────────────────────────────────────────────

func _set_chunk_material(body: Node3D, mat: StandardMaterial3D) -> void:
	"""Set the material on the MeshInstance3D child of a chunk body."""
	for child in body.get_children():
		if child is MeshInstance3D:
			child.material_override = mat
			break

func _cancel_stale_async_tasks() -> void:
	"""Cancel async tasks whose target resolution changed since they were dispatched.
	We can't actually cancel WorkerThreadPool tasks, but we can let them complete
	and discard the results in _poll_async_results by checking resolution.
	Here we just clear the queue of anything that's now up-to-date."""
	var stale_queue: Array[Vector2i] = []
	for chunk_pos in _generation_queue:
		var target_res: int = _get_chunk_target_resolution(chunk_pos)
		var current_res: int = _chunk_resolutions.get(chunk_pos, 0)
		if current_res == target_res:
			stale_queue.append(chunk_pos)
	for chunk_pos in stale_queue:
		_generation_queue.erase(chunk_pos)
		if debug_visible_terrain and _debug_terrain_material and _chunks.has(chunk_pos):
			_set_chunk_material(_chunks[chunk_pos], _debug_terrain_material)

func _create_terrain_mesh(height_data: PackedFloat32Array, res: int, size: float) -> MeshInstance3D:
	var st: SurfaceTool = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	
	var step: float = size / float(res - 1)
	var half: float = size * 0.5
	
	@warning_ignore("INTEGER_DIVISION")
	var mesh_step: int = maxi(1, res / 64)
	
	# Build list of sampled indices, always including edges (0 and res-1)
	var indices: PackedInt32Array = PackedInt32Array()
	var idx: int = 0
	while idx < res - 1:
		indices.append(idx)
		idx += mesh_step
	indices.append(res - 1)  # Always include last edge
	
	var idx_count: int = indices.size()
	for zi in range(idx_count - 1):
		for xi in range(idx_count - 1):
			var x0_idx: int = indices[xi]
			var x1_idx: int = indices[xi + 1]
			var z0_idx: int = indices[zi]
			var z1_idx: int = indices[zi + 1]
			var x0: float = x0_idx * step - half
			var z0: float = z0_idx * step - half
			var x1: float = x1_idx * step - half
			var z1: float = z1_idx * step - half
			var h00: float = height_data[z0_idx * res + x0_idx]
			var h10: float = height_data[z0_idx * res + x1_idx]
			var h01: float = height_data[z1_idx * res + x0_idx]
			var h11: float = height_data[z1_idx * res + x1_idx]
			var v00: Vector3 = Vector3(x0, h00, z0)
			var v10: Vector3 = Vector3(x1, h10, z0)
			var v01: Vector3 = Vector3(x0, h01, z1)
			var v11: Vector3 = Vector3(x1, h11, z1)
			st.add_vertex(v00)
			st.add_vertex(v10)
			st.add_vertex(v11)
			st.add_vertex(v00)
			st.add_vertex(v11)
			st.add_vertex(v01)
	
	st.generate_normals()
	var mesh: ArrayMesh = st.commit()
	var mesh_instance: MeshInstance3D = MeshInstance3D.new()
	mesh_instance.mesh = mesh
	mesh_instance.material_override = _debug_terrain_material
	mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mesh_instance
