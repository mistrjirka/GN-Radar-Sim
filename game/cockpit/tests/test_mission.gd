extends SceneTree
const State=preload("res://game/cockpit/mission_state.gd")
const Paper=preload("res://game/cockpit/paper_chart.gd")
var passed:=0
var failed:=0

func check(ok: bool,name: String) -> void:
	if ok:passed+=1;print("PASS ",name)
	else:failed+=1;push_error("FAIL "+name)

func fresh():
	var state=State.new()
	state.setup({"seed":42,"start":[0,-1870],"target":[565,235],"egress":[850,-1500],
		"emitters":[{"id":0,"position":[-500,-450],"power":1.0,"phase":0.0,"disabled":false},
		 {"id":1,"position":[650,-560],"power":.8,"phase":0.5,"disabled":false}],
		"suspected":[{"center":[-420,-380],"radius":260,"label":"SAM ?"}]})
	return state

func _initialize() -> void:
	var s=fresh()
	check(not s.active and not s.authorized,"No authority before radio orders")
	check(not s.release_payload(),"Payload inhibited before mission begins")
	s.begin();check(s.active and s.authorized,"Order starts mission")
	var before: Vector2=s.position;s.tick(1)
	check(s.position.distance_to(before)>50,"Aircraft actually moves")
	check(not s.release_payload(),"Release inhibited away from designated target")
	var contacts: Array=s.receiver_contacts()
	check(not contacts.is_empty(),"Receiver detects active emitters")
	var restricted_ok:=true
	for c in contacts:
		for key in c.keys():
			if key not in ["id","bearing","strength","tracking"]:restricted_ok=false
	check(restricted_ok,"RWR interface contains no positions, ranges or estimated locations")
	check(not s.fire_arm(),"ARM launch inhibited when master arm is safe")
	s.toggle_arm();s.cycle_emitter()
	var count:int=s.arm_count
	check(s.fire_arm() and s.arm_count==count-1,"ARM uses finite inventory")
	var victim:int=s.missile_emitter
	s.tick(7)
	var disabled:=false
	for e in s.emitters:
		if int(e["id"])==victim:disabled=e["disabled"]
	check(disabled,"Placeholder ARM suppresses its selected emitter after delay")
	var gone:=true
	for c in s.receiver_contacts():
		if int(c["id"])==victim:gone=false
	check(gone,"Suppressed emitter disappears from receiver")
	var cm:int=s.countermeasures
	s.tracking=.9
	check(s.deploy_countermeasure() and s.countermeasures==cm-1 and s.tracking<.9,"Countermeasure inventory and temporary defensive effect")
	var goal=fresh();goal.begin();goal.speed=0;goal.position=goal.target
	check(goal.release_payload(),"Placeholder release accepted in designated area")
	check(not goal.release_payload(),"Payload cannot be released twice")
	goal.position=goal.egress;goal.tick(.1)
	check(goal.finished and goal.survived,"Mission has a reachable egress/win state")
	var loss=fresh();loss.begin();loss.integrity=0;loss.tick(.1)
	check(loss.finished and not loss.survived,"Mission has a damage/fail state")
	var simultaneous=fresh();simultaneous.begin();simultaneous.speed=0;simultaneous.payload_released=true
	simultaneous.position=simultaneous.egress;simultaneous.integrity=0;simultaneous.tick(.1)
	check(simultaneous.finished and not simultaneous.survived,"Damage failure cannot be overwritten by an egress success")
	var chart=Paper.new();chart.size=Vector2(640,800);chart.aircraft=Vector2(-150,-1700)
	var p:=Vector2(370,120)
	check(chart.screen_to_world(chart.world_to_screen(p)).distance_to(p)<.01,"Chart projection and pointer selection round trip")
	var a:Vector2=chart.world_to_screen(p);chart.aircraft.y+=100
	var b:Vector2=chart.world_to_screen(p)
	check(absf(b.y-a.y-100*chart.scale_px)<.01,"Paper rolls according to actual flight displacement")
	chart.change_extent(1000);chart.select(Vector2(900,900))
	check(chart.selected_center==Vector2(500,500),"Selection remains inside available radar terrain")
	chart.free()
	s=null;goal=null;loss=null;simultaneous=null
	print("MISSION_TESTS ",JSON.stringify({"passed":passed,"failed":failed}))
	quit(0 if failed==0 else 1)
