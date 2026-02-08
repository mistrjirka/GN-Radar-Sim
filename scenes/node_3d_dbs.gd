# Godot 4.x - DBS (Doppler Beam Sharpening) Radar
# Based on working Python implementation
# Optimized: Raycasting spread over multiple frames for better FPS
extends Node3D

@export_category("Aircraft Movement")
@export var velocity_mps: float = 200.0              ## Aircraft movement velocity in m/s
@export var orbit_radius: float = 150.0              ## Radius of circular orbit around target (closer to middle)
@export var orbit_altitude: float = 100.0            ## Constant altitude above map_center.y
@export var enable_movement: bool = false            ## Toggle movement
@export var orbit_clockwise: bool = true             ## Orbit direction

var _orbit_angle: float = 0.0                        ## Current angle in radians

@export_category("Radar Parameters")
@export var wavelength_m: float = 0.03               ## X-band ~3cm wavelength
@export var beam_width_deg: float = 17.0             ## Beam width for ~40x40m scan area
@export var dbs_velocity_mps: float = 500.0          ## Velocity used for DBS Doppler calculation (can differ from movement)

@export_category("Raycasting Resolution")
@export var azimuth_count: int = 500                 ## Number of rays in azimuth
@export var elevation_count: int = 150               ## Number of rays in elevation

@export_category("Performance")
@export var rays_per_frame: int = 5000               ## Number of rays to cast per frame (adjust for FPS)
@export var target_fps: float = 30.0                 ## Target FPS - auto-adjusts rays_per_frame
@export var raycast_budget_ms: float = 8.0           ## Time budget for raycasting per frame (ms)

@export_category("Map Area")
@export var map_center: Vector3 = Vector3.ZERO       ## Center of target area (where beam aims)
@export var target_area_from_beam: bool = true       ## Auto-compute target area from beam footprint
@export var target_area_size: float = 40.0           ## Manual override (used when target_area_from_beam is false)

@export_category("Image")
@export var image_size: int = 512                    ## Square image size
@export var background_color: Color = Color(0.0, 0.0, 0.0, 1.0)

@export_category("Display")
@export var display_range_x: Vector2 = Vector2(-250, 250)  ## DBS X display range
@export var display_range_y: Vector2 = Vector2(-250, 250)  ## DBS Y display range
@export var auto_fit_range: bool = true              ## Auto-fit display range to data
@export var preserve_aspect_ratio: bool = true       ## Keep physical proportions on display
@export var accumulate_scans: int = 20                ## Number of scans to accumulate (1=no accumulation)
@export_enum("Median", "Average") var accumulate_mode: int = 0  ## 0=Median (noise-robust), 1=Average (smoother)
@export var colormap: int = 0                        ## 0=Inferno, 1=Green, 2=Grayscale
@export var intensity_gamma: float = 0.5             ## Gamma correction for intensity

@export_category("Noise")
@export var doppler_noise_std: float = 5.0          ## Standard deviation of Doppler noise (Hz)
@export var enable_speckle: bool = true              ## Enable speckle noise

@export_category("Surface Properties")
@export var cube_height_threshold: float = 55.0      ## Height above which is considered "cube" (specular) - fallback only
@export var specular_exponent: float = 6.0           ## Specular reflection sharpness (default)
@export var specular_multiplier: float = 15.0        ## Specular intensity multiplier (default)
@export var diffuse_base: float = 0.1                ## Base diffuse intensity (default)
@export var diffuse_multiplier: float = 0.5          ## Diffuse intensity multiplier (default)
## Metadata keys on colliders: radar_rcs (float), radar_specular (bool), radar_specular_exp (float)

@export_category("Physics")
@export var collision_mask: int = 0xFFFFFFFF

@export_category("UI")
@export var ui_size_px: Vector2i = Vector2i(400, 400)
@export var ui_anchor_top_left: Vector2 = Vector2(12, 12)

@export_category("Debug")
@export var debug_draw_beam: bool = true
@export var debug_print_stats: bool = true

var _space_state: PhysicsDirectSpaceState3D
var _img: Image
var _tex: ImageTexture
var _img_rb: Image            # Real Beam image
var _tex_rb: ImageTexture     # Real Beam texture
var _ui_layer: CanvasLayer
var _ui_rect: TextureRect
var _ui_rect_rb: TextureRect  # Real Beam display
var _countdown_label: Label   # Scan countdown / ETA
var _scale_label_rb: Label    # RB scale indicator
var _scale_label_dbs: Label   # DBS scale indicator
var _lod_label: Label         # Current LOD resolution display
var _chunk_manager: Node3D    # Reference to TerrainChunkManager for LOD
var _loading_overlay: ColorRect  # Loading screen overlay
var _loading_label: Label     # Loading screen text
var _waiting_for_terrain: bool = false  # Waiting for terrain chunks to reach target resolution

# DBS data buffer: Array of [dbs_x, dbs_y, intensity]
var _dbs_data: PackedVector3Array
# Real Beam data buffer: Array of [rb_x, rb_y, intensity]
var _rb_data: PackedVector3Array

# Debug mesh
var _dbg_mesh: ImmediateMesh
var _dbg_mesh_instance: MeshInstance3D

# Computed beam direction
var _beam_dir: Vector3 = Vector3.FORWARD

var _first_frame: bool = true
var _debug_timer: float = 10.0  # Start high to trigger debug immediately
var _should_debug: bool = false

# --- Chunked processing state ---
var _ray_directions: PackedVector3Array     # Pre-computed ray directions
var _current_ray_index: int = 0             # Current position in ray array
var _scan_in_progress: bool = false         # Is a scan currently in progress?
var _scan_radar_pos: Vector3                # Radar position at scan start
var _scan_vel_dir: Vector3                  # Velocity direction at scan start
var _scan_dist_to_center: float             # Distance to target at scan start
var _total_rays: int = 0                    # Total rays in current scan
var _scan_start_time: float = 0.0           # Time when scan started
var _last_fps: float = 60.0                 # Last measured FPS for auto-adjustment
var _scan_max_range: float = 0.0            # Max ray distance for current scan
var _scan_dbs_velocity: float = 0.0         # DBS velocity locked at scan start
var _scan_beam_width: float = 0.0           # Beam width locked at scan start
var _debug_printed_nodes: Dictionary        # Track nodes already printed this scan

# Reusable ray query object (avoid per-ray allocation)
var _ray_query: PhysicsRayQueryParameters3D

# Pre-computed colormap lookup table (256 entries x 3 bytes RGB)
var _colormap_lut: PackedByteArray

