# Godot 4.x
extends Node3D

@export_category("Radar Geometry")
@export var max_slant_range_m: float = 100.0         ## Maximum radar beam range
@export var azimuth_fov_deg: float = 70.0            ## Horizontal field of view
@export var depression_min_deg: float = 10.0         ## Shallow depression (far range on display)
@export var depression_max_deg: float = 60.0         ## Steep depression (near range on display)
@export var use_aircraft_pitch: bool = true          ## Compensate for aircraft pitch

@export_category("Sampling")
@export var azimuth_bins: int = 512                  ## Samples across azimuth FOV
@export var elevation_bins: int = 512                ## Samples across depression range
@export var samples_per_frame: int = 1024              ## Samples per frame

@export_category("Image")
@export var image_size: int = 512                    ## Square image size
@export var fade_rate: float = 0.0000                  ## How fast old hits fade (per frame)
@export var background_color: Color = Color(0.02, 0.02, 0.02, 1.0)  ## Dark background

@export_category("Return Model")
@export var base_gain: float = 0.6
@export var slope_boost: float = 1.5
@export var noise_floor: float = 0.00
@export var brightness: float = 0.0                  ## Brightness offset (adjust with +/-)
@export var brightness_step: float = 0.00            ## How much +/- changes brightness
@export var auto_contrast_min: float = 0.1           ## Minimum brightness for lowest terrain
@export var auto_contrast_max: float = 1.0           ## Maximum brightness for highest terrain
@export_range(0.0, 1.0) var intensity_blend: float = 0.5  ## 0=height only, 1=intensity only

@export_category("Noise Models (toggle with keys)")
@export var enable_multiplicative_speckle: bool = false  ## Key 1: Exponential/Gamma speckle
@export var speckle_looks: int = 3                       ## Multi-look count (1=max speckle, 6=smooth)
@export var enable_glint: bool = false                   ## Key 2: Heavy-tailed glint spikes
@export var glint_probability: float = 0.005             ## Chance of bright glint per sample
@export var glint_sigma: float = 0.8                     ## Lognormal sigma for glint intensity
@export var enable_additive_noise: bool = false          ## Key 3: Receiver thermal noise
@export var enable_log_compression: bool = true          ## Key 4: Log-scale compression
@export var log_compression_strength: float = 4.0        ## Higher = more compression
@export var enable_specular: bool = false                ## Key 5: Specular reflection term
@export var specular_width: float = 0.15                 ## Width of specular lobe
@export var specular_strength: float = 0.7               ## Specular contribution
@export var enable_range_noise: bool = false             ## Key 6: Range-dependent position jitter
@export var enable_range_brightness: bool = false        ## Key 7: Brightness falloff with range

@export_category("Beam Spread")
@export var beam_width_near_px: float = 1.0          ## Beam width in pixels at near range
@export var beam_width_far_px: float = 6.0           ## Beam width in pixels at far range
@export var range_noise_near_m: float = 0.5          ## Range jitter at near range (meters)
@export var range_noise_far_m: float = 5.0           ## Range jitter at far range (meters)

@export_category("Shadow")
@export var enable_horizon_shadow: bool = true
@export var shadow_attenuation: float = 0.1

@export_category("Physics")
@export var collision_mask: int = 0xFFFFFFFF

@export_category("UI")
@export var ui_size_px: Vector2i = Vector2i(520, 520)
@export var ui_anchor_top_left: Vector2 = Vector2(12, 12)
@export var ui_alpha: float = 0.95

@export_category("Debug")
@export var debug_draw_rays: bool = true
@export var debug_ray_color: Color = Color(0.2, 1.0, 0.2, 1.0)
@export var debug_verify_height: bool = false          ## Verify height with vertical raycast
@export var debug_verify_interval: int = 1000          ## How often to verify (every N samples)

var _space_state: PhysicsDirectSpaceState3D
var _img_front: Image          # Display buffer (shown)
var _img_back: Image           # Render buffer (being drawn to)
var _tex: ImageTexture

var _ui_layer: CanvasLayer
var _ui_rect: TextureRect

