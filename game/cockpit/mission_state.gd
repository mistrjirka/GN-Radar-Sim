extends RefCounted
## Game rules only: no scene nodes, input events, file paths or radar rendering.
## Radar/RWR views receive filtered data; tests may drive this state headlessly.
const Tuning = preload("res://game/cockpit/mission_tuning.gd")
const Route = preload("res://game/cockpit/navigation_route.gd")
signal radio(text: String, cue: String)
signal event(kind: String)
signal origin_shifted(offset:Vector2)
const ScanGeometry = preload("res://game/cockpit/scan_geometry.gd")
const CoordinateWeapon = preload("res://game/cockpit/coordinate_weapon.gd")
var coordinate_weapon = CoordinateWeapon.new()
var designated_point: Array = []
var designation_scan := -1
var coordinate_impacts: Array = []
var last_coordinate_outcome := ""
var heading_control=preload("res://game/cockpit/heading_control.gd").new()
var origin_east:float=0.0
var origin_north:float=0.0
var endless:=false
var silenced:Dictionary={}
var origin_shift_count:=0

var tuning = Tuning.new()
var route = Route.new()
var seed_value := 42
var position := Vector2(0, -1870)
var heading := 0.0
var commanded_heading := 0.0
var altitude := 1250.0
var commanded_altitude := 1250.0
var speed := 62.0
var target := Vector2(565, 235)
var egress := Vector2(850, -1500)
var emitters: Array = []
var suspected: Array = []
var elapsed := 0.0
var active := false
var authorized := false
var payload_released := false
var finished := false
var survived := false
var integrity := 1.0
var fuel := 1.0
var arm_count := 2
var countermeasures := 4
var armed := false
var selected_emitter := -1
var tracking := 0.0
var incoming := false
var evade_time := 0.0
var missile_time := -1.0
var missile_emitter := -1
var scan_transmit_time := 0.0
var last_warning := -100.0
var hits := 0
var distance_flown := 0.0
var scans_completed := 0
var failure_reason := ""
var journal: Array[Dictionary] = []
var flight_bounds := Rect2(-4200,-4200,8400,8400)
var suggested_routes: Dictionary={}
var region_scenario := "reference"
var approach_announced := false
var zone_announced := false


func setup(data: Dictionary) -> void:
	# Reusing a state for restart must never retain stores, old threats or timers.
	seed_value = int(data.get("seed", 42))
	region_scenario=str(data.get("scenario","reference"))
	endless=region_scenario=="endless"
	origin_east=0.0;origin_north=0.0;origin_shift_count=0;silenced.clear();heading_control.reset()
	coordinate_weapon=CoordinateWeapon.new();designated_point.clear();designation_scan=-1
	coordinate_impacts.clear();last_coordinate_outcome=""
	var b:Array=data.get("bounds",[-tuning.flight_boundary,tuning.flight_boundary,-tuning.flight_boundary,tuning.flight_boundary])
	# The old test map starts outside its image; retain its original flight area.
	flight_bounds=Rect2(Vector2(b[0],b[2]),Vector2(b[1]-b[0],b[3]-b[2])) if region_scenario=="sortie" else Rect2(-tuning.flight_boundary,-tuning.flight_boundary,2*tuning.flight_boundary,2*tuning.flight_boundary)
	suggested_routes=data.get("suggested_routes",{}).duplicate(true)
	position = Vector2(data["start"][0], data["start"][1])
	target = Vector2(data["target"][0], data["target"][1])
	egress = Vector2(data["egress"][0], data["egress"][1])
	emitters = data["emitters"].duplicate(true)
	suspected = data["suspected"].duplicate(true)
	route = Route.new()
	route.replace(target)
	commanded_heading = atan2(target.x - position.x, target.y - position.y)
	heading = commanded_heading
	if endless:
		route.clear();commanded_heading=float(data.get("heading",0));heading=commanded_heading
	altitude = 1250.0
	commanded_altitude = altitude
	speed = tuning.cruise_speed
	elapsed = 0.0
	active = false
	authorized = false
	payload_released = false
	finished = false
	survived = false
	integrity = 1.0
	fuel = 1.0
	arm_count = tuning.initial_arm_count
	countermeasures = tuning.initial_countermeasures
	armed = false
	selected_emitter = -1
	tracking = 0.0
	incoming = false
	evade_time = 0.0
	missile_time = -1.0
	missile_emitter = -1
	scan_transmit_time = 0.0
	last_warning = -100.0
	hits = 0
	distance_flown = 0.0
	scans_completed = 0
	failure_reason = ""
	journal.clear()
	approach_announced=false
	zone_announced=false


