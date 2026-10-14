extends RefCounted
## Fictional pilot response: limited turn rate and rate-of-turn acceleration.
## Setting a new heading never sets the actual heading or aircraft position.
var rate := 0.0
var maximum_rate := deg_to_rad(4.0)
var acceleration := deg_to_rad(2.0)

func reset() -> void:
	rate=0.0

func advance(heading:float,commanded:float,dt:float) -> float:
	if dt<=0.0:return heading
	var error:=wrapf(commanded-heading,-PI,PI)
	var braking_rate:=sqrt(2.0*acceleration*absf(error))
	var desired:=signf(error)*minf(maximum_rate,braking_rate)
	rate=move_toward(rate,desired,acceleration*dt)
	var change:=rate*dt
	if signf(change)==signf(error) and absf(change)>absf(error):
		rate=0.0
		return wrapf(commanded,-PI,PI)
	return wrapf(heading+change,-PI,PI)
