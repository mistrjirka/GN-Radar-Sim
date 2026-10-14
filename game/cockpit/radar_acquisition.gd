extends RefCounted
## Immutable acquisition metadata and display-resolving lifecycle, not radar math.
## A complete soft image resolves AFTER the real worker supplies that frame.
var stage := "idle"
var pending: Dictionary = {}
var incoming: Dictionary = {}
var frame: Dictionary = {}
var progress := 1.0
var resolve_seconds := 1.8
var request_id := -1

func is_busy() -> bool:
	return stage in ["computing", "resolving"]

func begin(id: int, pose: Array, heading: float, center: Array, extent: float, quality: String) -> void:
	request_id=id
	pending={"id":id,"pose":pose.duplicate(),"heading":heading,"global_center":center.duplicate(),"extent":extent,"quality":quality}
	incoming.clear()
	stage="computing"
	progress=0.0

func receive(details: Dictionary) -> bool:
	if stage!="computing" or int(details.get("id",-1))!=request_id:return false
	incoming=details.duplicate(true)
	incoming["global_center"]=pending["global_center"].duplicate()
	incoming["heading"]=pending["heading"]
	resolve_seconds={"survey":1.0,"map":1.5,"detail":2.2}[pending["quality"]]
	stage="resolving"
	return true

func advance(dt: float) -> bool:
	if stage!="resolving" or dt<=0:return false
	progress=minf(1.0,progress+dt/resolve_seconds)
	if progress<1.0:return false
	frame=incoming.duplicate(true)
	stage="ready"
	pending.clear()
	return true

func fail() -> void:
	pending.clear();incoming.clear()
	stage="ready" if not frame.is_empty() else "idle"
	progress=1.0

func can_designate() -> bool:
	return stage=="ready" and not frame.is_empty()