func phase_name() -> String:
	if finished:
		return "EGRESS COMPLETE" if survived else "MISSION LOST"
	if not active:
		return "AWAIT ORDERS"
	return "OPEN FLIGHT" if endless else ("EGRESS" if payload_released else "INGRESS / ZULU")


func _announce(text: String, cue: String) -> void:
	journal.append({"seconds": elapsed, "text": text})
	if journal.size() > 80:
		journal.pop_front()
	radio.emit(text, cue)


func begin() -> void:
	if active or finished:
		return
	active = true
	if endless:
		authorized=false
		_announce("PILOT / Open flight. Set a heading on the paper; I will turn onto it. No mission boundary or fuel timer.","click")
		event.emit("authorized")
		return
	authorized = true
	_announce(
		"GROUND / RAVEN TWO. Execute the predesignated mission. Chart target ZULU. Release authority confirmed.",
		"orders"
	)
	event.emit("authorized")


func command_course(delta_degrees: float) -> void:
	if not active or finished:
		return
	route.clear()
	commanded_heading = wrapf(commanded_heading + deg_to_rad(delta_degrees), -PI, PI)


func command_waypoint(point: Vector2, append_route: bool = false) -> bool:
	if not active or finished or not point.is_finite():
		return false
	if not endless and not flight_bounds.has_point(point):
		return false
	if append_route:
		if not route.append(point):
			_announce("PILOT / Route is full or that fix is already entered.", "click")
			return false
	else:
		route.replace(point)
	commanded_heading = route.desired_heading(position, commanded_heading)
	_announce(
		(
			"PILOT / Chart fix added to the route."
			if append_route
			else "PILOT / Following your chart course."
		),
		"click"
	)
	return true


func undo_waypoint() -> bool:
	if not active or finished or not route.undo():
		return false
	commanded_heading = route.desired_heading(position, commanded_heading)
	_announce("PILOT / Last chart fix removed.", "click")
	return true


func radar_pose() -> Array:
	return [origin_east+position.x, origin_north+position.y, altitude]


func record_scan() -> void:
	scans_completed += 1


func tick(dt: float) -> void:
	if not active or finished or not is_finite(dt) or dt <= 0.0:
		return
	# Bounded substeps keep turning, threat pressure and waypoint crossing stable
	# under irregular frame rates. Tests can advance several seconds at once.
	var remaining := minf(dt, 60.0)
	while remaining > 0.000001 and not finished:
		var step := minf(remaining, 0.05)
		_step(step)
		remaining -= step


func _step(dt: float) -> void:
	elapsed += dt
	commanded_heading = route.desired_heading(position, commanded_heading)
	heading = heading_control.advance(heading,commanded_heading,dt) if endless else rotate_toward(heading, commanded_heading, deg_to_rad(tuning.turn_rate_degrees) * dt)
	altitude = move_toward(altitude, commanded_altitude, tuning.climb_rate * dt)
	var previous := position
	position += Vector2(sin(heading), cos(heading)) * speed * dt
	distance_flown += previous.distance_to(position)
	if route.advance(previous, position, tuning.waypoint_radius) > 0:
		_announce("PILOT / Chart fix passed. Continuing on course.", "click")
	if not endless:fuel = maxf(0.0, fuel - dt / tuning.fuel_duration)
	evade_time = maxf(0.0, evade_time - dt)
	scan_transmit_time = maxf(0.0, scan_transmit_time - dt)
	_update_pending_arm(dt)
	if endless:_update_coordinate_weapon(dt)
	_update_threats(dt)
	if endless:
		_rebase_if_needed()
		return
	if region_scenario=="sortie" and not payload_released:
		var remaining := position.distance_to(target)
		if not approach_announced and remaining<1600:
			approach_announced=true
			_announce("PILOT / ZULU ahead on the chart. Awaiting your decision.","click")
		if not zone_announced and remaining<tuning.release_radius:
			zone_announced=true
			_announce("WEAPONS / Inside the charted game objective area. Release remains manual.","click")
	if (
		fuel <= 0.0
		or integrity <= 0.0
		or not flight_bounds.has_point(position)

	):
		failure_reason = (
			"AIRFRAME LOST"
			if integrity <= 0.0
			else ("FUEL EXHAUSTED" if fuel <= 0.0 else "LEFT MISSION AREA")
		)
		finished = true
		survived = false
		_announce("MISSION LOST / Aircraft unable to continue. Press R to restart.", "failure")
		event.emit("failure")
	elif payload_released and position.distance_to(egress) < tuning.egress_radius:
		finished = true
		survived = true
		_announce(
			"MISSION COMPLETE / Egress reached. There is no reply from ground control.", "success"
		)
		event.emit("success")


