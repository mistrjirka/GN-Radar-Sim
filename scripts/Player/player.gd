extends CharacterBody3D

# Настройки движения
const FORWARD_SPEED =20.0
const MOUSE_SENSITIVITY = 0.005 # Настройте эту величину для чувствительности

# Диапазоны вращения по оси X (вверх/вниз)
const PITCH_LIMIT_UP = deg_to_rad(-89)
const PITCH_LIMIT_DOWN = deg_to_rad(89)

# Переменные для отслеживания вращения
var pitch: float = 0.0
var yaw: float = 0.0

@onready var camera_pivot: Node3D = $CameraPivot # Предполагаем, что у вас есть Node3D для вращения по Y
@onready var camera: Camera3D = $CameraPivot/Camera3D

# Reference to the radar node (will be found at runtime)
var radar_node: Node3D = null

func _ready():
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	# Find the radar node in the scene (the Node3D with DBS script)
	call_deferred("_find_radar_node")

func _find_radar_node():
	# Look for a node with the 'map_center' property (the DBS radar)
	var root = get_tree().current_scene
	radar_node = _find_node_with_property(root, "map_center")
	if radar_node:
		print("Radar node found: ", radar_node.name)
	else:
		print("WARNING: Could not find radar node with 'map_center' property")

func _find_node_with_property(node: Node, property_name: String) -> Node:
	if node.get(property_name) != null:
		return node
	for child in node.get_children():
		var result = _find_node_with_property(child, property_name)
		if result:
			return result
	return null

func _input(event):
	if event is InputEventMouseMotion:
		yaw -= event.relative.x * MOUSE_SENSITIVITY
		pitch -= event.relative.y * MOUSE_SENSITIVITY
		
		pitch = clamp(pitch, PITCH_LIMIT_UP, PITCH_LIMIT_DOWN)
	
	# Handle click to aim radar
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			_aim_radar_at_click(event.position)
		# Scroll wheel to change beam width
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
			_adjust_radar_beam_width(1.0)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
			_adjust_radar_beam_width(-1.0)

func _aim_radar_at_click(screen_pos: Vector2):
	if not camera or not radar_node:
		return
	
	# Get ray from camera through click position
	var ray_origin = camera.project_ray_origin(screen_pos)
	var ray_direction = camera.project_ray_normal(screen_pos)
	var ray_end = ray_origin + ray_direction * 1000.0
	
	# Cast the ray
	var space_state = get_world_3d().direct_space_state
	var query = PhysicsRayQueryParameters3D.create(ray_origin, ray_end)
	var result = space_state.intersect_ray(query)
	
	if not result.is_empty():
		var hit_pos = result.get("position", Vector3.ZERO)
		# Update radar's map_center to aim at the clicked location
		radar_node.map_center = hit_pos
		print("Radar now aiming at: ", hit_pos)

func _adjust_radar_beam_width(delta: float):
	if not radar_node:
		return
	
	# Adjust beam width by delta degrees
	var current_width = radar_node.beam_width_deg
	var new_width = clamp(current_width + delta, 2.0, 60.0)
	radar_node.beam_width_deg = new_width
	print("Beam width: %.1f°" % new_width)

var mouse_mode_captured : bool = true

func _unhandled_input(event):
	if event.is_action_pressed("ui_cancel"): # Например, по нажатию ESC
		mouse_mode_captured = !mouse_mode_captured


func _physics_process(delta: float) -> void:
	if mouse_mode_captured:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	else:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	
	camera_pivot.rotation.x = lerp_angle(camera_pivot.rotation.x , pitch, delta*10.0)
	rotation.y = lerp_angle(rotation.y , yaw, delta*10.0)
	
	
	var input_dir := Input.get_vector("left", "right", "forward", "backward")
	
	var forward_vector = camera_pivot.global_transform.basis.z.normalized()
	var right_vector = camera_pivot.global_transform.basis.x.normalized()

	var desired_velocity = (right_vector * input_dir.x + forward_vector * input_dir.y) * FORWARD_SPEED
	
	velocity = desired_velocity
	
	move_and_slide()