# Scanning state: azimuth first (left to right), then elevation
var _current_az_bin: int = 0
var _current_elev_bin: int = 0
var _scan_az_direction: int = 1  # 1 = left to right, -1 = right to left

# Per-azimuth shadow tracking
var _max_elev_per_az: PackedFloat32Array

# Debug mesh
var _dbg_mesh: ImmediateMesh
var _dbg_mesh_instance: MeshInstance3D

# Current scan for debug
var _last_ray_origin: Vector3 = Vector3.ZERO
var _last_ray_end: Vector3 = Vector3.ZERO
var _last_hit_pos: Vector3 = Vector3.ZERO
var _had_hit: bool = false
var _verify_sample_counter: int = 0

# Auto-contrast: track min/max height during scan
var _min_height_this_scan: float = 1e9
var _max_height_this_scan: float = -1e9

# Height buffer for auto-contrast normalization
var _height_buffer: PackedFloat32Array
var _intensity_buffer: PackedFloat32Array
var _count_buffer: PackedInt32Array  # Track samples per pixel for averaging

func _ready() -> void:
	_space_state = get_world_3d().direct_space_state

	# Double buffer: front for display, back for rendering
	_img_front = Image.create(image_size, image_size, false, Image.FORMAT_RGB8)
	_img_front.fill(background_color)
	_img_back = Image.create(image_size, image_size, false, Image.FORMAT_RGB8)
	_img_back.fill(background_color)
	_tex = ImageTexture.create_from_image(_img_front)
	
	# Initialize height buffer for auto-contrast
	var buffer_size: int = image_size * image_size
	_height_buffer.resize(buffer_size)
	_intensity_buffer.resize(buffer_size)
	_count_buffer.resize(buffer_size)
	_clear_height_buffer()
	
	# Initialize per-azimuth shadow tracking
	_max_elev_per_az.resize(azimuth_bins)
	_reset_shadow_tracking()

	_create_debug()
	call_deferred("_attach_ui")

func _clear_height_buffer() -> void:
	for i in range(_height_buffer.size()):
		_height_buffer[i] = 0.0      # Accumulator (will divide by count)
		_intensity_buffer[i] = 0.0
		_count_buffer[i] = 0         # Sample count
	_min_height_this_scan = 1e9
	_max_height_this_scan = -1e9

func _reset_shadow_tracking() -> void:
	for i in range(azimuth_bins):
		_max_elev_per_az[i] = -1e9

func _exit_tree() -> void:
	if is_instance_valid(_ui_layer):
		_ui_layer.queue_free()

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed:
		match event.keycode:
			KEY_EQUAL, KEY_KP_ADD:  # + key
				brightness = clamp(brightness + brightness_step, -0.5, 1.0)
				print("Brightness: %.2f" % brightness)
			KEY_MINUS, KEY_KP_SUBTRACT:  # - key
				brightness = clamp(brightness - brightness_step, -0.5, 1.0)
				print("Brightness: %.2f" % brightness)
			KEY_1:
				enable_multiplicative_speckle = !enable_multiplicative_speckle
				print("Multiplicative speckle: %s" % ("ON" if enable_multiplicative_speckle else "OFF"))
			KEY_2:
				enable_glint = !enable_glint
				print("Glint: %s" % ("ON" if enable_glint else "OFF"))
			KEY_3:
				enable_additive_noise = !enable_additive_noise
				print("Additive noise: %s" % ("ON" if enable_additive_noise else "OFF"))
			KEY_4:
				enable_log_compression = !enable_log_compression
				print("Log compression: %s" % ("ON" if enable_log_compression else "OFF"))
			KEY_5:
				enable_specular = !enable_specular
				print("Specular: %s" % ("ON" if enable_specular else "OFF"))
			KEY_6:
				enable_range_noise = !enable_range_noise
				print("Range noise: %s" % ("ON" if enable_range_noise else "OFF"))
			KEY_7:
				enable_range_brightness = !enable_range_brightness
				print("Range brightness: %s" % ("ON" if enable_range_brightness else "OFF"))

func _process(_delta: float) -> void:
	# Fade all pixels toward background
	_apply_fade()
	
	for _i in range(samples_per_frame):
		_render_radar_sample(_current_az_bin, _current_elev_bin)
		_advance_scan()
	
	# Only update display - front buffer doesn't change until scan complete
	# (texture already shows _img_front)