func _update_pending_arm(dt: float) -> void:
	if missile_time <= 0.0:
		return
	missile_time -= dt
	if missile_time <= 0.0:
		for emitter in emitters:
			if int(emitter["id"]) == missile_emitter:
				emitter["disabled"] = true
				if endless:silenced[missile_emitter]=true
		tracking *= 0.35
		_announce("WEAPONS / Selected emitter has gone silent. No visual confirmation.", "silent")
		event.emit("emitter_silent")


func _update_threats(dt: float) -> void:
	var strongest := 0.0
	for emitter in emitters:
		if bool(emitter.get("disabled", false)):
			continue
		var p := Vector2(emitter["position"][0], emitter["position"][1])
		var pressure := clampf(1.0 - position.distance_to(p) / tuning.danger_radius, 0.0, 1.0)
		if altitude < 850.0:
			pressure *= 0.7
		strongest = maxf(strongest, pressure)
	if evade_time > 0.0:
		strongest *= 0.15
	tracking = clampf(
		tracking + dt * (strongest * tuning.danger_growth - tuning.danger_decay), 0.0, 1.0
	)
	incoming = tracking > 0.68
	if incoming and elapsed - last_warning > tuning.warning_interval:
		last_warning = elapsed
		_announce(
			"RWR / Launch warning. Pilot awaiting course change or countermeasures.", "warning"
		)
		event.emit("launch_warning")
	if tracking >= 0.98:
		integrity = maxf(.2 if endless else 0.0, integrity - tuning.damage_per_hit)
		hits += 1
		tracking = 0.26
		_announce("PILOT / Damage report. We are still flying.", "impact")
		event.emit("impact")


func receiver_contacts() -> Array:
	if endless:return _estimated_contacts()
	# Keep this narrow interface: RWR has no world positions or distance fields.
	var contacts: Array = []
	for emitter in emitters:
		if bool(emitter.get("disabled", false)):
			continue
		var d := Vector2(emitter["position"][0], emitter["position"][1]) - position
		var distance := d.length()
		var scanning := sin(elapsed * 0.62 + float(emitter["phase"])) > -0.50 or distance < 850.0
		if not scanning or distance > 2850.0:
			continue
		var strength := clampf((1.0 - distance / 3100.0) * float(emitter["power"]), 0.06, 1.0)
		var jitter := deg_to_rad(2.0) * sin(elapsed * 0.8 + float(int(emitter["id"])%1024) * 2.3)
		contacts.append(
			{
				"id": int(emitter["id"]),
				"bearing": wrapf(atan2(d.x, d.y) - heading + jitter, -PI, PI),
				"strength": strength,
				"tracking": distance < 850.0 and tracking > 0.28
			}
		)
	contacts.sort_custom(func(a, b): return float(a["strength"]) > float(b["strength"]))
	return contacts


func cycle_emitter() -> void:
	var contacts := receiver_contacts()
	if contacts.is_empty():
		selected_emitter = -1
		return
	var index := -1
	for i in range(contacts.size()):
		if int(contacts[i]["id"]) == selected_emitter:
			index = i
	selected_emitter = int(contacts[(index + 1) % contacts.size()]["id"])
	event.emit("selector")


