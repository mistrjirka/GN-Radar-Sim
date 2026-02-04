# Attach this script to any node (MeshInstance3D, Node3D, etc.)
# It will find ALL CollisionObject3D descendants and set radar metadata on them
# Works with imported meshes that have auto-generated collision
extends Node
class_name RadarMaterial

@export_category("Radar Properties")
@export var radar_rcs: float = 1.0  ## 0.1=stealthy, 1.0=normal, 5.0=bright
@export var radar_specular: bool = true  ## true=metallic/shiny
@export var radar_specular_exp: float = 6.0  ## Specular sharpness

var _applied_to: Array = []

func _ready() -> void:
	# Wait one frame for all children to be ready
	call_deferred("_find_and_apply_to_colliders")

func _find_and_apply_to_colliders() -> void:
	_applied_to.clear()
	_apply_to_descendants(self)
	
	# Also apply to self (in case this IS the collider or has metadata checking)
	set_meta("radar_rcs", radar_rcs)
	set_meta("radar_specular", radar_specular)
	set_meta("radar_specular_exp", radar_specular_exp)
	
	if _applied_to.size() > 0:
		var names: String = ""
		for n in _applied_to:
			if names != "":
				names += ", "
			names += n.name
		print("[RadarMaterial] '%s' applied to %d colliders: %s" % [name, _applied_to.size(), names])
	else:
		print("[RadarMaterial] '%s' - no child colliders found, metadata set on self" % name)

func _apply_to_descendants(node: Node) -> void:
	for child in node.get_children():
		if child is CollisionObject3D:
			_apply_metadata_to(child)
			_applied_to.append(child)
			print("[RadarMaterial] -> Set on '%s' (type: %s)" % [child.name, child.get_class()])
		# Keep searching deeper
		_apply_to_descendants(child)

func _apply_metadata_to(node: Node) -> void:
	node.set_meta("radar_rcs", radar_rcs)
	node.set_meta("radar_specular", radar_specular)
	node.set_meta("radar_specular_exp", radar_specular_exp)
