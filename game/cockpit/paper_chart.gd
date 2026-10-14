extends Control
## North-up physical paper: paper moves with aircraft; ink annotations move with it.
## Enemy coordinates are never passed into this view, only uncertain intel circles.
var chart: Texture2D
var endless:=false
var commanded_heading:=0.0
var selector_screen:=Vector2(320,360)
var sheet_revision:=0
var world_bounds := Rect2(-1000,-1000,2000,2000)
var scale_index := 0
var aircraft := Vector2(0, -1870)
var heading := 0.0
var target := Vector2(565, 235)
var egress := Vector2(850, -1500)
var suspected: Array = []
var selected_center := Vector2.ZERO
var selected_extent := 1000.0
var scale_px := .29
var route_points: Array[Vector2] = []
var phase_text := "AWAIT ORDERS"
var trail := PackedVector2Array()
var released := false
var font: Font = ThemeDB.fallback_font
var paper_color := Color(.79, .69, .46)


func anchor() -> Vector2:
	return Vector2(size.x * .50, size.y * .81)


func world_to_screen(p: Vector2) -> Vector2:
	return anchor() + Vector2((p.x - aircraft.x) * scale_px, -(p.y - aircraft.y) * scale_px)


func screen_to_world(p: Vector2) -> Vector2:
	var d: Vector2 = (p - anchor()) / scale_px
	return aircraft + Vector2(d.x, -d.y)


func select(point: Vector2) -> void:
	if endless:
		_fit_selector()
		var half:=selected_extent*scale_px/2
		selector_screen=world_to_screen(point).clamp(Vector2.ONE*(half+14),size-Vector2.ONE*(half+14))
		selected_center=screen_to_world(selector_screen)
		queue_redraw();return
	var h := selected_extent / 2
	selected_center = Vector2(
		clampf(point.x, world_bounds.position.x + h, world_bounds.end.x - h), clampf(point.y, world_bounds.position.y + h, world_bounds.end.y - h)
	)
	queue_redraw()


func change_extent(value: float) -> void:
	selected_extent = value
	select(selected_center)


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), paper_color)
	# A continuous paper grid also covers the blank chart leader before terrain.
	var start := screen_to_world(Vector2(0, size.y))
	var finish := screen_to_world(Vector2(size.x, 0))
	for x in range(int(floor(start.x / 250)) * 250, int(finish.x) + 251, 250):
		var pos := world_to_screen(Vector2(x, 0)).x
		draw_line(Vector2(pos, 0), Vector2(pos, size.y), Color(.31, .29, .23, .25), .7)
	for y in range(int(floor(start.y / 250)) * 250, int(finish.y) + 251, 250):
		var pos := world_to_screen(Vector2(0, y)).y
		draw_line(Vector2(0, pos), Vector2(size.x, pos), Color(.31, .29, .23, .25), .7)
	if chart:
		var nw := world_to_screen(Vector2(world_bounds.position.x,world_bounds.end.y))
		draw_texture_rect(chart, Rect2(nw, world_bounds.size * scale_px), false)
	# Irregular pencilled circles: their centers are deliberately imprecise.
	for i in range(suspected.size()):
		var circle = suspected[i]
		var center := world_to_screen(Vector2(circle["center"][0], circle["center"][1]))
		var radius := float(circle["radius"]) * scale_px
		if not Rect2(center-Vector2.ONE*radius,Vector2.ONE*radius*2).intersects(Rect2(Vector2.ZERO,size)):continue
		var points := PackedVector2Array()
		for j in range(81):
			var a := TAU * float(j) / 80
			var r := radius * (1.0 + .018 * sin(a * 5 + i) + .01 * sin(a * 11 + i * 3))
			points.append(center + Vector2(cos(a), sin(a)) * r)
		draw_polyline(points, Color(.40, .11, .075, .85), 2.0, true)
		draw_string(
			font,
			center + Vector2(radius * .65, -radius * .75),
			"SAM ?",
			HORIZONTAL_ALIGNMENT_LEFT,
			-1,
			15,
			Color(.38, .08, .055)
		)
	if not endless:
		# Predesignated objective and egress are charted, not detected targets.
		var goal := world_to_screen(egress if released else target)
		draw_line(goal - Vector2(8, 0), goal + Vector2(8, 0), Color(.24, .11, .075), 1.7, true)
		draw_line(goal - Vector2(0, 8), goal + Vector2(0, 8), Color(.24, .11, .075), 1.7, true)
		draw_arc(goal, 11, 0, TAU, 28, Color(.26, .10, .065), 1.3, true)
		draw_string(
			font,
			goal + Vector2(14, -10),
			"EGRESS" if released else "ZULU",
			HORIZONTAL_ALIGNMENT_LEFT,
			-1,
			17,
			Color(.25, .08, .03)
		)
	_draw_route()
	if trail.size() > 1:
		var pts := PackedVector2Array()
		for p in trail:
			pts.append(world_to_screen(p))
		draw_polyline(pts, Color(.40, .14, .09, .7), 1.5, true)
	# Selection is now four native mechanical bars built by chart_mechanism.gd.
	# No tinted rectangle or glowing corner dots are painted onto the paper.
	if endless:
		var aim:=Vector2(sin(commanded_heading),-cos(commanded_heading))
		var segment:=clip_chart_segment(anchor(),anchor()+aim*2000,Rect2(Vector2(12,12),size-Vector2(24,24)))
		if segment.size()==2:draw_dashed_line(segment[0],segment[1],Color(.16,.22,.24,.75),1.4,8,true)
	var a := anchor()
	var tip := Vector2(sin(heading), -cos(heading))
	var right := Vector2(cos(heading), sin(heading))
	draw_line(a - tip * 12, a + tip * 13, Color(.14, .16, .15), 2.0, true)
	draw_line(a - right * 10, a + right * 10, Color(.14, .16, .15), 2.0, true)
	draw_line(a - tip * 9 - right * 5, a - tip * 9 + right * 5, Color(.14, .16, .15), 1.8, true)
	# Glass and edge shadows reveal the lit paper without coating it in glow.
	for i in range(10):
		var opacity := .13 * (1 - float(i) / 10)
		draw_rect(Rect2(Vector2(i, 0), Vector2(1, size.y)), Color(.05, .025, .01, opacity))
		draw_rect(Rect2(Vector2(size.x - i, 0), Vector2(1, size.y)), Color(.05, .025, .01, opacity))