# Pre-built background pixel buffer (avoids clearing each frame)
var _bg_pixels: PackedByteArray

# --- Threading state for parallel rendering ---
var _render_mutex := Mutex.new()
var _render_pending: bool = false
var _task_dbs: int = -1
var _task_rb: int = -1
var _pixels_dbs: PackedByteArray
var _pixels_rb: PackedByteArray

# --- Scan accumulation ring buffers ---
var _accum_dbs: Array[PackedByteArray] = []
var _accum_rb: Array[PackedByteArray] = []
var _task_median: int = -1
var _median_pending: bool = false
var _median_result_dbs: PackedByteArray
var _median_result_rb: PackedByteArray

# --- Target change tracking ---
var _prev_map_center: Vector3 = Vector3.ZERO
var _prev_beam_width: float = 0.0

func _ready() -> void:
	_build_colormap_lut()
	_build_background_pixels()
	_space_state = get_world_3d().direct_space_state
	
	# Create reusable ray query object once
	_ray_query = PhysicsRayQueryParameters3D.new()
	_ray_query.collide_with_areas = false
	_ray_query.collide_with_bodies = true
	_ray_query.hit_back_faces = false  # Skip backface hits - reduces work
	_ray_query.hit_from_inside = false
	
	# Set starting position on circular orbit
	_orbit_angle = 0.0
	_update_orbit_position()
	
	_img = Image.create(image_size, image_size, false, Image.FORMAT_RGB8)
	_img.fill(background_color)
	_tex = ImageTexture.create_from_image(_img)
	
	_img_rb = Image.create(image_size, image_size, false, Image.FORMAT_RGB8)
	_img_rb.fill(background_color)
	_tex_rb = ImageTexture.create_from_image(_img_rb)
	
	_dbs_data = PackedVector3Array()
	_rb_data = PackedVector3Array()
	_ray_directions = PackedVector3Array()
	
	_create_debug()
	call_deferred("_attach_ui")
	call_deferred("_find_chunk_manager")
	
	print("DBS Radar initialized at position: ", global_transform.origin)
	print("Aiming at map_center: ", map_center)
	print("Performance: rays_per_frame = ", rays_per_frame)
	_prev_map_center = map_center
	_prev_beam_width = beam_width_deg

func _find_chunk_manager() -> void:
	"""Find TerrainChunkManager in scene tree for LOD updates."""
	# TerrainChunkManager is created at runtime by ProceduralTerrainSetup.
	# Wait several frames for the deferred setup to complete.
	for _i in range(5):
		await get_tree().process_frame
		var root: Node = get_tree().current_scene
		if root:
			_chunk_manager = _find_node_by_class(root, "TerrainChunkManager")
		if _chunk_manager:
			print("[RADAR] Found TerrainChunkManager for LOD updates")
			_chunk_manager.set_beam_width(beam_width_deg)
			# If terrain already loaded (tiny maps), hide overlay immediately
			if _loading_overlay and _chunk_manager.is_initial_load_done():
				_loading_overlay.visible = false
			return
	# No chunk manager found — hide overlay (nothing to wait for)
	if _loading_overlay:
		_loading_overlay.visible = false
	print("[RADAR] No TerrainChunkManager found (LOD disabled)")

func _find_node_by_class(node: Node, cls: String) -> Node3D:
	if node.get_class() == cls or (node.get_script() and node.get_script().get_global_name() == cls):
		return node
	for child in node.get_children():
		var found := _find_node_by_class(child, cls)
		if found:
			return found
	return null

func _update_orbit_position() -> void:
	# Aircraft orbits around map_center at fixed radius and altitude
	# In Godot: X = right, Y = up, Z = forward/back
	var x: float = map_center.x + orbit_radius * cos(_orbit_angle)
	var z: float = map_center.z + orbit_radius * sin(_orbit_angle)
	var y: float = map_center.y + orbit_altitude
	global_transform.origin = Vector3(x, y, z)

func _get_velocity_direction() -> Vector3:
	# Velocity is tangent to orbit (perpendicular to radial direction)
	if orbit_clockwise:
		return Vector3(-sin(_orbit_angle), 0.0, cos(_orbit_angle))
	else:
		return Vector3(sin(_orbit_angle), 0.0, -cos(_orbit_angle))

func _exit_tree() -> void:
	# Wait for any pending render tasks before cleanup
	if _task_dbs >= 0:
		WorkerThreadPool.wait_for_task_completion(_task_dbs)
	if _task_rb >= 0:
		WorkerThreadPool.wait_for_task_completion(_task_rb)
	if _task_median >= 0:
		WorkerThreadPool.wait_for_task_completion(_task_median)
	if is_instance_valid(_ui_layer):
		_ui_layer.queue_free()

func set_target(new_center: Vector3) -> void:
	"""Change the radar target. Invalidates accumulated scans and repositions."""
	map_center = new_center
	_invalidate_scans()

func _invalidate_scans() -> void:
	"""Clear all accumulated data and abort current scan"""
	# Wait for any in-flight worker tasks to finish before clearing their data
	if _task_dbs >= 0:
		WorkerThreadPool.wait_for_task_completion(_task_dbs)
		_task_dbs = -1
	if _task_rb >= 0:
		WorkerThreadPool.wait_for_task_completion(_task_rb)
		_task_rb = -1
	if _task_median >= 0:
		WorkerThreadPool.wait_for_task_completion(_task_median)
		_task_median = -1
	_render_pending = false
	_median_pending = false
	
	_accum_dbs.clear()
	_accum_rb.clear()
	_dbs_data.clear()
	_rb_data.clear()
	# Abort current scan so next frame starts fresh
	_scan_in_progress = false
	_current_ray_index = 0
	# Clear display immediately
	if _img:
		_img.fill(background_color)
		_tex.update(_img)
	if _img_rb:
		_img_rb.fill(background_color)
		_tex_rb.update(_img_rb)
	_prev_map_center = map_center
	_prev_beam_width = beam_width_deg
	print("[RADAR] Target/beam changed — scans invalidated  center=", map_center, "  beam=", beam_width_deg)

