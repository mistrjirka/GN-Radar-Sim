extends RefCounted
## Shared fictional instrument envelope. Test the ENTIRE square, not its center.
static var limits: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://game/cockpit/scan_limits.json"))

static func inhibit_reason(position: Array, heading: float, center: Array, extent: float) -> String:
	if position.size() < 2 or center.size() != 2 or not is_finite(heading) or not is_finite(extent) or extent < 400.0 or extent > 4000.0:
		return "INVALID AREA"
	for value in position + center:
		if not is_finite(float(value)):return "INVALID POSITION"
	var f := Vector2(sin(heading), cos(heading))
	var right := Vector2(f.y, -f.x)
	var tangent := tan(deg_to_rad(float(limits["half_angle_degrees"])))
	# Subtract double global coordinates before converting small deltas to Vector2.
	var delta := Vector2(float(center[0])-float(position[0]), float(center[1])-float(position[1]))
	for x in [-1, 1]:
		for y in [-1, 1]:
			var corner:Vector2 = delta + (right*x+f*y)*extent*.5
			var ahead:float = corner.dot(f)
			if ahead < float(limits["minimum_forward_m"]):return "AREA TOO CLOSE / BEHIND"
			if absf(corner.dot(right)) > ahead*tangent:return "TURN TOWARD AREA"
			if corner.length() > float(limits["maximum_ground_range_m"]):return "AREA OUT OF RANGE"
	return ""

static func screen_to_sample(uv: Vector2) -> Vector2:
	# Must match the CRT barrel mapping; a click chooses the displayed pixel.
	var p := uv*2.0-Vector2.ONE
	return p*(1.0+.021*p.length_squared())*.5+Vector2.ONE*.5

static func sample_to_world(uv: Vector2, frame: Dictionary) -> Array:
	if not frame.has("global_center") or not frame.has("extent") or not Rect2(0,0,1,1).has_point(uv):return []
	var c: Array = frame["global_center"]
	var width: float = frame["extent"]
	var h:float=frame.get("heading",0.0)
	var x:float=(uv.x-.5)*width
	var y:float=(.5-uv.y)*width
	return [float(c[0])+x*cos(h)+y*sin(h),float(c[1])-x*sin(h)+y*cos(h)]
