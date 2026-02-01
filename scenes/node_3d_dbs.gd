# Godot 4.x - DBS (Doppler Beam Sharpening) Radar
extends Node3D

@export_category("Aircraft Movement")
@export var velocity_mps: float = 50.0               ## Aircraft velocity in m/s
@export var orbit_radius: float = 100.0              ## Radius of circular orbit around target (closer = better DBS)
@export var orbit_altitude: float = 80.0             ## Constant altitude above map_center.y
@export var enable_movement: bool = true             ## Toggle movement
@export var orbit_clockwise: bool = true             ## Orbit direction

var _orbit_angle: float = 0.0                        ## Current angle in radians

@export_category("Radar Parameters")
@export var wavelength_m: float = 0.03               ## X-band ~3cm wavelength
@export var prf_hz: float = 5000.0                   ## Pulse Repetition Frequency
@export var pulses_per_cpi: int = 128                ## Pulses per CPI (more = finer Doppler resolution)
@export var range_bins: int = 128                    ## Number of range bins
@export var max_range_m: float = 500.0               ## Maximum slant range (auto-calculated if 0)
@export var beam_width_deg: float = 20.0             ## Real antenna beam width (wider = more cross-range)
@export var auto_aim_at_map_center: bool = true      ## Dynamically aim beam at map_center

@export_category("Map Area")
@export var map_size_m: float = 80.0                 ## Map 80x80m area
@export var map_center: Vector3 = Vector3.ZERO       ## Center of mapped area

@export_category("Image")
@export var image_size: int = 512                    ## Square image size (higher = better resolution)
@export var background_color: Color = Color(0.02, 0.02, 0.02, 1.0)

@export_category("Return Model")
@export var base_gain: float = 0.8
@export var diffuse_exponent: float = 0.5            ## Lower = more diffuse (0.3-1.5)

@export_category("Noise/Display")
@export var enable_speckle: bool = false             ## Multiplicative speckle (disable for debug)
@export var speckle_looks: int = 4                   ## Multi-look averaging
@export var enable_log_compression: bool = true
@export var log_compression_strength: float = 3.0
@export var auto_contrast_min: float = 0.05
@export var auto_contrast_max: float = 1.0

@export_category("Physics")
@export var collision_mask: int = 0xFFFFFFFF

@export_category("UI")
@export var ui_size_px: Vector2i = Vector2i(400, 400)
@export var ui_anchor_top_left: Vector2 = Vector2(12, 12)
@export var ui_alpha: float = 0.95

@export_category("Debug")
@export var debug_draw_beam: bool = true
@export var debug_print_doppler: bool = true
@export var debug_print_scatterers: bool = true
@export var debug_print_pulse: bool = true
@export var debug_print_geometry: bool = true        ## Print DBS geometry info

var _space_state: PhysicsDirectSpaceState3D
var _img: Image
var _tex: ImageTexture
var _ui_layer: CanvasLayer
var _ui_rect: TextureRect

# DBS processing state
var _current_pulse: int = 0

# Complex I/Q buffers: [range_bin][pulse] -> complex (stored as Vector2: x=I, y=Q)
var _iq_buffer: Array[PackedVector2Array]  # [range_bin] -> array of (I,Q) per pulse

# Scatterer cache: for each range bin, store hit positions and amplitudes
# This simulates what the radar "sees" during the dwell
var _scatterer_cache: Array[Array]  # [range_bin] -> Array of {pos: Vector3, amp: float, normal: Vector3}

# Output: after FFT, we have [range_bin][doppler_bin] -> magnitude
var _range_doppler_map: PackedFloat32Array

# Occupied range bin extents (for image scaling)
var _min_occupied_range_bin: int = 0
var _max_occupied_range_bin: int = 0

# Debug mesh
var _dbg_mesh: ImmediateMesh
var _dbg_mesh_instance: MeshInstance3D

# Timing
var _dwell_start_pos: Vector3
var _time_since_dwell_start: float = 0.0
var _cpi_complete: bool = false

# Computed beam direction (towards map_center)
var _beam_dir: Vector3 = Vector3.FORWARD
var _beam_azimuth_rad: float = 0.0
var _beam_depression_rad: float = 0.0