func _process(delta: float) -> void:
	# Wait one frame for physics to be ready
	if _first_frame:
		_first_frame = false
		return
	
	# Detect if map_center or beam width changed (e.g. via inspector or script)
	if map_center != _prev_map_center or beam_width_deg != _prev_beam_width:
		if _chunk_manager:
			if beam_width_deg != _prev_beam_width:
				_chunk_manager.set_beam_width(beam_width_deg)
			# Update focus area to beam footprint
			var dist_to_target: float = global_transform.origin.distance_to(map_center)
			var footprint: float = 2.0 * dist_to_target * tan(deg_to_rad(beam_width_deg * 0.5))
			_chunk_manager.update_focus_area(map_center.x, map_center.z, footprint * 0.5)
		_invalidate_scans()
		_waiting_for_terrain = true
	
	# Update focus area each frame (in case aircraft moves)
	if _chunk_manager and not _waiting_for_terrain:
		var dist_to_target: float = global_transform.origin.distance_to(map_center)
		var footprint: float = 2.0 * dist_to_target * tan(deg_to_rad(beam_width_deg * 0.5))
		_chunk_manager.update_focus_area(map_center.x, map_center.z, footprint * 0.5)
	
	# Check if terrain is ready (clear waiting flag)
	if _waiting_for_terrain and _chunk_manager:
		if _chunk_manager.is_focus_ready():
			_waiting_for_terrain = false
	
	# Hide loading overlay when initial load is done
	if _loading_overlay and _loading_overlay.visible:
		if not _chunk_manager or _chunk_manager.is_initial_load_done():
			_loading_overlay.visible = false
		else:
			var loaded: int = _chunk_manager.get_loaded_chunk_count()
			var pending: int = _chunk_manager.get_pending_chunk_count()
			_loading_label.text = "Loading terrain... %d/%d chunks" % [loaded, loaded + pending]
	
	# Update countdown / progress label
	_update_countdown_label()
	_update_scale_labels()
	_update_lod_label()
	
	# Track FPS for auto-adjustment
	if delta > 0:
		_last_fps = 1.0 / delta
		# Auto-adjust rays_per_frame to maintain target FPS
		if _last_fps < target_fps * 0.9:
			rays_per_frame = maxi(500, int(rays_per_frame * 0.9))
		elif _last_fps > target_fps * 1.1 and rays_per_frame < 20000:
			rays_per_frame = mini(20000, int(rays_per_frame * 1.05))
	
	# Debug timer - only print debug every 2 seconds
	_debug_timer += delta
	if _debug_timer >= 2.0:
		_should_debug = debug_print_stats
		_debug_timer = 0.0
	else:
		_should_debug = false
	
	# Move aircraft along orbit
	if enable_movement:
		var arc_length: float = velocity_mps * delta
		var delta_angle: float = arc_length / orbit_radius
		if orbit_clockwise:
			_orbit_angle += delta_angle
		else:
			_orbit_angle -= delta_angle
		_update_orbit_position()
	
	# Check if parallel render tasks completed - apply results on main thread
	_check_render_completion()
	
	# Process DBS scan in chunks (only if not waiting for render)
	if not _render_pending:
		_process_dbs_scan_chunk()
	
	if debug_draw_beam:
		_draw_debug()

func _start_new_scan() -> void:
	"""Initialize a new scan cycle - locks all parameters for duration of scan"""
	_dbs_data.clear()
	_rb_data.clear()
	_ray_directions.clear()
	_current_ray_index = 0
	_debug_printed_nodes = {}  # Reset debug tracking
	
	# LOCK all scan parameters at start - these won't change during the scan
	# This prevents smearing when aircraft moves during multi-frame scan
	_scan_radar_pos = global_transform.origin
	_scan_vel_dir = _get_velocity_direction().normalized()
	_scan_dbs_velocity = dbs_velocity_mps  # Use DBS velocity, not movement velocity
	_scan_beam_width = beam_width_deg
	
	# Calculate beam direction toward target (locked for this scan)
	var vec_to_target: Vector3 = map_center - _scan_radar_pos
	_scan_dist_to_center = vec_to_target.length()
	
	if _scan_dist_to_center < 0.1:
		_scan_in_progress = false
		return
	
	_beam_dir = vec_to_target.normalized()
	
	# Auto-compute target area from beam footprint: footprint = 2 * dist * tan(beam_width/2)
	if target_area_from_beam:
		target_area_size = 2.0 * _scan_dist_to_center * tan(deg_to_rad(beam_width_deg * 0.5))
	
	# Lock display ranges centered on map_center (coords are now world-relative to map_center)
	var half_area: float = target_area_size * 0.5
	display_range_x = Vector2(-half_area, half_area)
	display_range_y = Vector2(-half_area, half_area)
	auto_fit_range = false
	
	# Pre-generate all ray directions
	var half_beam_rad: float = deg_to_rad(beam_width_deg * 0.5)
	
	# Find two perpendicular axes to the beam direction
	var up_approx: Vector3 = Vector3.UP
	if abs(_beam_dir.dot(up_approx)) > 0.99:
		up_approx = Vector3.RIGHT
	var perp1: Vector3 = _beam_dir.cross(up_approx).normalized()
	var perp2: Vector3 = _beam_dir.cross(perp1).normalized()
	
	# Generate ray directions in a grid by rotating around beam center
	for i in range(azimuth_count):
		var t1: float = float(i) / float(azimuth_count - 1) - 0.5 if azimuth_count > 1 else 0.0
		var angle1: float = t1 * 2.0 * half_beam_rad
		
		for j in range(elevation_count):
			var t2: float = float(j) / float(elevation_count - 1) - 0.5 if elevation_count > 1 else 0.0
			var angle2: float = t2 * 2.0 * half_beam_rad
			
			var ray_dir: Vector3 = _beam_dir.rotated(perp1, angle1).rotated(perp2, angle2).normalized()
			_ray_directions.append(ray_dir)
	
	_total_rays = _ray_directions.size()
	_scan_in_progress = true
	_scan_start_time = Time.get_ticks_msec() / 1000.0
	
	# Configure ray query for this scan
	_scan_max_range = _scan_dist_to_center * 2.0
	_ray_query.from = _scan_radar_pos
	_ray_query.collision_mask = collision_mask

func _process_dbs_scan_chunk() -> void:
	"""Process rays until time budget spent (prevents frame spikes)"""
	
	# Don't start scanning if terrain is still updating
	if _waiting_for_terrain:
		return
	
	# Start a new scan if not in progress
	if not _scan_in_progress:
		_start_new_scan()
		if not _scan_in_progress:
			return
	
	# Time-budget based processing (more consistent than fixed ray count)
	var start_usec: int = Time.get_ticks_usec()
	var budget_usec: int = int(raycast_budget_ms * 1000.0)
	
	# Cache frequently accessed values for speed
	var space_state: PhysicsDirectSpaceState3D = _space_state
	var from_pos: Vector3 = _scan_radar_pos
	var max_range: float = _scan_max_range
	var ray_dirs: PackedVector3Array = _ray_directions
	var total: int = _total_rays
	
	while _current_ray_index < total:
		# Check time budget every ray
		if Time.get_ticks_usec() - start_usec >= budget_usec:
			break
		
		# Reuse query object - just update the endpoint
		_ray_query.to = from_pos + ray_dirs[_current_ray_index] * max_range
		
		var hit: Dictionary = space_state.intersect_ray(_ray_query)
		if not hit.is_empty():
			_process_ray_hit(hit["position"], hit["normal"], hit["collider"])
		
		_current_ray_index += 1
	
	# Check if scan is complete
	if _current_ray_index >= total:
		_finalize_scan()

