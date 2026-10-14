extends RefCounted
## Abstract game projectile: travel to one player-entered coordinate.
## No seeker, emitter tracking, interception or real weapon guidance simulation.
var active := false
var destination: Array = []
var launch_position: Array = []
var remaining := 0.0
var duration := 0.0
var source_scan := -1
var speed := 450.0
var maximum_range := 16000.0
var impact_radius := 120.0

func launch(from: Array, to: Array, scan_id: int) -> bool:
	if active or from.size()!=2 or to.size()!=2 or scan_id<0:return false
	for value in from+to:
		if not is_finite(float(value)):return false
	var distance := Vector2(float(to[0])-float(from[0]),float(to[1])-float(from[1])).length()
	if distance<600 or distance>maximum_range:return false
	launch_position=from.duplicate();destination=to.duplicate();source_scan=scan_id
	duration=maxf(1.0,distance/speed);remaining=duration;active=true
	return true

func advance(dt: float) -> bool:
	if not active or dt<=0:return false
	remaining=maxf(0,remaining-dt)
	if remaining>0:return false
	active=false
	return true

func position_at_present() -> Array:
	if destination.is_empty():return []
	var f := 1.0-remaining/maxf(duration,.001)
	return [lerpf(float(launch_position[0]),float(destination[0]),f),lerpf(float(launch_position[1]),float(destination[1]),f)]