# Exponential random variable with mean=1 (for single-look speckle)
func _speckle_exp_mean1() -> float:
	var u: float = max(1e-6, randf())
	return -log(u)

# Multi-look speckle: average L exponentials -> Gamma distribution
func _speckle_multilook(L: int) -> float:
	L = max(1, L)
	var s: float = 0.0
	for i in range(L):
		s += _speckle_exp_mean1()
	return s / float(L)  # mean ~ 1

# Heavy-tailed glint multiplier (lognormal spikes)
func _glint_multiplier() -> float:
	if randf() < glint_probability:
		return exp(randfn(0.0, glint_sigma))
	return 1.0

# Verify height by casting vertical ray at the same horizontal position
func _verify_height_at_position(radar_hit_pos: Vector3) -> void:
	# Cast vertical ray from high above down to ground at the hit's XZ position
	var probe_start: Vector3 = Vector3(radar_hit_pos.x, radar_hit_pos.y + 500.0, radar_hit_pos.z)
	var probe_end: Vector3 = Vector3(radar_hit_pos.x, radar_hit_pos.y - 500.0, radar_hit_pos.z)
	
	var q := PhysicsRayQueryParameters3D.create(probe_start, probe_end)
	q.collision_mask = collision_mask
	var hit: Dictionary = _space_state.intersect_ray(q)
	
	if not hit.is_empty():
		var vertical_hit_pos: Vector3 = hit.get("position", Vector3.ZERO) as Vector3
		var height_diff: float = abs(radar_hit_pos.y - vertical_hit_pos.y)
		
		print("Height verify at (%.1f, %.1f): Radar=%.2f, Vertical=%.2f, Diff=%.3f" % [
			radar_hit_pos.x, radar_hit_pos.z,
			radar_hit_pos.y, vertical_hit_pos.y, height_diff
		])
		
		if height_diff > 0.5:
			print("  WARNING: Height mismatch > 0.5m!")
	else:
		print("Height verify: Vertical ray missed at (%.1f, %.1f)" % [radar_hit_pos.x, radar_hit_pos.z])

func _apply_fade() -> void:
	# Fade is applied to back buffer during rendering
	for y in range(image_size):
		for x in range(image_size):
			var c: Color = _img_back.get_pixel(x, y)
			c = c.lerp(background_color, fade_rate)
			_img_back.set_pixel(x, y, c)

	if debug_draw_rays:
		_draw_debug()

func _advance_scan() -> void:
	# Move along azimuth (left-right)
	_current_az_bin += _scan_az_direction
	
	# Check if we've completed this azimuth row
	if _current_az_bin >= azimuth_bins or _current_az_bin < 0:
		_current_az_bin = clampi(_current_az_bin, 0, azimuth_bins - 1)
		# Move to next elevation row (near to far on display)
		_current_elev_bin += 1
		# Reverse azimuth direction for boustrophedon
		_scan_az_direction = -_scan_az_direction
		
		# Check if full scan complete
		if _current_elev_bin >= elevation_bins:
			_current_elev_bin = 0
			_current_az_bin = 0 if _scan_az_direction == 1 else azimuth_bins - 1
			_reset_shadow_tracking()
			# Apply auto-contrast and render final image
			_apply_auto_contrast()
			_clear_height_buffer()

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

	_ui_rect = TextureRect.new()
	_ui_rect.texture = _tex
	_ui_rect.size = ui_size_px
	_ui_rect.position = ui_anchor_top_left
	_ui_rect.modulate.a = ui_alpha
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