func _process_ray_hit(hit_point: Vector3, hit_normal: Vector3, collider: Object) -> void:
	"""Process a single ray hit and add to data buffers"""
	# Filter: only keep hits within the target area around map_center
	var half_area: float = target_area_size * 0.5
	if absf(hit_point.x - map_center.x) > half_area or absf(hit_point.z - map_center.z) > half_area:
		return
	
	var rel_pos: Vector3 = hit_point - _scan_radar_pos
	var dist: float = rel_pos.length()
	var view_dir: Vector3 = rel_pos.normalized()
	
	# Incidence angle
	var incidence: float = abs(view_dir.dot(hit_normal.normalized()))
	
	# Get reflectivity properties from collider metadata (or use defaults)
	var rcs_mult: float = 1.0      # Radar Cross Section multiplier
	var is_specular: bool = false  # Specular vs diffuse
	var spec_exp: float = specular_exponent
	var found_meta: bool = false
	var meta_source_name: String = ""
	
	if collider != null and collider is Node:
		var node: Node = collider as Node
		
		# First check directly on collider (RadarMaterial script sets it here)
		if node.has_meta("radar_rcs"):
			rcs_mult = node.get_meta("radar_rcs")
			found_meta = true
			meta_source_name = node.name
		if node.has_meta("radar_specular"):
			is_specular = node.get_meta("radar_specular")
			found_meta = true
			meta_source_name = node.name
		if node.has_meta("radar_specular_exp"):
			spec_exp = node.get_meta("radar_specular_exp")
			found_meta = true
			meta_source_name = node.name
		
		# If not found on collider, check parents (up to 3 levels)
		if not found_meta:
			var parent: Node = node.get_parent()
			for i in range(3):
				if parent == null:
					break
				if parent.has_meta("radar_rcs"):
					rcs_mult = parent.get_meta("radar_rcs")
					found_meta = true
					meta_source_name = parent.name
				if parent.has_meta("radar_specular"):
					is_specular = parent.get_meta("radar_specular")
					found_meta = true
					meta_source_name = parent.name
				if parent.has_meta("radar_specular_exp"):
					spec_exp = parent.get_meta("radar_specular_exp")
					found_meta = true
					meta_source_name = parent.name
				if found_meta:
					break
				parent = parent.get_parent()
		
		# Also check groups for convenience
		if node.is_in_group("radar_specular"):
			is_specular = true
			found_meta = true
		if node.is_in_group("radar_stealth"):
			rcs_mult = 0.1
			found_meta = true
		if node.is_in_group("radar_bright"):
			rcs_mult = 5.0
			found_meta = true
		
		# Debug: print when we detect metadata/groups (once per node per scan)
		if found_meta:
			var node_id: int = node.get_instance_id()
			if not _debug_printed_nodes.has(node_id):
				_debug_printed_nodes[node_id] = true
				print("  [RADAR] '%s' (from '%s') rcs=%.2f spec=%s exp=%.1f" % [node.name, meta_source_name, rcs_mult, is_specular, spec_exp])
	
	if not found_meta:
		# Fallback to height-based detection
		is_specular = hit_point.y > cube_height_threshold
	
	var intensity: float
	if is_specular:
		intensity = pow(incidence, spec_exp) * specular_multiplier
		if hit_normal.y > 0.8:
			intensity = max(intensity, 2.0)
	else:
		intensity = diffuse_base + incidence * diffuse_multiplier
	
	# Apply RCS multiplier
	intensity *= rcs_mult
	
	if enable_speckle:
		intensity *= randf_range(0.5, 1.5)
	
	# Compute angle between view direction and velocity for squint factor
	var cos_theta: float = view_dir.dot(_scan_vel_dir)
	
	# Use TRUE hit position in world coords (stable across scans)
	# Only apply cross-range perturbation from DBS/RB processing
	var true_x: float = hit_point.x - map_center.x
	var true_z: float = hit_point.z - map_center.z
	
	# Cross-range direction: perpendicular to look direction in XZ plane
	var look_xz: Vector3 = Vector3(rel_pos.x, 0.0, rel_pos.z).normalized()
	var cross_dir: Vector3 = look_xz.cross(Vector3.UP).normalized()
	
	# DBS cross-range error from Doppler noise:
	# delta_cr = lambda * R * delta_fd / (2 * V * sin(squint))
	var doppler_noise: float = randfn(0.0, doppler_noise_std)
	var squint_sin: float = maxf(abs(sin(acos(clamp(cos_theta, -1.0, 1.0)))), 0.1)
	var dbs_cross_error: float = wavelength_m * dist * doppler_noise / (2.0 * _scan_dbs_velocity * squint_sin)
	
	var dbs_map_x: float = true_x + cross_dir.x * dbs_cross_error
	var dbs_map_z: float = true_z + cross_dir.z * dbs_cross_error
	
	# Real Beam: large cross-range smearing from beam width
	var beam_noise: float = randfn(0.0, deg_to_rad(_scan_beam_width / 2.0))
	var rb_cross_error: float = dist * beam_noise
	
	var rb_map_x: float = true_x + cross_dir.x * rb_cross_error
	var rb_map_z: float = true_z + cross_dir.z * rb_cross_error
	
	_dbs_data.append(Vector3(dbs_map_x, dbs_map_z, intensity))
	_rb_data.append(Vector3(rb_map_x, rb_map_z, intensity))