func _ready() -> void:
	_space_state = get_world_3d().direct_space_state
	
	# Set starting position on circular orbit (side-looking geometry maintained)
	_orbit_angle = 0.0
	_update_orbit_position()
	
	_img = Image.create(image_size, image_size, false, Image.FORMAT_RGB8)
	_img.fill(background_color)
	_tex = ImageTexture.create_from_image(_img)
	
	_init_dbs_buffers()
	_create_debug()
	call_deferred("_attach_ui")
	
	# Initialize dwell
	_start_new_dwell()

func _update_orbit_position() -> void:
	# Aircraft orbits around map_center at fixed radius and altitude
	# This maintains perfect 90° squint angle for DBS
	var x: float = map_center.x + orbit_radius * cos(_orbit_angle)
	var z: float = map_center.z + orbit_radius * sin(_orbit_angle)
	var y: float = map_center.y + orbit_altitude
	global_transform.origin = Vector3(x, y, z)

func _get_velocity_direction() -> Vector3:
	# Velocity is tangent to orbit (perpendicular to radial direction)
	# For clockwise orbit, tangent = (-sin(angle), 0, cos(angle))
	# For counter-clockwise, tangent = (sin(angle), 0, -cos(angle))
	if orbit_clockwise:
		return Vector3(-sin(_orbit_angle), 0.0, cos(_orbit_angle))
	else:
		return Vector3(sin(_orbit_angle), 0.0, -cos(_orbit_angle))

func _init_dbs_buffers() -> void:
	# Initialize I/Q buffer: one array per range bin
	_iq_buffer.resize(range_bins)
	for r in range(range_bins):
		_iq_buffer[r] = PackedVector2Array()
		_iq_buffer[r].resize(pulses_per_cpi)
		for p in range(pulses_per_cpi):
			_iq_buffer[r][p] = Vector2.ZERO
	
	# Scatterer cache
	_scatterer_cache.resize(range_bins)
	for r in range(range_bins):
		_scatterer_cache[r] = []
	
	# Range-Doppler map: range_bins x pulses_per_cpi (Doppler bins = number of pulses)
	_range_doppler_map.resize(range_bins * pulses_per_cpi)
	for i in range(_range_doppler_map.size()):
		_range_doppler_map[i] = 0.0

func _start_new_dwell() -> void:
	_dwell_start_pos = global_transform.origin
	_current_pulse = 0
	_time_since_dwell_start = 0.0
	_cpi_complete = false
	
	# Clear I/Q buffer
	for r in range(range_bins):
		for p in range(pulses_per_cpi):
			_iq_buffer[r][p] = Vector2.ZERO
	
	# Probe the scene once at dwell start to find all scatterers
	_probe_scatterers()

