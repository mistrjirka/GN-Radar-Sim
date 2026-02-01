# Godot 4.x - DBS (Doppler Beam Sharpening) Radar
# Based on working Python implementation
extends Node3D

@export_category("Aircraft Movement")
@export var velocity_mps: float = 200.0              ## Aircraft velocity in m/s (flight direction is +Y)
@export var orbit_radius: float = 300.0              ## Radius of circular orbit around target
@export var orbit_altitude: float = 100.0            ## Constant altitude above map_center.y
@export var enable_movement: bool = false            ## Toggle movement
@export var orbit_clockwise: bool = true             ## Orbit direction

var _orbit_angle: float = 0.0                        ## Current angle in radians

@export_category("Radar Parameters")
@export var wavelength_m: float = 0.03               ## X-band ~3cm wavelength
@export var beam_width_deg: float = 16.0              ## Beam width in both azimuth and elevation

@export_category("Raycasting Resolution")
@export var azimuth_count: int = 500                 ## Number of rays in azimuth
@export var elevation_count: int = 150               ## Number of rays in elevation

@export_category("Map Area")
@export var map_center: Vector3 = Vector3.ZERO       ## Center of target area (where beam aims)

@export_category("Image")
@export var image_size: int = 512                    ## Square image size
@export var background_color: Color = Color(0.0, 0.0, 0.0, 1.0)

@export_category("Display")
@export var display_range_x: Vector2 = Vector2(-250, 250)  ## DBS X display range
@export var display_range_y: Vector2 = Vector2(-250, 250)  ## DBS Y display range
@export var auto_fit_range: bool = true              ## Auto-fit display range to data
@export var colormap: int = 0                        ## 0=Inferno, 1=Green, 2=Grayscale
@export var intensity_gamma: float = 0.5             ## Gamma correction for intensity

@export_category("Noise")
@export var doppler_noise_std: float = 15.0          ## Standard deviation of Doppler noise (Hz)
@export var enable_speckle: bool = true              ## Enable speckle noise

@export_category("Surface Properties")
@export var cube_height_threshold: float = 55.0      ## Height above which is considered "cube" (specular)
@export var specular_exponent: float = 6.0           ## Specular reflection sharpness
@export var specular_multiplier: float = 15.0        ## Specular intensity multiplier
@export var diffuse_base: float = 0.1                ## Base diffuse intensity
@export var diffuse_multiplier: float = 0.5          ## Diffuse intensity multiplier

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

func _ready() -> void:
	_space_state = get_world_3d().direct_space_state
	
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
	
	_create_debug()
	call_deferred("_attach_ui")
	
	print("DBS Radar initialized at position: ", global_transform.origin)
	print("Aiming at map_center: ", map_center)

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
	if is_instance_valid(_ui_layer):
		_ui_layer.queue_free()

func _process(delta: float) -> void:
	# Wait one frame for physics to be ready
	if _first_frame:
		_first_frame = false
		return
	
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
	
	# Perform DBS scan each frame
	_perform_dbs_scan()
	
	if debug_draw_beam:
		_draw_debug()