func _finalize_scan() -> void:
	"""Finish scan and start parallel render tasks"""
	_scan_in_progress = false
	
	var scan_duration: float = Time.get_ticks_msec() / 1000.0 - _scan_start_time
	
	if _should_debug:
		print("=== SCAN COMPLETE ===")
		print("Total rays: %d, Hits: %d" % [_total_rays, _dbs_data.size()])
		print("Scan duration: %.2f sec, FPS: %.1f, rays_per_frame: %d" % [scan_duration, _last_fps, rays_per_frame])
	
	# Prevent starting new scan until render completes
	_render_pending = true
	
	# Duplicate data so next scan won't mutate it while rendering
	var dbs_copy: PackedVector3Array = _dbs_data.duplicate()
	var rb_copy: PackedVector3Array = _rb_data.duplicate()
	
	# Start parallel render tasks for DBS and RB
	_task_dbs = WorkerThreadPool.add_task(_task_compute_pixels.bind(dbs_copy, true))
	_task_rb = WorkerThreadPool.add_task(_task_compute_pixels.bind(rb_copy, false))

func _check_render_completion() -> void:
	"""Poll render tasks and apply results on main thread when done"""
	# Stage 1: Check if pixel render tasks are done
	if _render_pending and not _median_pending:
		if not WorkerThreadPool.is_task_completed(_task_dbs):
			return
		if not WorkerThreadPool.is_task_completed(_task_rb):
			return
		
		# Both pixel tasks done
		WorkerThreadPool.wait_for_task_completion(_task_dbs)
		WorkerThreadPool.wait_for_task_completion(_task_rb)
		_task_dbs = -1
		_task_rb = -1
		
		# Get rendered pixels
		_render_mutex.lock()
		var px_dbs: PackedByteArray = _pixels_dbs
		var px_rb: PackedByteArray = _pixels_rb
		_render_mutex.unlock()
		
		if accumulate_scans <= 1:
			# No accumulation — apply directly
			_accum_dbs.clear()
			_accum_rb.clear()
			_img.set_data(image_size, image_size, false, Image.FORMAT_RGB8, px_dbs)
			_tex.update(_img)
			_img_rb.set_data(image_size, image_size, false, Image.FORMAT_RGB8, px_rb)
			_tex_rb.update(_img_rb)
			_render_pending = false
		else:
			# Accumulate and offload median to worker thread
			_accum_dbs.append(px_dbs)
			_accum_rb.append(px_rb)
			while _accum_dbs.size() > accumulate_scans:
				_accum_dbs.remove_at(0)
			while _accum_rb.size() > accumulate_scans:
				_accum_rb.remove_at(0)
			
			# Snapshot buffers for the worker (shallow copy of array of refs is fine —
			# we only remove_at(0) old entries, never mutate existing PackedByteArrays)
			var snap_dbs: Array[PackedByteArray] = _accum_dbs.duplicate()
			var snap_rb: Array[PackedByteArray] = _accum_rb.duplicate()
			_median_pending = true
			_task_median = WorkerThreadPool.add_task(_task_compute_median.bind(snap_dbs, snap_rb))
		return
	
	# Stage 2: Check if median task is done
	if _median_pending:
		if not WorkerThreadPool.is_task_completed(_task_median):
			return
		
		WorkerThreadPool.wait_for_task_completion(_task_median)
		_task_median = -1
		_median_pending = false
		
		# Apply median results on main thread
		_render_mutex.lock()
		var final_dbs: PackedByteArray = _median_result_dbs
		var final_rb: PackedByteArray = _median_result_rb
		_render_mutex.unlock()
		
		_img.set_data(image_size, image_size, false, Image.FORMAT_RGB8, final_dbs)
		_tex.update(_img)
		_img_rb.set_data(image_size, image_size, false, Image.FORMAT_RGB8, final_rb)
		_tex_rb.update(_img_rb)
		
		_render_pending = false

func _task_compute_median(bufs_dbs: Array[PackedByteArray], bufs_rb: Array[PackedByteArray]) -> void:
	"""Worker: compute median or average for both DBS and RB buffers"""
	var med_dbs: PackedByteArray
	var med_rb: PackedByteArray
	if accumulate_mode == 1:
		med_dbs = _average_pixels(bufs_dbs)
		med_rb = _average_pixels(bufs_rb)
	else:
		med_dbs = _median_pixels(bufs_dbs)
		med_rb = _median_pixels(bufs_rb)
	_render_mutex.lock()
	_median_result_dbs = med_dbs
	_median_result_rb = med_rb
	_render_mutex.unlock()

func _median_pixels(buffers: Array[PackedByteArray]) -> PackedByteArray:
	"""Compute per-byte median across multiple pixel buffers"""
	var count: int = buffers.size()
	if count == 0:
		return _bg_pixels.duplicate()
	if count == 1:
		return buffers[0]
	
	var pixel_count: int = buffers[0].size()
	var result: PackedByteArray = PackedByteArray()
	result.resize(pixel_count)
	
	# For small counts (typical: 3-7), insertion sort into small array is fastest
	var vals: Array[int] = []
	vals.resize(count)
	
	for i in range(pixel_count):
		# Gather values from all buffers for this byte
		for b in range(count):
			vals[b] = buffers[b][i]
		# Sort (small array, ~5 elements)
		vals.sort()
		# Median: middle element (or lower-middle for even count)
		@warning_ignore("integer_division")
		result[i] = vals[count / 2]
	
	return result

func _average_pixels(buffers: Array[PackedByteArray]) -> PackedByteArray:
	"""Compute per-byte average across multiple pixel buffers"""
	var count: int = buffers.size()
	if count == 0:
		return _bg_pixels.duplicate()
	if count == 1:
		return buffers[0]
	
	var pixel_count: int = buffers[0].size()
	var result: PackedByteArray = PackedByteArray()
	result.resize(pixel_count)
	
	for i in range(pixel_count):
		var total: int = 0
		for b in range(count):
			total += buffers[b][i]
		@warning_ignore("integer_division")
		result[i] = total / count
	
	return result

func _task_compute_pixels(data: PackedVector3Array, is_dbs: bool) -> void:
	"""Worker task: compute pixels only (no Image/Texture - thread safe)"""
	var pixels: PackedByteArray = _compute_pixels_only(data)
	
	_render_mutex.lock()
	if is_dbs:
		_pixels_dbs = pixels
	else:
		_pixels_rb = pixels
	_render_mutex.unlock()

func _build_colormap_lut() -> void:
	"""Pre-compute 256-entry colormap lookup table for fast rendering"""
	_colormap_lut = PackedByteArray()
	_colormap_lut.resize(256 * 3)  # 256 colors x RGB
	
	for i in range(256):
		var t: float = float(i) / 255.0
		var color: Color = _get_colormap_color(t)
		_colormap_lut[i * 3] = int(color.r * 255.0)
		_colormap_lut[i * 3 + 1] = int(color.g * 255.0)
		_colormap_lut[i * 3 + 2] = int(color.b * 255.0)