func _compute_beam_direction() -> void:
	# Calculate direction from aircraft to map_center
	var origin: Vector3 = global_transform.origin
	var to_target: Vector3 = map_center - origin
	
	# Horizontal direction (XZ plane)
	var to_target_horiz: Vector3 = Vector3(to_target.x, 0, to_target.z)
	var horiz_dist: float = to_target_horiz.length()
	
	if horiz_dist < 0.1:
		# Directly above target - DBS won't work well here
		_beam_dir = Vector3.DOWN
		_beam_azimuth_rad = 0.0
		_beam_depression_rad = PI / 2.0
		if debug_print_geometry:
			print("WARNING: Directly above target - no Doppler separation possible!")
		return
	
	# Azimuth: angle from +X axis in XZ plane
	_beam_azimuth_rad = atan2(to_target.z, to_target.x)
	
	# Depression: angle below horizontal
	_beam_depression_rad = atan2(-to_target.y, horiz_dist)
	
	# Normalized beam direction
	_beam_dir = to_target.normalized()
	
	# Check DBS geometry: angle between velocity and look direction
	var vel_dir: Vector3 = _get_velocity_direction()
	var squint_angle_rad: float = acos(clamp(_beam_dir.dot(vel_dir), -1.0, 1.0))
	var squint_angle_deg: float = rad_to_deg(squint_angle_rad)
	
	# For good DBS, squint should be near 90° (side-looking)
	# Doppler spread is proportional to sin(squint_angle)
	var doppler_factor: float = sin(squint_angle_rad)
	
	if debug_print_geometry:
		var slant_to_target: float = to_target.length()
		
		# Calculate expected Doppler spread for cross-range
		# Angular extent of map area from aircraft position
		var half_swath: float = map_size_m * 0.5
		var angular_extent_rad: float = 2.0 * atan(half_swath / slant_to_target)
		var angular_extent_deg: float = rad_to_deg(angular_extent_rad)
		
		# Max Doppler shift for edge of swath (scatterer at angle from broadside)
		# f_d = 2 * V * sin(angular_offset) / lambda
		var max_doppler_spread_hz: float = 2.0 * velocity_mps * sin(angular_extent_rad * 0.5) / wavelength_m
		var doppler_bins_expected: float = (2.0 * max_doppler_spread_hz) / (prf_hz / float(pulses_per_cpi))
		
		print("DBS Geometry: slant=%.1fm, squint=%.1f° (ideal=90°), doppler_factor=%.2f" % [
			slant_to_target, squint_angle_deg, doppler_factor
		])
		print("  Map angular extent: %.1f° (beam=%.1f°)" % [angular_extent_deg, beam_width_deg])
		print("  Expected Doppler spread: ±%.0f Hz, ~%.0f Doppler bins" % [max_doppler_spread_hz, doppler_bins_expected])
		if doppler_factor < 0.3:
			print("  WARNING: Low squint angle - poor Doppler separation!")
		if doppler_bins_expected < 5:
			print("  WARNING: Low Doppler spread - image may appear as thin line. Move closer or increase map_size.")
	
	if debug_print_scatterers:
		var slant_to_target: float = to_target.length()
		print("Beam aim: to_target=%s, slant=%.1fm, az=%.1f°, dep=%.1f°" % [
			to_target, slant_to_target,
			rad_to_deg(_beam_azimuth_rad), rad_to_deg(_beam_depression_rad)
		])