func _perform_dbs_scan() -> void:
	_dbs_data.clear()
	_rb_data.clear()
	
	var radar_pos: Vector3 = global_transform.origin
	
	# --- AIMING: Calculate beam direction toward target ---
	var vec_to_target: Vector3 = map_center - radar_pos
	var dist_to_center: float = vec_to_target.length()
	
	if dist_to_center < 0.1:
		if _should_debug:
			print("WARNING: Radar too close to target center")
		return
	
	# Calculate azimuth and elevation to target center
	# We'll use the beam direction directly and rotate around it
	_beam_dir = vec_to_target.normalized()
	
	if _should_debug:
		print("=== DBS SCAN DEBUG ===")
		print("Radar pos: ", radar_pos)
		print("Map center: ", map_center)
		print("Vec to target: ", vec_to_target, " dist: ", dist_to_center)
		print("Beam dir: ", _beam_dir)
	
	# --- RAY GENERATION ---
	# Use rotation from beam center instead of spherical coords
	var half_beam_rad: float = deg_to_rad(beam_width_deg * 0.5)
	
	# Find two perpendicular axes to the beam direction
	var up_approx: Vector3 = Vector3.UP
	if abs(_beam_dir.dot(up_approx)) > 0.99:
		up_approx = Vector3.RIGHT
	var perp1: Vector3 = _beam_dir.cross(up_approx).normalized()
	var perp2: Vector3 = _beam_dir.cross(perp1).normalized()
	
	# Generate ray directions in a grid by rotating around beam center
	var ray_origins: PackedVector3Array = PackedVector3Array()
	var ray_directions: PackedVector3Array = PackedVector3Array()
	
	for i in range(azimuth_count):
		var t1: float = float(i) / float(azimuth_count - 1) - 0.5 if azimuth_count > 1 else 0.0
		var angle1: float = t1 * 2.0 * half_beam_rad
		
		for j in range(elevation_count):
			var t2: float = float(j) / float(elevation_count - 1) - 0.5 if elevation_count > 1 else 0.0
			var angle2: float = t2 * 2.0 * half_beam_rad
			
			# Rotate beam direction by small angles around two perpendicular axes
			var ray_dir: Vector3 = _beam_dir.rotated(perp1, angle1).rotated(perp2, angle2).normalized()
			
			ray_origins.append(radar_pos)
			ray_directions.append(ray_dir)
	
	# --- RAYCASTING ---
	var total_hits: int = 0
	var max_intensity: float = 0.0
	
	# Debug: test a single ray straight at map_center first
	if _should_debug:
		var test_ray_end: Vector3 = radar_pos + _beam_dir * (dist_to_center * 2.0)
		var test_query := PhysicsRayQueryParameters3D.create(radar_pos, test_ray_end)
		test_query.collision_mask = collision_mask
		var test_hit: Dictionary = _space_state.intersect_ray(test_query)
		print("Test ray from ", radar_pos, " to ", test_ray_end)
		print("Test ray dir: ", _beam_dir)
		if test_hit.is_empty():
			print("TEST RAY: NO HIT!")
		else:
			print("TEST RAY HIT: ", test_hit.get("position"), " normal: ", test_hit.get("normal"))
		print("Total rays to cast: ", ray_origins.size())
		if ray_origins.size() > 0:
			print("Sample ray dir[0]: ", ray_directions[0])
			print("Sample ray dir[mid]: ", ray_directions[ray_origins.size() / 2])
	
	for ray_idx in range(ray_origins.size()):
		var ray_origin: Vector3 = ray_origins[ray_idx]
		var ray_dir: Vector3 = ray_directions[ray_idx]
		
		var ray_end: Vector3 = ray_origin + ray_dir * (dist_to_center * 2.0)
		var query := PhysicsRayQueryParameters3D.create(ray_origin, ray_end)
		query.collision_mask = collision_mask
		
		var hit: Dictionary = _space_state.intersect_ray(query)
		
		if hit.is_empty():
			continue
		
		var hit_point: Vector3 = hit.get("position", Vector3.ZERO)
		var hit_normal: Vector3 = hit.get("normal", Vector3.UP)
		
		total_hits += 1
		
		# --- GEOMETRY CALCULATIONS ---
		var rel_pos: Vector3 = hit_point - radar_pos
		var dist: float = rel_pos.length()
		var view_dir: Vector3 = rel_pos.normalized()
		
		# Get the actual direction of the aircraft's velocity
		var vel_dir: Vector3 = _get_velocity_direction().normalized()
		
		# --- INTENSITY CALCULATION ---
		# Incidence angle (how perpendicular is the surface?)
		var incidence: float = abs(view_dir.dot(hit_normal.normalized()))
		
		var intensity: float
		
		# Height check: distinguish cube (specular) from terrain (diffuse)
		var is_cube: bool = hit_point.y > cube_height_threshold
		
		if is_cube:
			# CUBE: Specular reflection (shiny)
			intensity = pow(incidence, specular_exponent) * specular_multiplier
			# Boost top face slightly
			if hit_normal.y > 0.8:
				intensity = max(intensity, 2.0)
		else:
			# TERRAIN: Diffuse reflection (rough)
			intensity = diffuse_base + incidence * diffuse_multiplier
		
		# Speckle noise
		if enable_speckle:
			intensity *= randf_range(0.5, 1.5)
		
		if intensity > max_intensity:
			max_intensity = intensity
		
		# --- DBS MATH ---
		# The Cosine of the angle is the Dot Product of view and velocity directions
		var cos_theta: float = view_dir.dot(vel_dir)
		
		# Calculate Doppler frequency
		var doppler: float = (2.0 * velocity_mps * cos_theta) / wavelength_m
		
		# Add Doppler measurement noise
		var fd_meas: float = doppler + randfn(0.0, doppler_noise_std)
		
		# Calculate measured azimuth from Doppler
		# meas_az_dbs = arccos((fd * lambda) / (2 * V))
		var val: float = clamp((fd_meas * wavelength_m) / (2.0 * velocity_mps), -1.0, 1.0)
		var meas_az_dbs: float = acos(val)
		
		# Handle negative azimuth (left/right of velocity vector)
		# Calculate a "Right" vector relative to the aircraft's velocity
		var right_vec: Vector3 = vel_dir.cross(Vector3.UP).normalized()
		
		# Check if the hit point is to the left or right of the aircraft's path
		if rel_pos.dot(right_vec) < 0.0:
			meas_az_dbs = -meas_az_dbs
		
		# DBS coordinates
		var dbs_x: float = dist * sin(meas_az_dbs)
		var dbs_y: float = dist * cos(meas_az_dbs)
		
		# --- REAL BEAM (BLURRY) ---
		# Simulate poor angular resolution by adding noise to the angle
		# Calculate true azimuth relative to velocity vector
		var true_az_vel: float = acos(clamp(cos_theta, -1.0, 1.0))
		if rel_pos.dot(right_vec) < 0.0:
			true_az_vel = -true_az_vel
		
		# Add beam width noise (simulates poor angular resolution)
		var beam_noise: float = randfn(0.0, deg_to_rad(beam_width_deg / 2.0))
		var meas_az_rb: float = true_az_vel + beam_noise
		
		# Real Beam coordinates
		var rb_x: float = dist * sin(meas_az_rb)
		var rb_y: float = dist * cos(meas_az_rb)
		
		# Debug first few hits
		if _should_debug and total_hits <= 3:
			print("Hit #%d: pos=%s, dist=%.1f, cos_theta=%.3f, doppler=%.1f, dbs=(%.1f, %.1f), rb=(%.1f, %.1f)" % [
				total_hits, hit_point, dist, cos_theta, doppler, dbs_x, dbs_y, rb_x, rb_y
			])
		
		# Store: x, y, intensity
		_dbs_data.append(Vector3(dbs_x, dbs_y, intensity))
		_rb_data.append(Vector3(rb_x, rb_y, intensity))
	
	if _should_debug:
		if total_hits > 0:
			print("DBS Scan: %d hits, max intensity=%.2f, dbs_data size=%d" % [total_hits, max_intensity, _dbs_data.size()])
		else:
			print("DBS Scan: 0 hits! Radar at %s, aiming at %s, rays cast=%d" % [radar_pos, map_center, ray_origins.size()])
	
	# Render both images
	_render_dbs_image()
	_render_rb_image()