func toggle_arm() -> void:
	if active and not finished:
		armed = not armed
		event.emit("switch")


func fire_arm() -> bool:
	if not active or finished or not armed:
		_announce("WEAPONS / Set the guarded ARM switch first.", "click")
		return false
	if arm_count <= 0 or missile_time > 0:
		_announce("WEAPONS / No weapon ready.", "click")
		return false
	var contacts := receiver_contacts()
	if contacts.is_empty():
		_announce("WEAPONS / No emitting signal. Launch inhibited.", "click")
		return false
	var selected := -1
	for contact in contacts:
		if int(contact["id"]) == selected_emitter:
			selected = selected_emitter
	if selected < 0:
		selected = int(contacts[0]["id"])
	selected_emitter = selected
	missile_emitter = selected
	missile_time = tuning.arm_delay
	arm_count -= 1
	_announce("WEAPONS / ARM away. Following the selected emitter.", "arm_away")
	event.emit("arm_away")
	return true


func deploy_countermeasure() -> bool:
	if not active or finished or countermeasures <= 0:
		return false
	countermeasures -= 1
	evade_time = tuning.countermeasure_duration
	tracking = maxf(0.0, tracking - tuning.countermeasure_reduction)
	_announce("PILOT / Countermeasures out. Keep us clear of the threat.", "chaff")
	event.emit("chaff")
	return true


func release_payload() -> bool:
	if not active or finished or not authorized or payload_released:
		return false
	if position.distance_to(target) > tuning.release_radius:
		_announce("WEAPONS / Outside the designated release area. Follow the paper chart.", "click")
		return false
	payload_released = true
	route.replace(egress)
	commanded_heading = route.desired_heading(position, commanded_heading)
	_announce(
		"WEAPONS / Payload released. Pilot turning to egress. Ground control, acknowledge.",
		"release"
	)
	event.emit("release")
	return true


func debrief() -> Dictionary:
	return {
		"phase": phase_name(),
		"survived": survived,
		"reason": failure_reason,
		"seconds": elapsed,
		"distance_m": distance_flown,
		"scans": scans_completed,
		"arm_used": tuning.initial_arm_count - arm_count,
		"countermeasures_used": tuning.initial_countermeasures - countermeasures,
		"integrity": integrity,
		"fuel": fuel,
		"fixes_passed": route.reached_count,
		"seed": seed_value,
		"journal": journal.duplicate(true)
	}


func select_briefed_route(name_: String) -> bool:
	if not active or finished or payload_released or not suggested_routes.has(name_):return false
	var planned:Array=suggested_routes[name_]
	if planned.is_empty() or planned.size()>Route.MAX_WAYPOINTS:return false
	for p in planned:
		if not flight_bounds.has_point(Vector2(p[0],p[1])):return false
	route.clear()
	for p in planned:route.append(Vector2(p[0],p[1]))
	commanded_heading=route.desired_heading(position,commanded_heading)
	_announce("PILOT / Following the "+name_+" pencilled route. Intelligence remains unconfirmed.","click")
	return true


func global_position_array() -> Array:
	return [origin_east+position.x,origin_north+position.y]

func global_point(point:Vector2) -> Array:
	return [origin_east+point.x,origin_north+point.y]

func local_point(point:Array) -> Vector2:
	return Vector2(float(point[0])-origin_east,float(point[1])-origin_north)

func command_direction(point:Vector2) -> bool:
	if not active or finished or not point.is_finite() or position.distance_to(point)<5:return false
	route.clear()
	commanded_heading=atan2(point.x-position.x,point.y-position.y)
	_announce("PILOT / Turning to heading %03d. Will hold that direction." % posmod(int(round(rad_to_deg(commanded_heading))),360),"click")
	return true

func update_endless_nearby(data:Dictionary) -> void:
	if not endless:return
	emitters=[]
	for source in data.get("emitters",[]):
		var e:Dictionary=source.duplicate(true)
		var p:=local_point(e["position"]);e["position"]=[p.x,p.y]
		e["disabled"]=bool(e.get("disabled",false)) or silenced.has(int(e["id"]))
		for impact in coordinate_impacts:
			var distance:=Vector2(float(source["position"][0])-float(impact[0]),float(source["position"][1])-float(impact[1])).length()
			if distance<=coordinate_weapon.impact_radius:
				e["disabled"]=true;silenced[int(e["id"])]=true
		emitters.append(e)
	suspected=[]
	for source in data.get("suspected",[]):
		var c:Dictionary=source.duplicate(true)
		var p:=local_point(c["center"]);c["center"]=[p.x,p.y];suspected.append(c)