func _probe_scatterers() -> void:
	# Clear cache
	for r in range(range_bins):
		_scatterer_cache[r].clear()
	
	var origin: Vector3 = global_transform.origin
	
	# Compute beam direction to aim at map_center
	if auto_aim_at_map_center:
		_compute_beam_direction()
	
	# Get the beam center direction
	var beam_center_dir: Vector3 = _beam_dir
	
	# Calculate slant range to map center for range scaling
	var slant_to_center: float = origin.distance_to(map_center)
	var effective_max_range: float = max_range_m
	if slant_to_center > max_range_m * 0.5:
		# Auto-extend range to reach target area
		effective_max_range = slant_to_center * 1.5
	
	var half_beam_rad: float = deg_to_rad(beam_width_deg * 0.5)
	
	if debug_print_scatterers:
		print("Probe: origin=%s, beam_dir=%s, eff_range=%.1fm" % [origin, beam_center_dir, effective_max_range])
	
	# We need to rotate around the beam axis to spread the beam
	# Find two perpendicular axes to the beam direction
	var up_approx: Vector3 = Vector3.UP
	if abs(beam_center_dir.dot(up_approx)) > 0.99:
		up_approx = Vector3.RIGHT
	
	var perp1: Vector3 = beam_center_dir.cross(up_approx).normalized()
	var perp2: Vector3 = beam_center_dir.cross(perp1).normalized()
	
	# Sample many rays within the beam cone
	var samples_per_axis: int = 64  # 64x64 = 4096 samples for dense coverage
	var total_hits: int = 0
	
	# Track occupied range bins
	var local_min_bin: int = range_bins
	var local_max_bin: int = 0
	
	for i in range(samples_per_axis):
		for j in range(samples_per_axis):
			# Offset angles within beam width
			var t1: float = float(i) / float(samples_per_axis - 1) - 0.5
			var t2: float = float(j) / float(samples_per_axis - 1) - 0.5
			var angle1: float = t1 * 2.0 * half_beam_rad
			var angle2: float = t2 * 2.0 * half_beam_rad
			
			# Rotate beam direction
			var ray_dir: Vector3 = beam_center_dir.rotated(perp1, angle1).rotated(perp2, angle2).normalized()
			
			# Cast ray
			var ray_end: Vector3 = origin + ray_dir * effective_max_range
			var q := PhysicsRayQueryParameters3D.create(origin, ray_end)
			q.collision_mask = collision_mask
			var hit: Dictionary = _space_state.intersect_ray(q)
			
			if not hit.is_empty():
				var hit_pos: Vector3 = hit.get("position", Vector3.ZERO) as Vector3
				var hit_normal: Vector3 = hit.get("normal", Vector3.UP) as Vector3
				var slant_range: float = origin.distance_to(hit_pos)
				
				# Determine range bin (use effective range)
				var range_bin: int = int((slant_range / effective_max_range) * float(range_bins))
				range_bin = clampi(range_bin, 0, range_bins - 1)
				
				# Compute backscatter amplitude (diffuse model)
				var los: Vector3 = (origin - hit_pos).normalized()
				var ci: float = clamp(los.dot(hit_normal.normalized()), 0.0, 1.0)
				var amp: float = base_gain * pow(ci, diffuse_exponent)
				
				# Add speckle
				if enable_speckle:
					amp *= _speckle_multilook(speckle_looks)
				
				# Store scatterer
				_scatterer_cache[range_bin].append({
					"pos": hit_pos,
					"amp": amp,
					"normal": hit_normal
				})
				total_hits += 1
				
				# Track range bin extents
				if range_bin < local_min_bin:
					local_min_bin = range_bin
				if range_bin > local_max_bin:
					local_max_bin = range_bin
	
	# Update global range bin extents
	if total_hits > 0:
		_min_occupied_range_bin = local_min_bin
		_max_occupied_range_bin = local_max_bin
	else:
		_min_occupied_range_bin = 0
		_max_occupied_range_bin = range_bins - 1
	
	if debug_print_scatterers:
		var filled_bins: int = 0
		var total_scatterers: int = 0
		var min_range: float = 1e9
		var max_range_found: float = 0.0
		for r in range(range_bins):
			var count: int = _scatterer_cache[r].size()
			if count > 0:
				filled_bins += 1
				total_scatterers += count
				# Check first scatterer range
				var scat_pos: Vector3 = _scatterer_cache[r][0]["pos"]
				var scat_range: float = origin.distance_to(scat_pos)
				if scat_range < min_range:
					min_range = scat_range
				if scat_range > max_range_found:
					max_range_found = scat_range
		print("  Total hits: %d, filled range bins: %d/%d" % [total_hits, filled_bins, range_bins])
		if total_scatterers > 0:
			print("  Scatterer range: %.1f - %.1f m" % [min_range, max_range_found])
			# Print a few sample scatterer positions
			var samples_printed: int = 0
			for r in range(range_bins):
				if _scatterer_cache[r].size() > 0 and samples_printed < 3:
					var s: Dictionary = _scatterer_cache[r][0]
					var spos: Vector3 = s["pos"]
					# Calculate Doppler for this scatterer
					var los: Vector3 = (spos - origin).normalized()
					var cos_angle: float = _get_velocity_direction().dot(los)
					var fd: float = 2.0 * velocity_mps * cos_angle / wavelength_m
					print("  Sample scatterer[%d]: pos=%s, amp=%.3f, fd=%.1f Hz" % [r, spos, s["amp"], fd])
					samples_printed += 1

func _speckle_multilook(L: int) -> float:
	L = max(1, L)
	var s: float = 0.0
	for i in range(L):
		var u: float = max(1e-6, randf())
		s += -log(u)
	return s / float(L)

func _exit_tree() -> void:
	if is_instance_valid(_ui_layer):
		_ui_layer.queue_free()

func _process(_delta: float) -> void:
	# Process entire CPI in one frame (DBS is fast - typically 10-20ms)
	# This ensures proper coherent integration timing
	
	if not _cpi_complete:
		# Process ALL pulses for this CPI at proper timing
		var cpi_duration: float = float(pulses_per_cpi) / prf_hz
		var pulse_interval: float = 1.0 / prf_hz
		
		# Get current velocity direction (tangent to orbit)
		var vel_dir: Vector3 = _get_velocity_direction()
		var vel_vec: Vector3 = vel_dir * velocity_mps
		
		# Starting position for this CPI
		var start_pos: Vector3 = global_transform.origin
		
		for pulse_idx in range(pulses_per_cpi):
			# Calculate aircraft position at this pulse time
			var pulse_time: float = float(pulse_idx) * pulse_interval
			var pos_at_pulse: Vector3 = start_pos + vel_vec * pulse_time
			
			_process_pulse_at_position(pulse_idx, pos_at_pulse, vel_dir)
		
		# Move aircraft along orbit by updating angle
		if enable_movement:
			# arc_length = velocity * time, angle = arc_length / radius
			var arc_length: float = velocity_mps * cpi_duration
			var delta_angle: float = arc_length / orbit_radius
			if orbit_clockwise:
				_orbit_angle += delta_angle
			else:
				_orbit_angle -= delta_angle
			_update_orbit_position()
		
		_cpi_complete = true
		_process_doppler_fft()
		_render_image()
		_start_new_dwell()
	
	if debug_draw_beam:
		_draw_debug()

