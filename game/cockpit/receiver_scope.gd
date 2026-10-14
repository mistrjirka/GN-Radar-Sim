extends Control
## A bearing-only receiver, not a range plot. All contacts share one fixed radius.
var contacts: Array=[]
var selected_id := -1
var powered := false
var warning := false
var font: Font=ThemeDB.fallback_font
var phase := 0.0
var signal_level := 0.0

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO,size),Color(.017,.022,.020))
	var center:=Vector2(size.x*.5,size.y*.41)
	var radius:=size.x*.405
	draw_circle(center,radius+8,Color(.004,.006,.005))
	draw_circle(center,radius,Color(.011,.031,.019))
	for deg in range(0,360,10):
		var a:=deg_to_rad(deg)-PI/2
		var d:=Vector2(cos(a),sin(a))
		var long_tick:=deg%30==0
		draw_line(center+d*(radius-7),center+d*(radius-(17 if long_tick else 11)),Color(.28,.38,.26),1.0,true)
		if long_tick:
			var text:=str(deg)
			var pos:=center+d*(radius-30)
			draw_string(font,pos-Vector2(font.get_string_size(text,HORIZONTAL_ALIGNMENT_LEFT,-1,14).x/2,-5),text,HORIZONTAL_ALIGNMENT_LEFT,-1,14,Color(.45,.48,.34))
	# Aircraft reference is fixed. No moving sweep, range rings or range labels.
	var ink:=Color(.28,.48,.25) if powered else Color(.045,.08,.045)
	draw_line(center+Vector2(0,11),center+Vector2(0,-13),ink,1.4,true)
	draw_line(center+Vector2(-10,1),center+Vector2(10,1),ink,1.4,true)
	draw_line(center+Vector2(-5,9),center+Vector2(5,9),ink,1.4,true)
	if powered:
		for c in contacts:
			var bearing:=float(c["bearing"])-PI/2
			var d:=Vector2(cos(bearing),sin(bearing))
			var strength:=float(c["strength"])
			var picked:=int(c["id"])==selected_id
			var intensity:=.36+.58*strength
			var color:=Color(.39*intensity,.96*intensity,.31*intensity)
			# Equal radial endpoints for every contact: direction and brightness
			# only. No signal is placed closer because it is stronger.
			var a:=center+d*radius*.52
			var b:=center+d*radius*.79
			draw_line(a,b,Color(color.r,color.g,color.b,.1),7,true)
			draw_line(a,b,color,2.0 if picked else 1.3,true)
			if picked:
				var t:=Vector2(-d.y,d.x)
				draw_line(b-t*4,b+t*4,color,1.2,true)
	# Separate moving-coil signal meter, not radial distance from aircraft.
	var meter:=Rect2(56,size.y*.84,size.x-112,size.y*.12)
	draw_rect(meter,Color(.14,.135,.103))
	var pivot:=Vector2(size.x/2,size.y*1.06)
	var mr:=size.x*.26
	for i in range(11):
		var a:=deg_to_rad(-129+i*7.8)
		var d:=Vector2(cos(a),sin(a))
		draw_line(pivot+d*mr,pivot+d*(mr-6),Color(.02,.025,.02),1.0,true)
	var angle:=deg_to_rad(-129+78*clampf(signal_level,0,1))
	var tip:=pivot+Vector2(cos(angle),sin(angle))*mr
	var entry:=clampf((meter.end.y-pivot.y)/(tip.y-pivot.y),0,1)
	draw_line(pivot.lerp(tip,entry),tip,Color(.55,.14,.05),1.7,true)
	draw_string(font,Vector2(70,size.y*.93),"LOW",HORIZONTAL_ALIGNMENT_LEFT,-1,11,Color(.045,.035,.02))
	draw_string(font,Vector2(size.x-103,size.y*.93),"HIGH",HORIZONTAL_ALIGNMENT_LEFT,-1,11,Color(.045,.035,.02))
