extends SceneTree
## Heading, long-distance origin, paper and streamed-emitter invariants.
const Mission=preload("res://game/cockpit/mission_state.gd")
const Chart=preload("res://game/cockpit/paper_chart.gd")
var passed:=0
var failed:=0

func check(ok:bool,message:String) -> void:
	if ok:passed+=1;print("PASS ",message)
	else:failed+=1;push_error(message)

func state():
	var m=Mission.new()
	m.tuning.cruise_speed=90.0
	m.setup({"seed":42,"scenario":"endless","start":[0,0],"target":[0,0],"egress":[0,0],
		"bounds":[-8000,8000,-10000,10000],"heading":0.0,"emitters":[],"suspected":[]})
	m.begin();return m

func _initialize() -> void:
	var m=state();var original:Vector2=m.position
	check(m.command_direction(Vector2(1000,0)),"Direction command accepted")
	check(m.heading==0.0 and m.position==original,"Command does not snap heading or move aircraft")
	m.tick(1)
	check(rad_to_deg(m.heading)>0 and rad_to_deg(m.heading)<2,"Turn builds gradually during first second")
	check(absf(rad_to_deg(m.heading_control.rate))<=4.01,"Turn rate respects the cap")
	for i in range(140):m.tick(.2)
	check(absf(wrapf(m.heading-PI/2,-PI,PI))<.002,"Pilot settles on requested direction")
	check(m.route.points.is_empty(),"A direction command is not a waypoint arrival")
	var settled:float=m.heading;m.tick(8)
	check(absf(wrapf(m.heading-settled,-PI,PI))<.002,"Pilot holds direction after passing the clicked location")
	check(m.command_direction(m.position+Vector2(-1500,0)),"Opposite heading accepted")
	var before:float=m.heading;m.tick(.05)
	check(absf(wrapf(m.heading-before,-PI,PI))<deg_to_rad(.01),"Reversing direction starts through a gradual turn")
	var far=state()
	for i in range(3000):far.tick(.5)
	var position:Array=far.global_position_array()
	check(position[1]>130000,"Flight crosses 130km without a map edge")
	check(not far.finished and far.fuel==1.0,"Exploration has no forced end or fuel countdown")
	check(far.origin_shift_count>10 and absf(far.position.y)<8192,"Local origin recenters repeatedly")
	check(absf(position[1]-far.distance_flown)<100,"Rebasing preserves travelled global distance")
	check(not far.release_payload(),"Exploration does not accidentally finish at an objective")
	var nearby={"emitters":[{"id":700000012345,"position":[position[0]+100,position[1]+100],"power":1,"phase":0}],
		"suspected":[{"center":[position[0]+150,position[1]+80],"radius":610}]}
	far.update_endless_nearby(nearby)
	check(Vector2(far.emitters[0]['position'][0],far.emitters[0]['position'][1]).distance_to(far.position)<150,"Global streamed actors converted to local coordinates")
	far.silenced[700000012345]=true;far.update_endless_nearby(nearby)
	check(far.emitters[0]['disabled'],"Suppression survives sheet reload")
	check(far.receiver_contacts().is_empty(),"Silenced emitter does not return to receiver")
	var c=Chart.new();c.size=Vector2(640,800);c.endless=true;c.aircraft=Vector2(0,0)
	c.configure_region([-8000,8000,-10000,10000]);c.change_extent(1600);c.select(Vector2(0,2000))
	var rect:Rect2=c.selection_rect();var cp:Vector2=c.selected_center
	check(rect.size.x==rect.size.y,"Four guide intersections delimit a square in chart coordinates")
	check(Rect2(Vector2.ZERO,c.size).encloses(rect),"All four guide positions fit on the paper")
	c.aircraft.y+=250;c.follow_paper()
	check(c.selection_rect()==rect and c.selected_center.distance_to(cp+Vector2(0,250))<.1,"Mechanical bars stay over the rolling paper, not welded to world ink")
	c.change_extent(2800)
	check(absf(c.selection_rect().size.x/float(c.scale_px)-2800)<.01,"Guide width represents actual selected metres")
	var extent:float=c.selected_extent;var old_scale:float=c.scale_px;c.cycle_scale()
	check(c.scale_px!=old_scale,"Paper scale visibly changes on the first command")
	check(c.selected_extent==extent,"Paper scale does not change scan area")
	c.select(Vector2(9999,9999));check(Rect2(Vector2.ZERO,c.size).encloses(c.selection_rect()),"Guide travel stops at the hardware rails")
	c.change_extent(4000)
	var changes:=true
	for i in range(8):
		var previous_scale:float=c.scale_px
		c.cycle_scale()
		changes=changes and not is_equal_approx(previous_scale,c.scale_px)
	check(changes,"Paper zoom skips magnifications that cannot fit a large square")
	c.free()
	m.setup({"seed":42,"scenario":"endless","start":[0,0],"target":[0,0],"egress":[0,0],"emitters":[],"suspected":[]})
	check(m.heading_control.rate==0 and m.origin_shift_count==0,"Restart resets turn and world-origin state")
	print("ENDLESS_FLIGHT_TESTS ",JSON.stringify({"passed":passed,"failed":failed}))
	quit(0 if failed==0 else 1)