func _process_pulse() -> void:
	# Legacy - now use _process_pulse_at_position
	_process_pulse_at_position(_current_pulse, global_transform.origin, _get_velocity_direction())

func _process_pulse_at_position(pulse_idx: int, aircraft_pos: Vector3, vel_dir: Vector3) -> void:
	# For each range bin, compute the coherent return from all scatterers
	var max_iq_mag: float = 0.0
	var max_doppler_hz: float = 0.0
	
	for r_bin in range(range_bins):
		var iq_sum: Vector2 = Vector2.ZERO
		
		for scatterer in _scatterer_cache[r_bin]:
			var scat_pos: Vector3 = scatterer["pos"]
			var amp: float = scatterer["amp"]
			
			# Current slant range from aircraft position at this pulse
			var slant_range: float = aircraft_pos.distance_to(scat_pos)
			
			# Line of sight direction
			var los: Vector3 = (scat_pos - aircraft_pos).normalized()
			
			# Doppler frequency: fd = 2 * V * cos(angle) / lambda
			# where angle is between velocity and LOS
			var cos_angle: float = vel_dir.dot(los)
			var doppler_hz: float = 2.0 * velocity_mps * cos_angle / wavelength_m
			
			if abs(doppler_hz) > max_doppler_hz:
				max_doppler_hz = abs(doppler_hz)
			
			# Phase = -4*pi*R / lambda (two-way path)
			# This is the core of coherent integration - phase evolves with range
			var phase: float = -4.0 * PI * slant_range / wavelength_m
			
			# Complex return: amplitude * exp(j*phase)
			var iq: Vector2 = Vector2(cos(phase), sin(phase)) * amp
			iq_sum += iq
		
		_iq_buffer[r_bin][pulse_idx] = iq_sum
		if iq_sum.length() > max_iq_mag:
			max_iq_mag = iq_sum.length()
	
	if debug_print_pulse and pulse_idx == 0:
		var cpi_duration: float = float(pulses_per_cpi) / prf_hz
		var aircraft_motion: float = velocity_mps * cpi_duration
		print("Pulse 0: max IQ=%.4f, max Doppler=%.1f Hz, CPI=%.3fs, motion=%.3fm" % [
			max_iq_mag, max_doppler_hz, cpi_duration, aircraft_motion
		])

func _process_doppler_fft() -> void:
	# For each range bin, perform FFT on the slow-time (pulse) dimension
	# This gives us the Doppler spectrum
	
	for r_bin in range(range_bins):
		# Get the slow-time samples for this range bin
		var samples: PackedVector2Array = _iq_buffer[r_bin]
		
		# Perform FFT (we'll use a simple DFT for now - could optimize)
		var N: int = pulses_per_cpi
		var spectrum: PackedVector2Array = _compute_fft(samples)
		
		# Store magnitudes in range-Doppler map
		# FFT shift: move zero-Doppler to center
		for k in range(N):
			@warning_ignore("integer_division")
			var k_shifted: int = (k + N / 2) % N
			var mag: float = spectrum[k].length()
			_range_doppler_map[r_bin * N + k_shifted] = mag