func _render_dbs_image() -> void:
	_render_image_to(_img, _tex, _dbs_data, "DBS")

func _render_rb_image() -> void:
	_render_image_to(_img_rb, _tex_rb, _rb_data, "RB")

func _render_image_to(img: Image, tex: ImageTexture, data: PackedVector3Array, label: String) -> void:
	img.fill(background_color)
	
	if data.size() == 0:
		if _should_debug:
			print("RENDER %s: No data to render!" % label)
		tex.update(img)
		return
	
	if _should_debug:
		print("RENDER %s: Drawing %d points" % [label, data.size()])
	
	# Determine display range
	var x_min: float = display_range_x.x
	var x_max: float = display_range_x.y
	var y_min: float = display_range_y.x
	var y_max: float = display_range_y.y
	
	if auto_fit_range:
		# Find data extents
		x_min = INF
		x_max = -INF
		y_min = INF
		y_max = -INF
		
		for point in data:
			if point.x < x_min: x_min = point.x
			if point.x > x_max: x_max = point.x
			if point.y < y_min: y_min = point.y
			if point.y > y_max: y_max = point.y
		
		# Add 10% margin
		var x_margin: float = (x_max - x_min) * 0.1
		var y_margin: float = (y_max - y_min) * 0.1
		x_min -= x_margin
		x_max += x_margin
		y_min -= y_margin
		y_max += y_margin
		
		# Ensure minimum range
		if x_max - x_min < 10.0:
			var mid: float = (x_min + x_max) / 2.0
			x_min = mid - 5.0
			x_max = mid + 5.0
		if y_max - y_min < 10.0:
			var mid: float = (y_min + y_max) / 2.0
			y_min = mid - 5.0
			y_max = mid + 5.0
	
	var x_range: float = x_max - x_min
	var y_range: float = y_max - y_min
	
	if _should_debug:
		print("RENDER %s: X range [%.1f, %.1f], Y range [%.1f, %.1f]" % [label, x_min, x_max, y_min, y_max])
	
	# Find intensity range for normalization
	var i_min: float = INF
	var i_max: float = -INF
	for point in data:
		if point.z < i_min: i_min = point.z
		if point.z > i_max: i_max = point.z
	
	var i_range: float = i_max - i_min
	if i_range < 0.001:
		i_range = 1.0
	
	if _should_debug:
		print("RENDER %s: Intensity range [%.3f, %.3f]" % [label, i_min, i_max])
	
	# Sort by intensity so bright pixels draw on top (like Python does)
	var sorted_data: Array = []
	for point in data:
		sorted_data.append(point)
	sorted_data.sort_custom(func(a, b): return a.z < b.z)
	
	var pixels_drawn: int = 0
	
	# Render each point
	for point in sorted_data:
		var dbs_x: float = point.x
		var dbs_y: float = point.y
		var intensity: float = point.z
		
		# Map to image coordinates
		var img_x: int = int((dbs_x - x_min) / x_range * float(image_size - 1))
		var img_y: int = int((dbs_y - y_min) / y_range * float(image_size - 1))
		
		# Flip Y so higher values are at top
		img_y = image_size - 1 - img_y
		
		# Clamp to image bounds
		img_x = clampi(img_x, 0, image_size - 1)
		img_y = clampi(img_y, 0, image_size - 1)
		
		# Normalize intensity and apply gamma
		var norm_intensity: float = (intensity - i_min) / i_range
		norm_intensity = pow(norm_intensity, intensity_gamma)
		norm_intensity = clamp(norm_intensity, 0.0, 1.0)
		
		# Apply colormap
		var color: Color = _get_colormap_color(norm_intensity)
		
		# Set pixel (and neighbors for larger dots)
		_set_pixel_safe(img, img_x, img_y, color)
		_set_pixel_safe(img, img_x + 1, img_y, color)
		_set_pixel_safe(img, img_x, img_y + 1, color)
		_set_pixel_safe(img, img_x + 1, img_y + 1, color)
		pixels_drawn += 1
		
		# Debug first few pixels
		if _should_debug and pixels_drawn <= 3:
			print("Pixel #%d: dbs=(%.1f,%.1f) -> img=(%d,%d), intensity=%.2f, color=%s" % [
				pixels_drawn, dbs_x, dbs_y, img_x, img_y, norm_intensity, color
			])
	
	if _should_debug:
		print("RENDER %s: Drew %d pixels total" % [label, pixels_drawn])
	
	tex.update(img)

func _set_pixel_safe(img: Image, x: int, y: int, color: Color) -> void:
	if x >= 0 and x < image_size and y >= 0 and y < image_size:
		# Blend with existing pixel (take brighter)
		var existing: Color = img.get_pixel(x, y)
		if color.get_luminance() > existing.get_luminance():
			img.set_pixel(x, y, color)

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
	
	var origin: Vector3 = global_transform.origin
	var to_target: Vector3 = map_center - origin
	var dist_to_center: float = to_target.length()
	
	var beam_center: Vector3 = _beam_dir
	var half_beam_rad: float = deg_to_rad(beam_width_deg * 0.5)
	
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
	
	# Velocity vector (cyan)
	var vel_dir: Vector3 = _get_velocity_direction()
	_dbg_mesh.surface_set_color(Color(0.0, 1.0, 1.0, 1.0))
	_dbg_mesh.surface_add_vertex(origin)
	_dbg_mesh.surface_add_vertex(origin + vel_dir * velocity_mps * 0.5)
	
	_dbg_mesh.surface_end()