func _build_background_pixels() -> void:
	"""Pre-build background pixel buffer once (avoid clearing each frame)"""
	_bg_pixels = PackedByteArray()
	_bg_pixels.resize(image_size * image_size * 3)
	var bg_r: int = int(background_color.r * 255.0)
	var bg_g: int = int(background_color.g * 255.0)
	var bg_b: int = int(background_color.b * 255.0)
	for i in range(0, _bg_pixels.size(), 3):
		_bg_pixels[i] = bg_r
		_bg_pixels[i + 1] = bg_g
		_bg_pixels[i + 2] = bg_b

func _compute_pixels_only(data: PackedVector3Array) -> PackedByteArray:
	"""Pure CPU pixel computation - thread safe, no Image/Texture usage"""
	var data_size: int = data.size()
	
	# Start from pre-built background (duplicate for independent writable copy)
	var pixels: PackedByteArray = _bg_pixels.duplicate()
	var row_stride: int = image_size * 3
	var max_coord: int = image_size - 1
	
	if data_size == 0:
		return pixels
	
	# Calculate ranges in single pass
	var x_min: float = display_range_x.x
	var x_max: float = display_range_x.y
	var y_min: float = display_range_y.x
	var y_max: float = display_range_y.y
	var i_min: float = INF
	var i_max: float = -INF
	
	if auto_fit_range:
		x_min = INF
		x_max = -INF
		y_min = INF
		y_max = -INF
		
		for i in range(data_size):
			var point: Vector3 = data[i]
			if point.x < x_min: x_min = point.x
			if point.x > x_max: x_max = point.x
			if point.y < y_min: y_min = point.y
			if point.y > y_max: y_max = point.y
			if point.z < i_min: i_min = point.z
			if point.z > i_max: i_max = point.z
		
		# Add 10% margin
		var x_margin: float = (x_max - x_min) * 0.1
		var y_margin: float = (y_max - y_min) * 0.1
		x_min -= x_margin
		x_max += x_margin
		y_min -= y_margin
		y_max += y_margin
		
		# Ensure minimum range
		if x_max - x_min < 10.0:
			var mid: float = (x_min + x_max) * 0.5
			x_min = mid - 5.0
			x_max = mid + 5.0
		if y_max - y_min < 10.0:
			var mid: float = (y_min + y_max) * 0.5
			y_min = mid - 5.0
			y_max = mid + 5.0
	else:
		for i in range(data_size):
			var z: float = data[i].z
			if z < i_min: i_min = z
			if z > i_max: i_max = z
	
	# Pre-compute scale factors
	var x_range: float = x_max - x_min
	var y_range: float = y_max - y_min
	var i_range: float = maxf(i_max - i_min, 0.001)
	var x_scale: float = float(image_size - 1) / x_range
	var y_scale: float = float(image_size - 1) / y_range
	
	# Uniform scaling: use same pixels-per-meter for both axes, center the smaller one
	var x_offset: float = 0.0
	var y_offset: float = 0.0
	if preserve_aspect_ratio and x_range > 0.001 and y_range > 0.001:
		var uniform_scale: float = minf(x_scale, y_scale)
		x_offset = (float(image_size - 1) - x_range * uniform_scale) * 0.5
		y_offset = (float(image_size - 1) - y_range * uniform_scale) * 0.5
		x_scale = uniform_scale
		y_scale = uniform_scale
	
	var i_scale: float = 255.0 / i_range
	
	# Local copy of LUT for thread safety
	var lut: PackedByteArray = _colormap_lut
	var gamma: float = intensity_gamma
	
	# Render all points using byte array
	for i in range(data_size):
		var point: Vector3 = data[i]
		
		# Map to image coordinates (with uniform offset for aspect ratio)
		var img_x: int = clampi(int(x_offset + (point.x - x_min) * x_scale), 0, max_coord)
		var img_y: int = clampi(max_coord - int(y_offset + (point.y - y_min) * y_scale), 0, max_coord)
		
		# Normalize intensity, apply gamma, and get LUT index
		var norm: float = clampf((point.z - i_min) * i_scale / 255.0, 0.0, 1.0)
		var lut_idx: int = clampi(int(pow(norm, gamma) * 255.0), 0, 255) * 3
		
		# Get RGB from pre-computed LUT
		var r: int = lut[lut_idx]
		var g: int = lut[lut_idx + 1]
		var b: int = lut[lut_idx + 2]
		
		# Draw 2x2 pixel block directly to byte array
		var base_idx: int = img_y * row_stride + img_x * 3
		pixels[base_idx] = r
		pixels[base_idx + 1] = g
		pixels[base_idx + 2] = b
		
		if img_x + 1 <= max_coord:
			pixels[base_idx + 3] = r
			pixels[base_idx + 4] = g
			pixels[base_idx + 5] = b
		
		if img_y + 1 <= max_coord:
			var next_row: int = base_idx + row_stride
			pixels[next_row] = r
			pixels[next_row + 1] = g
			pixels[next_row + 2] = b
			
			if img_x + 1 <= max_coord:
				pixels[next_row + 3] = r
				pixels[next_row + 4] = g
				pixels[next_row + 5] = b
	
	return pixels

func _get_colormap_color(t: float) -> Color:
	match colormap:
		0:  # Inferno (dark -> red -> yellow -> white)
			return _inferno_colormap(t)
		1:  # Green radar style
			return Color(0.0, t, 0.0, 1.0)
		2:  # Grayscale
			return Color(t, t, t, 1.0)
		_:
			return _inferno_colormap(t)

func _inferno_colormap(t: float) -> Color:
	# Approximate inferno colormap (dark purple -> red -> orange -> yellow -> white)
	if t < 0.25:
		# Black to dark purple
		var s: float = t / 0.25
		return Color(s * 0.3, 0.0, s * 0.4, 1.0)
	elif t < 0.5:
		# Dark purple to red
		var s: float = (t - 0.25) / 0.25
		return Color(0.3 + s * 0.5, 0.0, 0.4 - s * 0.4, 1.0)
	elif t < 0.75:
		# Red to orange/yellow
		var s: float = (t - 0.5) / 0.25
		return Color(0.8 + s * 0.2, s * 0.7, 0.0, 1.0)
	else:
		# Yellow to white
		var s: float = (t - 0.75) / 0.25
		return Color(1.0, 0.7 + s * 0.3, s, 1.0)