# Simple radix-2 FFT (Cooley-Tukey)
func _compute_fft(samples: PackedVector2Array) -> PackedVector2Array:
	var N: int = samples.size()
	
	# Pad to power of 2 if needed
	var N2: int = 1
	while N2 < N:
		N2 *= 2
	
	var x: PackedVector2Array = PackedVector2Array()
	x.resize(N2)
	for i in range(N2):
		if i < N:
			x[i] = samples[i]
		else:
			x[i] = Vector2.ZERO
	
	# Bit-reversal permutation
	var j: int = 0
	for i in range(N2):
		if i < j:
			var temp: Vector2 = x[i]
			x[i] = x[j]
			x[j] = temp
		@warning_ignore("integer_division")
		var m: int = N2 / 2
		while m >= 1 and j >= m:
			j -= m
			m /= 2
		j += m
	
	# Cooley-Tukey FFT
	var mmax: int = 1
	while mmax < N2:
		var istep: int = mmax * 2
		var theta: float = -PI / float(mmax)
		var wpr: float = cos(theta)
		var wpi: float = sin(theta)
		var wr: float = 1.0
		var wi: float = 0.0
		
		for m in range(mmax):
			for i in range(m, N2, istep):
				var j2: int = i + mmax
				var t_real: float = wr * x[j2].x - wi * x[j2].y
				var t_imag: float = wr * x[j2].y + wi * x[j2].x
				x[j2] = Vector2(x[i].x - t_real, x[i].y - t_imag)
				x[i] = Vector2(x[i].x + t_real, x[i].y + t_imag)
			var temp_wr: float = wr
			wr = wr * wpr - wi * wpi
			wi = wi * wpr + temp_wr * wpi
		
		mmax = istep
	
	return x

