extends RefCounted
## Player-authored navigation only. This component knows no enemy positions.
## Points are crossed in order; a swept segment prevents skipping at low FPS.
const MAX_WAYPOINTS := 8
var points: Array[Vector2] = []
var reached_count := 0


func replace(point: Vector2) -> void:
	points.assign([point])


func append(point: Vector2) -> bool:
	if not point.is_finite() or points.size() >= MAX_WAYPOINTS:
		return false
	if not points.is_empty() and points[-1].distance_to(point) < 5.0:
		return false
	points.append(point)
	return true


func undo() -> bool:
	if points.is_empty():
		return false
	points.pop_back()
	return true


func clear() -> void:
	points.clear()


func active_point() -> Vector2:
	return points[0] if not points.is_empty() else Vector2.INF


func desired_heading(position: Vector2, fallback: float) -> float:
	if points.is_empty():
		return fallback
	var delta := points[0] - position
	return atan2(delta.x, delta.y)


func advance(previous: Vector2, current: Vector2, capture_radius: float) -> int:
	var crossed := 0
	# At most one travelled segment is consumed. Distant later waypoints cannot
	# be completed by a teleport in tests or by merely changing a course command.
	while not points.is_empty():
		var nearest := Geometry2D.get_closest_point_to_segment(points[0], previous, current)
		if nearest.distance_to(points[0]) > capture_radius:
			break
		previous = nearest
		points.pop_front()
		crossed += 1
	reached_count += crossed
	return crossed


func remaining_distance(position: Vector2) -> float:
	var total := 0.0
	for point in points:
		total += position.distance_to(point)
		position = point
	return total