func _attach_ui() -> void:
	_ui_layer = CanvasLayer.new()
	_ui_layer.layer = 1000

	var root: Node = get_tree().current_scene
	if root == null:
		root = get_tree().root

	if root.is_inside_tree() and root.get_tree() != null:
		root.add_child(_ui_layer)
	else:
		root.call_deferred("add_child", _ui_layer)
	
	# Real Beam (Blurry) - Left side
	var label_rb := Label.new()
	label_rb.text = "Real Beam (Blurry)"
	label_rb.position = ui_anchor_top_left
	label_rb.add_theme_color_override("font_color", Color.WHITE)
	label_rb.add_theme_color_override("font_shadow_color", Color.BLACK)
	label_rb.add_theme_constant_override("shadow_offset_x", 1)
	label_rb.add_theme_constant_override("shadow_offset_y", 1)
	_ui_layer.add_child(label_rb)
	
	_ui_rect_rb = TextureRect.new()
	_ui_rect_rb.texture = _tex_rb
	_ui_rect_rb.custom_minimum_size = ui_size_px
	_ui_rect_rb.size = ui_size_px
	_ui_rect_rb.position = ui_anchor_top_left + Vector2(0, 20)
	_ui_rect_rb.modulate.a = 1.0
	_ui_rect_rb.stretch_mode = TextureRect.STRETCH_SCALE
	_ui_rect_rb.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	_ui_layer.add_child(_ui_rect_rb)
	
	# DBS (Sharpened) - Right side
	var label_dbs := Label.new()
	label_dbs.text = "DBS (Sharpened)"
	label_dbs.position = ui_anchor_top_left + Vector2(ui_size_px.x + 12, 0)
	label_dbs.add_theme_color_override("font_color", Color.WHITE)
	label_dbs.add_theme_color_override("font_shadow_color", Color.BLACK)
	label_dbs.add_theme_constant_override("shadow_offset_x", 1)
	label_dbs.add_theme_constant_override("shadow_offset_y", 1)
	_ui_layer.add_child(label_dbs)
	
	_ui_rect = TextureRect.new()
	_ui_rect.texture = _tex
	_ui_rect.custom_minimum_size = ui_size_px
	_ui_rect.size = ui_size_px
	_ui_rect.position = ui_anchor_top_left + Vector2(ui_size_px.x + 12, 20)
	_ui_rect.modulate.a = 1.0
	_ui_rect.stretch_mode = TextureRect.STRETCH_SCALE
	_ui_rect.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	_ui_layer.add_child(_ui_rect)
	
	# Countdown / progress label — centered over both radar displays
	_countdown_label = Label.new()
	_countdown_label.text = ""
	_countdown_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	# Position centered between the two displays
	var total_width: float = ui_size_px.x * 2 + 12
	_countdown_label.position = ui_anchor_top_left + Vector2(0, ui_size_px.y + 24)
	_countdown_label.size = Vector2(total_width, 24)
	_countdown_label.add_theme_color_override("font_color", Color(0.3, 1.0, 0.3))
	_countdown_label.add_theme_color_override("font_shadow_color", Color.BLACK)
	_countdown_label.add_theme_constant_override("shadow_offset_x", 1)
	_countdown_label.add_theme_constant_override("shadow_offset_y", 1)
	_ui_layer.add_child(_countdown_label)
	
	# Scale labels — bottom-left of each radar display
	_scale_label_rb = Label.new()
	_scale_label_rb.text = ""
	_scale_label_rb.position = ui_anchor_top_left + Vector2(4, ui_size_px.y + 6)
	_scale_label_rb.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8, 0.8))
	_scale_label_rb.add_theme_font_size_override("font_size", 12)
	_ui_layer.add_child(_scale_label_rb)
	
	_scale_label_dbs = Label.new()
	_scale_label_dbs.text = ""
	_scale_label_dbs.position = ui_anchor_top_left + Vector2(ui_size_px.x + 16, ui_size_px.y + 6)
	_scale_label_dbs.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8, 0.8))
	_scale_label_dbs.add_theme_font_size_override("font_size", 12)
	_ui_layer.add_child(_scale_label_dbs)
	
	# LOD resolution label — below countdown
	_lod_label = Label.new()
	_lod_label.text = ""
	_lod_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_lod_label.position = ui_anchor_top_left + Vector2(0, ui_size_px.y + 44)
	_lod_label.size = Vector2(total_width, 20)
	_lod_label.add_theme_color_override("font_color", Color(0.7, 0.85, 1.0, 0.9))
	_lod_label.add_theme_color_override("font_shadow_color", Color.BLACK)
	_lod_label.add_theme_constant_override("shadow_offset_x", 1)
	_lod_label.add_theme_constant_override("shadow_offset_y", 1)
	_lod_label.add_theme_font_size_override("font_size", 12)
	_ui_layer.add_child(_lod_label)
	
	# Loading overlay — fullscreen dark overlay shown during initial terrain load
	_loading_overlay = ColorRect.new()
	_loading_overlay.color = Color(0.05, 0.05, 0.1, 0.85)
	_loading_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_loading_overlay.visible = true   # Start visible; hidden once terrain finishes loading
	_ui_layer.add_child(_loading_overlay)
	
	_loading_label = Label.new()
	_loading_label.text = "Loading terrain..."
	_loading_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_loading_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_loading_label.set_anchors_preset(Control.PRESET_CENTER)
	_loading_label.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_loading_label.grow_vertical = Control.GROW_DIRECTION_BOTH
	_loading_label.size = Vector2(400, 60)
	_loading_label.position = Vector2(-200, -30)
	_loading_label.add_theme_color_override("font_color", Color(0.9, 0.95, 1.0))
	_loading_label.add_theme_font_size_override("font_size", 24)
	_loading_overlay.add_child(_loading_label)

func _update_countdown_label() -> void:
	if not _countdown_label:
		return
	
	# Waiting for terrain chunks to reach target resolution
	if _waiting_for_terrain:
		var pending: int = _chunk_manager.get_pending_chunk_count() if _chunk_manager else 0
		_countdown_label.text = "Waiting for terrain... %d chunks pending" % pending
		_countdown_label.add_theme_color_override("font_color", Color(1.0, 0.7, 0.3))
		return
	else:
		_countdown_label.add_theme_color_override("font_color", Color(0.3, 1.0, 0.3))
	
	if _scan_in_progress and _total_rays > 0:
		var progress: float = float(_current_ray_index) / float(_total_rays)
		var elapsed: float = Time.get_ticks_msec() / 1000.0 - _scan_start_time
		var eta: float = 0.0
		if progress > 0.01:
			eta = elapsed / progress * (1.0 - progress)
		_countdown_label.text = "Scanning... %d%% | ETA %.1fs" % [int(progress * 100.0), eta]
	elif _render_pending or _median_pending:
		_countdown_label.text = "Processing..."
	else:
		_countdown_label.text = "Ready"