func _rebase_if_needed() -> void:
	if maxf(absf(position.x),absf(position.y))<8192:return
	var shift:=Vector2(floor(position.x/4096)*4096,floor(position.y/4096)*4096)
	origin_east+=float(shift.x);origin_north+=float(shift.y);position-=shift
	target-=shift;egress-=shift
	for i in range(route.points.size()):route.points[i]-=shift
	for e in emitters:
		e["position"]=[float(e["position"][0])-shift.x,float(e["position"][1])-shift.y]
	for c in suspected:
		c["center"]=[float(c["center"][0])-shift.x,float(c["center"][1])-shift.y]
	origin_shift_count+=1
	origin_shifted.emit(shift)


func _estimated_contacts() -> Array:
	var result: Array=[]
	var maximum: float=ScanGeometry.limits["receiver_range_m"]
	for emitter in emitters:
		if emitter.get("disabled",false):continue
		var delta:=Vector2(emitter["position"][0],emitter["position"][1])-position
		var distance:=delta.length()
		if distance>maximum:continue
		var id:=int(emitter["id"])
		# A fictional received-strength estimate using an assumed source strength.
		# Variation in actual source power therefore produces range uncertainty.
		var strength:=float(emitter["power"])/(1.0+pow(distance/6000.0,2))
		var estimate:=6000.0*sqrt(maxf(0,.85/maxf(strength,.001)-1.0))
		estimate*=1.0+.045*sin(elapsed*.12+float(id%61))
		estimate=clampf(round(estimate/500.0)*500.0,500.0,maximum)
		result.append({"id":id,"bearing":wrapf(atan2(delta.x,delta.y)-heading+deg_to_rad(1.0)*sin(elapsed*.2+float(id%97)),-PI,PI),
			"strength":clampf(strength,.04,1.0),"tracking":distance<1800.0 and tracking>.28,
			"estimated_range_m":estimate,"range_uncertainty_m":maxf(500.0,estimate*.25)})
	result.sort_custom(func(a,b):return float(a["strength"])>float(b["strength"]))
	return result

func designate_radar_point(point: Array, scan_id: int) -> bool:
	if not endless or not active or finished or point.size()!=2 or scan_id<0:return false
	for value in point:
		if not is_finite(float(value)):return false
	designated_point=point.duplicate();designation_scan=scan_id
	last_coordinate_outcome="POINT MARKED"
	return true

func clear_designation() -> void:
	designated_point.clear();designation_scan=-1
	last_coordinate_outcome=""

func fire_coordinate() -> bool:
	if not endless or not active or finished or not armed:return false
	if arm_count<=0 or coordinate_weapon.active or designated_point.is_empty():return false
	if not coordinate_weapon.launch(global_position_array(),designated_point,designation_scan):return false
	arm_count-=1
	last_coordinate_outcome="IN FLIGHT"
	_announce("WEAPONS / Coordinate round away. Flying to the marked point.","arm_away")
	event.emit("coordinate_away")
	return true

func _update_coordinate_weapon(dt: float) -> void:
	if not coordinate_weapon.advance(dt):return
	var impact: Array=coordinate_weapon.destination.duplicate()
	coordinate_impacts.append(impact)
	if coordinate_impacts.size()>64:coordinate_impacts.pop_front()
	for emitter in emitters:
		var p: Array=global_point(Vector2(emitter["position"][0],emitter["position"][1]))
		if Vector2(float(p[0])-float(impact[0]),float(p[1])-float(impact[1])).length()<=coordinate_weapon.impact_radius:
			emitter["disabled"]=true;silenced[int(emitter["id"])]=true
	last_coordinate_outcome="IMPACT / UNCONFIRMED"
	_announce("WEAPONS / Round reached the marked coordinate. Effect unconfirmed.","impact")
	event.emit("coordinate_impact")
