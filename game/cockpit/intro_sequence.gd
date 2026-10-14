extends RefCounted
## Pure timeline. Presentation consumes a snapshot; no camera/audio/node access.
signal cue(name: String)
const END_TIME := 10.5
var elapsed := 0.0
var started := false
var complete := false


func start() -> void:
	elapsed = 0.0
	started = true
	complete = false


func advance(dt: float) -> void:
	if not started or complete or not is_finite(dt) or dt <= 0.0:
		return
	var previous := elapsed
	elapsed = minf(END_TIME, elapsed + dt)
	for boundary in [[3.0, "flash"], [3.25, "shutter"], [END_TIME, "begin_mission"]]:
		if previous < float(boundary[0]) and elapsed >= float(boundary[0]):
			cue.emit(str(boundary[1]))
	complete = elapsed >= END_TIME


func skip() -> void:
	if not started or complete:
		return
	elapsed = END_TIME
	complete = true
	cue.emit("begin_mission")


func snapshot(reduced_flash: bool = true) -> Dictionary:
	var stage := "loading"
	if started:
		stage = "daylight"
		if elapsed >= 3.0:
			stage = "flash_and_shutter"
		if elapsed >= 5.4:
			stage = "blackout"
		if elapsed >= 6.8:
			stage = "defcon"
		if complete:
			stage = "active"
	var flash := 0.0
	if stage == "flash_and_shutter":
		flash = clampf(1.0 - absf(elapsed - 3.35) / 0.7, 0.0, 1.0)
		flash *= 0.45 if reduced_flash else 0.94
	return {
		"stage": stage,
		"flash": flash,
		"shutters": smoothstep(3.3, 5.2, elapsed),
		"blackout": stage == "blackout",
		"red": smoothstep(6.8, 7.2, elapsed)
	}