func _draw_route() -> void:
	# Clip pencil segments BEFORE generating dash geometry. A distant off-screen
	# waypoint must not create thousands of draw calls at high chart magnification.
	var previous := anchor()
	var ink := Color(0.16,0.22,0.24,0.78)
	var visible := Rect2(Vector2(-24,-24),size+Vector2(48,48))
	for i in range(route_points.size()):
		var next := world_to_screen(route_points[i])
		var clipped := clip_chart_segment(previous,next,visible)
		if clipped.size()==2:draw_dashed_line(clipped[0],clipped[1],ink,1.4,6.0,true)
		if visible.has_point(next):
			draw_arc(next,8,0,TAU,24,ink,1.5,true)
			draw_string(font,next+Vector2(10,15),str(i+1),HORIZONTAL_ALIGNMENT_LEFT,-1,15,ink)
		previous=next


func clip_chart_segment(a: Vector2,b: Vector2,rect:Rect2) -> PackedVector2Array:
	var delta:=b-a
	var lower:=0.0
	var upper:=1.0
	var p: Array[float]=[-delta.x,delta.x,-delta.y,delta.y]
	var q: Array[float]=[a.x-rect.position.x,rect.end.x-a.x,a.y-rect.position.y,rect.end.y-a.y]
	for i in range(4):
		if absf(p[i])<0.000001:
			if q[i]<0:return PackedVector2Array()
		else:
			var t:=q[i]/p[i]
			if p[i]<0:lower=maxf(lower,t)
			else:upper=minf(upper,t)
			if lower>upper:return PackedVector2Array()
	return PackedVector2Array([a+lower*delta,a+upper*delta])


func configure_region(bounds: Array) -> void:
	world_bounds=Rect2(Vector2(bounds[0],bounds[2]),Vector2(bounds[1]-bounds[0],bounds[3]-bounds[2]))
	scale_index=2 if world_bounds.size.x>2000 else 4
	scale_px=0.11 if world_bounds.size.x>2000 else .29
	select(selected_center)

func cycle_scale() -> void:
	var choices:Array=[.065,.08,.11,.20,.29] if endless else [.04,.08,.11,.20,.29]
	if endless:
		var limit:float=(minf(size.x,size.y)-60)/maxf(selected_extent,1)
		choices=choices.filter(func(value):return float(value)<=limit+.000001)
	if choices.is_empty():return
	# Skip magnifications that cannot fit the guide square. Every press changes
	# scale; it must not choose two consecutive values that both clamp identically.
	var chosen:float=float(choices[0])
	for value in choices:
		if float(value)>scale_px+.000001:
			chosen=float(value);break
	scale_px=chosen
	if endless:follow_paper()
	queue_redraw()


func selection_rect() -> Rect2:
	var center:=selector_screen if endless else world_to_screen(selected_center)
	var length:=selected_extent*scale_px
	return Rect2(center-Vector2.ONE*length/2,Vector2.ONE*length)

func _fit_selector() -> void:
	if selected_extent*scale_px>minf(size.x,size.y)-60:
		scale_px=(minf(size.x,size.y)-60)/selected_extent
	var half:=selected_extent*scale_px/2
	selector_screen=selector_screen.clamp(Vector2.ONE*(half+14),size-Vector2.ONE*(half+14))

func follow_paper() -> void:
	if endless:
		_fit_selector()
		selected_center=screen_to_world(selector_screen)

func install_sheet(texture:Texture2D,bounds:Rect2) -> void:
	chart=texture;world_bounds=bounds;sheet_revision+=1;queue_redraw()