func _render_radar_sample(az_bin: int, elev_bin: int) -> void:
	var half_fov_rad: float = deg_to_rad(azimuth_fov_deg * 0.5)
	
	# Calculate azimuth angle: -half_fov (left) to +half_fov (right)
	var az_t: float = (float(az_bin) + 0.5) / float(azimuth_bins)
	var az_rad: float = lerp(-half_fov_rad, half_fov_rad, az_t)
	
	# Calculate depression angle: steep (near) to shallow (far)
	# elev_bin 0 = steep depression = near range on display (bottom)
	# elev_bin max = shallow depression = far range on display (top)
	var elev_t: float = (float(elev_bin) + 0.5) / float(elevation_bins)
	var dep_deg: float = lerp(depression_max_deg, depression_min_deg, elev_t)
	var dep_rad: float = deg_to_rad(dep_deg)
	
	# Get aircraft frame
	var origin: Vector3 = global_transform.origin
	var fwd: Vector3 = global_transform.basis.x.normalized()
	var up: Vector3 = global_transform.basis.y.normalized()
	var right: Vector3 = global_transform.basis.z.normalized()
	
	# Aircraft pitch compensation
	var pitch_offset_rad: float = 0.0
	if use_aircraft_pitch:
		pitch_offset_rad = asin(clamp(fwd.y, -1.0, 1.0))
	
	var effective_dep_rad: float = dep_rad - pitch_offset_rad
	effective_dep_rad = clamp(effective_dep_rad, deg_to_rad(1.0), deg_to_rad(85.0))
	
	# Build ray direction: start with forward, pitch down, then rotate in azimuth
	var ray_dir: Vector3 = fwd.rotated(right, -effective_dep_rad)  # Negative = down
	ray_dir = ray_dir.rotated(up, az_rad).normalized()
	
	# Cast the radar beam
	var ray_end: Vector3 = origin + ray_dir * max_slant_range_m
	
	# Store for debug
	_last_ray_origin = origin
	_last_ray_end = ray_end
	_had_hit = false
	
	var q := PhysicsRayQueryParameters3D.create(origin, ray_end)
	q.collision_mask = collision_mask
	var hit: Dictionary = _space_state.intersect_ray(q)
	
	var intensity: float = 0.0
	var ground_range: float = 0.0
	
	if not hit.is_empty():
		var hit_pos: Vector3 = hit.get("position", Vector3.ZERO) as Vector3
		var hit_nrm: Vector3 = hit.get("normal", Vector3.UP) as Vector3
		var slant_range: float = origin.distance_to(hit_pos)
		
		_last_hit_pos = hit_pos
		_had_hit = true
		
		# Calculate ground range (horizontal distance) from hit position
		ground_range = Vector2(hit_pos.x - origin.x, hit_pos.z - origin.z).length()
		
		# LOS vector from hit point back to radar
		var los: Vector3 = (origin - hit_pos).normalized()
		var n: Vector3 = hit_nrm.normalized()
		
		# Backscatter depends on incidence angle
		var ci: float = clamp(los.dot(n), 0.0, 1.0)  # cos(incidence)
		var diffuse: float = pow(ci, 0.6) * slope_boost
		
		# Specular term (narrow lobe near normal incidence)
		var spec: float = 0.0
		if enable_specular:
			spec = exp(-pow((1.0 - ci) / specular_width, 2.0)) * specular_strength
		
		var angle_term: float = diffuse + spec
		
		# Horizon shadow tracking (based on elevation angle to hit point)
		if enable_horizon_shadow:
			var elev_to_hit: float = atan2(hit_pos.y - origin.y, max(ground_range, 1.0))
			
			if elev_to_hit > _max_elev_per_az[az_bin]:
				_max_elev_per_az[az_bin] = elev_to_hit
			else:
				angle_term *= shadow_attenuation
		
		# Range normalization
		var range_factor: float = 1.0
		if enable_range_brightness:
			range_factor = 1.0 - (slant_range / max_slant_range_m)
			range_factor = clamp(range_factor, 0.0, 1.0)
			intensity = base_gain * angle_term * (0.3 + 0.7 * range_factor)
		else:
			intensity = base_gain * angle_term
		
		# Multiplicative speckle (exponential/Gamma model)
		if enable_multiplicative_speckle:
			var S: float = _speckle_multilook(speckle_looks)
			intensity *= S
		
		# Heavy-tailed glint (occasional bright spikes)
		if enable_glint:
			intensity *= _glint_multiplier()
		
		# Map hit to image pixel based on (azimuth, ground_range)
		# Use horizontal forward for plan view calculation
		var fwd_horiz: Vector3 = Vector3(fwd.x, 0, fwd.z).normalized()
		if fwd_horiz.length() < 0.001:
			fwd_horiz = Vector3(1, 0, 0)
		
		# Calculate the azimuth angle of the hit point relative to aircraft heading
		var to_hit_horiz: Vector3 = Vector3(hit_pos.x - origin.x, 0, hit_pos.z - origin.z)
		if to_hit_horiz.length() > 0.001:
			to_hit_horiz = to_hit_horiz.normalized()
			var hit_az: float = atan2(
				fwd_horiz.cross(to_hit_horiz).dot(Vector3.UP),
				fwd_horiz.dot(to_hit_horiz)
			)
			
			# Map to image coordinates
			# X: azimuth from -fov/2 to +fov/2 -> 0 to image_size
			var norm_x: float = (hit_az + half_fov_rad) / (2.0 * half_fov_rad)
			# Y: ground range scaled by max expected ground range
			var max_ground_range: float = max_slant_range_m * cos(deg_to_rad(depression_min_deg))
			var norm_y: float = ground_range / max_ground_range
			
			# Scale X by Y to create sector shape
			norm_x = 0.5 + (norm_x - 0.5) * norm_y * 2.0
			
			# Add range-dependent noise to ground_range for display
			var range_t_for_noise: float = clamp(norm_y, 0.0, 1.0)
			var noisy_norm_y: float = norm_y
			var noisy_norm_x: float = norm_x
			
			if enable_range_noise:
				var range_noise_m: float = lerp(range_noise_near_m, range_noise_far_m, range_t_for_noise)
				var noisy_ground_range: float = ground_range + (randf() * 2.0 - 1.0) * range_noise_m
				noisy_norm_y = noisy_ground_range / max_ground_range
				# Recalculate X with noisy Y for sector shape
				noisy_norm_x = 0.5 + (norm_x - 0.5) * max(noisy_norm_y, 0.01) * 2.0
			
			var px_x: int = clampi(int(noisy_norm_x * float(image_size)), 0, image_size - 1)
			var px_y: int = clampi(int(noisy_norm_y * float(image_size)), 0, image_size - 1)
			
			# Calculate beam width based on range
			var beam_width: float = lerp(beam_width_near_px, beam_width_far_px, range_t_for_noise)
			var half_beam: int = int(beam_width * 0.5)
			
			# Additive receiver noise floor
			if enable_additive_noise:
				intensity += noise_floor * (0.7 + 0.6 * randf())
			
			# Store height and intensity in buffer for auto-contrast (accumulate for averaging)
			var buf_idx: int = px_y * image_size + px_x
			if buf_idx >= 0 and buf_idx < _height_buffer.size():
				_height_buffer[buf_idx] += hit_pos.y
				_intensity_buffer[buf_idx] += intensity
				_count_buffer[buf_idx] += 1
				# Track min/max height
				if hit_pos.y < _min_height_this_scan:
					_min_height_this_scan = hit_pos.y
				if hit_pos.y > _max_height_this_scan:
					_max_height_this_scan = hit_pos.y
				
				# Verify height with vertical raycast
				if debug_verify_height:
					_verify_sample_counter += 1
					if _verify_sample_counter >= debug_verify_interval:
						_verify_sample_counter = 0
						_verify_height_at_position(hit_pos)
			
			# Immediate preview (will be replaced by auto-contrast at end of scan)
			var preview_v: float = clamp(intensity, 0.0, 1.0)
			
			# Draw beam footprint (multiple pixels for wider beam)
			for dx in range(-half_beam, half_beam + 1):
				for dy in range(-half_beam, half_beam + 1):
					# Circular falloff within beam
					var dist_sq: float = float(dx * dx + dy * dy)
					var max_dist_sq: float = beam_width * beam_width * 0.25
					if dist_sq <= max_dist_sq:
						var falloff: float = 1.0 - (dist_sq / max(max_dist_sq, 1.0)) * 0.5
						var final_v: float = preview_v * falloff
						var px_bx: int = clampi(px_x + dx, 0, image_size - 1)
						var px_by: int = clampi(image_size - 1 - px_y + dy, 0, image_size - 1)
						# Blend with existing (take max for brighter)
						var existing: Color = _img_back.get_pixel(px_bx, px_by)
						var new_g: float = max(existing.g, final_v)
						_img_back.set_pixel(px_bx, px_by, Color(0.0, new_g, 0.0, 1.0))