func _render_image() -> void:
	_img.fill(background_color)
	
	var N_doppler: int = pulses_per_cpi
	
	# Find min/max for auto-contrast (skip zero values)
	var min_val: float = 1e9
	var max_val: float = -1e9
	var non_zero_count: int = 0
	for i in range(_range_doppler_map.size()):
		var v: float = _range_doppler_map[i]
		if v > 1e-10:
			non_zero_count += 1
			if v < min_val:
				min_val = v
			if v > max_val:
				max_val = v
	
	if max_val <= min_val or non_zero_count == 0:
		if debug_print_doppler:
			print("Range-Doppler: NO VALID DATA (non_zero=%d)" % non_zero_count)
		return
	
	var val_range: float = max_val - min_val
	
	# Calculate DBS parameters for diagnostics
	var cpi_duration: float = float(pulses_per_cpi) / prf_hz
	var doppler_resolution: float = prf_hz / float(pulses_per_cpi)  # Hz per bin
	# Max unambiguous Doppler = PRF/2
	var max_doppler: float = prf_hz / 2.0
	# Cross-range resolution at center of beam (approximate)
	var slant_to_center: float = global_transform.origin.distance_to(map_center)
	var cross_range_res: float = wavelength_m * slant_to_center / (2.0 * velocity_mps * cpi_duration)
	
	# Find occupied Doppler bin extents
	var min_occupied_doppler: int = N_doppler
	var max_occupied_doppler: int = 0
	for r_bin in range(_min_occupied_range_bin, _max_occupied_range_bin + 1):
		for d_bin in range(N_doppler):
			if _range_doppler_map[r_bin * N_doppler + d_bin] > 1e-10:
				if d_bin < min_occupied_doppler:
					min_occupied_doppler = d_bin
				if d_bin > max_occupied_doppler:
					max_occupied_doppler = d_bin
	
	# Ensure valid extents
	if min_occupied_doppler >= max_occupied_doppler:
		min_occupied_doppler = 0
		max_occupied_doppler = N_doppler - 1
	
	# Add margin to Doppler extent (10% on each side)
	var doppler_extent: int = max_occupied_doppler - min_occupied_doppler
	@warning_ignore("integer_division")
	var doppler_margin: int = maxi(1, doppler_extent / 10)
	min_occupied_doppler = maxi(0, min_occupied_doppler - doppler_margin)
	max_occupied_doppler = mini(N_doppler - 1, max_occupied_doppler + doppler_margin)
	
	var range_extent: int = _max_occupied_range_bin - _min_occupied_range_bin
	if range_extent < 1:
		range_extent = 1
	
	if debug_print_doppler:
		print("Range-Doppler: min=%.4f max=%.4f, non_zero=%d" % [min_val, max_val, non_zero_count])
		print("  Doppler res=%.1f Hz, max_fd=%.1f Hz, cross-range res=%.2fm" % [
			doppler_resolution, max_doppler, cross_range_res
		])
		print("  Range bins: %d-%d (%d total), Doppler bins: %d-%d" % [
			_min_occupied_range_bin, _max_occupied_range_bin, range_extent + 1,
			min_occupied_doppler, max_occupied_doppler
		])
	
	# Map each (range_bin, doppler_bin) to image coordinates
	# Now we map only the OCCUPIED portion to fill the full image
	
	for r_bin in range(_min_occupied_range_bin, _max_occupied_range_bin + 1):
		for d_bin in range(min_occupied_doppler, max_occupied_doppler + 1):
			var mag: float = _range_doppler_map[r_bin * N_doppler + d_bin]
			if mag <= 1e-10:
				continue
			
			# Normalize and apply auto-contrast
			var v: float = (mag - min_val) / val_range
			v = lerp(auto_contrast_min, auto_contrast_max, v)
			
			# Log compression
			if enable_log_compression:
				v = log(1.0 + log_compression_strength * v) / log(1.0 + log_compression_strength)
			
			v = clamp(v, 0.0, 1.0)
			
			# Map occupied range bins to full image height
			var range_t: float = float(r_bin - _min_occupied_range_bin) / float(range_extent)
			var img_y: int = int(range_t * float(image_size - 1))
			img_y = clampi(image_size - 1 - img_y, 0, image_size - 1)  # Flip so far = top
			
			# Map occupied Doppler bins to full image width
			var doppler_extent_f: float = float(max_occupied_doppler - min_occupied_doppler)
			if doppler_extent_f < 1.0:
				doppler_extent_f = 1.0
			var doppler_t: float = float(d_bin - min_occupied_doppler) / doppler_extent_f
			var img_x: int = int(doppler_t * float(image_size - 1))
			img_x = clampi(img_x, 0, image_size - 1)
			
			_img.set_pixel(img_x, img_y, Color(0.0, v, 0.0, 1.0))
	
	_tex.update(_img)

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

	# Add dark background panel behind the radar display
	var bg_panel: ColorRect = ColorRect.new()
	bg_panel.color = Color(0.0, 0.0, 0.0, 1.0)
	bg_panel.size = Vector2(ui_size_px.x + 8, ui_size_px.y + 8)
	bg_panel.position = ui_anchor_top_left - Vector2(4, 4)
	_ui_layer.add_child(bg_panel)
	
	_ui_rect = TextureRect.new()
	_ui_rect.texture = _tex
	_ui_rect.size = ui_size_px
	_ui_rect.position = ui_anchor_top_left
	_ui_rect.modulate.a = 1.0  # Fully opaque
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
	
	# Update beam direction
	if auto_aim_at_map_center:
		_compute_beam_direction()
	
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
	
	var slant_to_center: float = origin.distance_to(map_center)
	var draw_range: float = max(max_range_m, slant_to_center * 1.2)
	
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
	
	# Velocity vector (cyan) - show actual velocity direction
	var vel_dir: Vector3 = _get_velocity_direction()
	_dbg_mesh.surface_set_color(Color(0.0, 1.0, 1.0, 1.0))
	_dbg_mesh.surface_add_vertex(origin)
	_dbg_mesh.surface_add_vertex(origin + vel_dir * velocity_mps * 0.5)
	
	# Map area outline (white) - at ground level (Y=0)
	var half_map: float = map_size_m * 0.5
	var map_y: float = map_center.y
	_dbg_mesh.surface_set_color(Color(1.0, 1.0, 1.0, 0.8))
	_dbg_mesh.surface_add_vertex(Vector3(map_center.x - half_map, map_y, map_center.z - half_map))
	_dbg_mesh.surface_add_vertex(Vector3(map_center.x + half_map, map_y, map_center.z - half_map))
	_dbg_mesh.surface_add_vertex(Vector3(map_center.x + half_map, map_y, map_center.z - half_map))
	_dbg_mesh.surface_add_vertex(Vector3(map_center.x + half_map, map_y, map_center.z + half_map))
	_dbg_mesh.surface_add_vertex(Vector3(map_center.x + half_map, map_y, map_center.z + half_map))
	_dbg_mesh.surface_add_vertex(Vector3(map_center.x - half_map, map_y, map_center.z + half_map))
	_dbg_mesh.surface_add_vertex(Vector3(map_center.x - half_map, map_y, map_center.z + half_map))
	_dbg_mesh.surface_add_vertex(Vector3(map_center.x - half_map, map_y, map_center.z - half_map))
	
	_dbg_mesh.surface_end()