func _update_lod_label() -> void:
	if not _lod_label:
		return
	if not _chunk_manager:
		_lod_label.text = "LOD: N/A"
		return
	var res: int = _chunk_manager.get_current_focus_resolution()
	var mps: float = _chunk_manager.get_meters_per_sample()
	var manual_txt: String = " [MANUAL]" if _chunk_manager._manual_resolution > 0 else ""
	_lod_label.text = "LOD: %d×%d  (%.1f m/sample)%s" % [res, res, mps, manual_txt]

func _update_scale_labels() -> void:
	if not _scale_label_rb or not _scale_label_dbs:
		return
	
	# Compute meters per pixel from display range and UI size
	var range_m: float = display_range_x.y - display_range_x.x
	if range_m < 0.01 or ui_size_px.x < 1:
		return
	
	var m_per_px: float = range_m / float(ui_size_px.x)
	
	# Choose a nice round scale bar length
	var bar_m: float = _nice_scale_value(range_m * 0.25)  # ~25% of display width
	var bar_px: int = int(bar_m / m_per_px)
	
	# Build text with a simple ASCII bar
	var bar_str: String = "|"
	@warning_ignore("integer_division")
	var dashes: int = maxi(2, bar_px / 6)  # rough char width
	for _i in range(dashes):
		bar_str += "-"
	bar_str += "| "
	
	if bar_m >= 1000.0:
		bar_str += "%.1f km" % (bar_m / 1000.0)
	else:
		bar_str += "%.0f m" % bar_m
	
	_scale_label_rb.text = bar_str
	_scale_label_dbs.text = bar_str

func _nice_scale_value(approx: float) -> float:
	"""Round to a nice human-readable distance value."""
	var targets: Array[float] = [1, 2, 5, 10, 20, 50, 100, 200, 500, 1000, 2000, 5000, 10000]
	var best: float = targets[0]
	for t in targets:
		if absf(t - approx) < absf(best - approx):
			best = t
	return best

func _create_debug() -> void:
	_dbg_mesh = ImmediateMesh.new()
	_dbg_mesh_instance = MeshInstance3D.new()
	_dbg_mesh_instance.mesh = _dbg_mesh
	_dbg_mesh_instance.top_level = true
	_dbg_mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_dbg_mesh_instance)

func _draw_debug() -> void:
	_dbg_mesh.clear_surfaces()
	_dbg_mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	
	# Use LOCKED scan position during scan, otherwise current position
	var origin: Vector3
	var vel_dir: Vector3
	var beam_width: float
	
	if _scan_in_progress or _render_pending:
		# During scan: draw from locked position
		origin = _scan_radar_pos
		vel_dir = _scan_vel_dir
		beam_width = _scan_beam_width
	else:
		# No scan: draw from current position
		origin = global_transform.origin
		vel_dir = _get_velocity_direction()
		beam_width = beam_width_deg
	
	var to_target: Vector3 = map_center - origin
	var dist_to_center: float = to_target.length()
	
	var beam_center: Vector3 = _beam_dir
	var half_beam_rad: float = deg_to_rad(beam_width * 0.5)
	
	# Find perpendicular axes
	var up_approx: Vector3 = Vector3.UP
	if abs(beam_center.dot(up_approx)) > 0.99:
		up_approx = Vector3.RIGHT
	var perp1: Vector3 = beam_center.cross(up_approx).normalized()
	var perp2: Vector3 = beam_center.cross(perp1).normalized()
	
	# Beam edges
	var beam_left: Vector3 = beam_center.rotated(perp1, -half_beam_rad).normalized()
	var beam_right: Vector3 = beam_center.rotated(perp1, half_beam_rad).normalized()
	var beam_up: Vector3 = beam_center.rotated(perp2, -half_beam_rad).normalized()
	var beam_down: Vector3 = beam_center.rotated(perp2, half_beam_rad).normalized()
	
	var draw_range: float = dist_to_center * 1.2
	
	# Beam edges (green)
	_dbg_mesh.surface_set_color(Color(0.2, 1.0, 0.2, 0.5))
	_dbg_mesh.surface_add_vertex(origin)
	_dbg_mesh.surface_add_vertex(origin + beam_left * draw_range)
	_dbg_mesh.surface_add_vertex(origin)
	_dbg_mesh.surface_add_vertex(origin + beam_right * draw_range)
	_dbg_mesh.surface_add_vertex(origin)
	_dbg_mesh.surface_add_vertex(origin + beam_up * draw_range)
	_dbg_mesh.surface_add_vertex(origin)
	_dbg_mesh.surface_add_vertex(origin + beam_down * draw_range)
	
	# Beam center (yellow)
	_dbg_mesh.surface_set_color(Color(1.0, 1.0, 0.0, 1.0))
	_dbg_mesh.surface_add_vertex(origin)
	_dbg_mesh.surface_add_vertex(origin + beam_center * draw_range)
	
	# Line to map_center (magenta)
	_dbg_mesh.surface_set_color(Color(1.0, 0.0, 1.0, 1.0))
	_dbg_mesh.surface_add_vertex(origin)
	_dbg_mesh.surface_add_vertex(map_center)
	
	# Velocity vector (cyan) - use locked vel_dir during scan
	_dbg_mesh.surface_set_color(Color(0.0, 1.0, 1.0, 1.0))
	_dbg_mesh.surface_add_vertex(origin)
	_dbg_mesh.surface_add_vertex(origin + vel_dir * dbs_velocity_mps * 0.5)
	
	# Also draw current aircraft position if different (white, small)
	if _scan_in_progress or _render_pending:
		var current_pos: Vector3 = global_transform.origin
		_dbg_mesh.surface_set_color(Color(1.0, 1.0, 1.0, 0.5))
		_dbg_mesh.surface_add_vertex(current_pos + Vector3(-2, 0, 0))
		_dbg_mesh.surface_add_vertex(current_pos + Vector3(2, 0, 0))
		_dbg_mesh.surface_add_vertex(current_pos + Vector3(0, -2, 0))
		_dbg_mesh.surface_add_vertex(current_pos + Vector3(0, 2, 0))
		_dbg_mesh.surface_add_vertex(current_pos + Vector3(0, 0, -2))
		_dbg_mesh.surface_add_vertex(current_pos + Vector3(0, 0, 2))
	
	_dbg_mesh.surface_end()