func _apply_auto_contrast() -> void:
	# Fill back buffer based on height-normalized values
	_img_back.fill(background_color)
	
	var height_range: float = _max_height_this_scan - _min_height_this_scan
	if height_range < 0.01:
		height_range = 1.0  # Avoid division by zero
	
	# Print height range for debugging
	print("Height range: %.2f to %.2f (delta: %.2f)" % [_min_height_this_scan, _max_height_this_scan, height_range])
	
	for y in range(image_size):
		for x in range(image_size):
			var buf_idx: int = y * image_size + x
			var count: int = _count_buffer[buf_idx]
			
			if count > 0:  # Valid pixel with samples
				# Average the accumulated values
				var h: float = _height_buffer[buf_idx] / float(count)
				var intensity: float = _intensity_buffer[buf_idx] / float(count)
				
				# Normalize height to 0-1
				var h_norm: float = (h - _min_height_this_scan) / height_range
				
				# Map height to auto-contrast range
				var height_contrib: float = lerp(auto_contrast_min, auto_contrast_max, h_norm)
				
				# Blend height-based brightness with intensity (which includes noise)
				# Height provides base contrast, intensity adds noise effects
				var v: float = height_contrib * (1.0 - intensity_blend) + intensity * intensity_blend
				
				# Apply brightness offset
				v += brightness
				
				# Log compression if enabled
				if enable_log_compression:
					v = log(1.0 + log_compression_strength * v) / log(1.0 + log_compression_strength)
				
				v = clamp(v, 0.0, 1.0)
				
				_img_back.set_pixel(x, image_size - 1 - y, Color(0.0, v, 0.0, 1.0))
	
	# Swap buffers: back becomes front (displayed)
	var temp: Image = _img_front
	_img_front = _img_back
	_img_back = temp
	
	# Update texture with newly completed frame
	_tex.update(_img_front)

func _draw_debug() -> void:
	_dbg_mesh.clear_surfaces()
	_dbg_mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	
	var origin: Vector3 = global_transform.origin
	var fwd: Vector3 = global_transform.basis.x.normalized()
	
	# Use horizontal forward for sector visualization
	var fwd_horiz: Vector3 = fwd
	if use_aircraft_pitch:
		fwd_horiz = Vector3(fwd.x, 0, fwd.z)
		if fwd_horiz.length() > 0.001:
			fwd_horiz = fwd_horiz.normalized()
		else:
			fwd_horiz = Vector3(1, 0, 0)
	
	var half_fov_rad: float = deg_to_rad(azimuth_fov_deg * 0.5)
	var max_ground_range: float = max_slant_range_m * cos(deg_to_rad(depression_min_deg))
	
	# Draw sector edges (dimmer)
	var left_dir: Vector3 = fwd_horiz.rotated(Vector3.UP, -half_fov_rad)
	var right_dir: Vector3 = fwd_horiz.rotated(Vector3.UP, half_fov_rad)
	
	_dbg_mesh.surface_set_color(debug_ray_color * 0.3)
	_dbg_mesh.surface_add_vertex(origin)
	_dbg_mesh.surface_add_vertex(origin + left_dir * max_ground_range)
	_dbg_mesh.surface_add_vertex(origin)
	_dbg_mesh.surface_add_vertex(origin + right_dir * max_ground_range)
	
	# Draw the radar ray being cast (yellow)
	if _last_ray_origin != Vector3.ZERO:
		_dbg_mesh.surface_set_color(Color(1.0, 1.0, 0.0, 1.0))  # Yellow
		_dbg_mesh.surface_add_vertex(_last_ray_origin)
		_dbg_mesh.surface_add_vertex(_last_ray_end)
	
	# Draw ray from radar to hit point (green, if we hit terrain)
	if _had_hit:
		_dbg_mesh.surface_set_color(debug_ray_color)
		_dbg_mesh.surface_add_vertex(_last_ray_origin)
		_dbg_mesh.surface_add_vertex(_last_hit_pos)
	
	_dbg_mesh.surface_end()
