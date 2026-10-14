extends PanelContainer
## Paper briefing emits pilot-route intent. It has no hidden threat information.
signal close_requested
signal route_requested(name: String)
const Chart=preload("res://game/cockpit/briefing_chart.gd")
var public_data: Dictionary={}
var chart
var briefing_text: RichTextLabel
var route_description: Label
var selected_route := "western"
var heading_label:Label
var route_buttons:Array[Button]=[]

func build() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	offset_left=-540;offset_right=540;offset_top=-380;offset_bottom=380
	var bg:=StyleBoxFlat.new()
	bg.bg_color=Color(.66,.60,.44,.99);bg.set_content_margin_all(20)
	bg.set_border_width_all(5);bg.border_color=Color(.20,.15,.095)
	add_theme_stylebox_override("panel",bg)
	var row:=HBoxContainer.new();row.add_theme_constant_override("separation",20);add_child(row)
	chart=Chart.new();chart.custom_minimum_size=Vector2(475,660);chart.size_flags_vertical=Control.SIZE_EXPAND_FILL
	row.add_child(chart)
	var right:=VBoxContainer.new();right.size_flags_horizontal=Control.SIZE_EXPAND_FILL;right.add_theme_constant_override("separation",14);row.add_child(right)
	var title:=Label.new();heading_label=title;title.text="RAVEN TWO / SORTIE ORDERS";title.add_theme_font_size_override("font_size",25);title.add_theme_color_override("font_color",Color(.22,.06,.025));right.add_child(title)
	briefing_text=RichTextLabel.new();briefing_text.bbcode_enabled=true
	briefing_text.add_theme_color_override("default_color",Color(.16,.13,.095));briefing_text.add_theme_font_size_override("normal_font_size",18)
	briefing_text.size_flags_vertical=Control.SIZE_EXPAND_FILL;right.add_child(briefing_text)
	route_description=Label.new();route_description.autowrap_mode=TextServer.AUTOWRAP_WORD_SMART
	route_description.add_theme_color_override("font_color",Color(.19,.13,.075));right.add_child(route_description)
	for record in [["Preview western route","western"],["Preview direct route","direct"]]:
		var b:=Button.new();b.text=record[0];var name_:String=record[1]
		b.pressed.connect(func():preview(name_));right.add_child(b);route_buttons.append(b)
	var accept:=Button.new();accept.text="Give pencilled route to pilot"
	accept.pressed.connect(func():route_requested.emit(selected_route));right.add_child(accept);route_buttons.append(accept)
	var close:=Button.new();close.text="Return to instruments [B]"
	close.pressed.connect(func():close_requested.emit());right.add_child(close)
	hide()

func configure(data: Dictionary, texture: Texture2D) -> void:
	# Explicit allowlist: do not store the combined worker/game manifest here.
	public_data={}
	for key in ["endless","seed","bounds","start","target","egress","suspected","suggested_routes","map_size_km"]:
		if data.has(key):public_data[key]=data[key]
	chart.public_data=public_data;chart.chart=texture;chart.queue_redraw()
	var open_flight:bool=bool(data.get("endless",false))
	heading_label.text="RAVEN TWO / OPEN FLIGHT" if open_flight else "RAVEN TWO / SORTIE ORDERS"
	for button in route_buttons:button.visible=not open_flight
	if open_flight:
		briefing_text.text="[b]OPEN FLIGHT[/b]\nChoose your direction. The next terrain and paper sections are generated as you travel. There is no mission edge, fuel countdown or forced return.\n\n[b]HEADING[/b]\nShift-click a direction on the paper. SET is the pilot's commanded heading; HDG is the aircraft's current direction. The aircraft turns gradually, then holds course. A/D trims the heading.\n\n[b]SCAN[/b]\nMove the four mechanical bars by clicking on the paper. The central square is the acquisition area. Mouse wheel or AREA changes its width. Z changes paper scale.\n\n[b]RESOLUTION[/b]\nRES on the radar bezel or 1/2/3 selects FAST / MED / FINE. Coarser scans calculate faster. No labels are painted over the radar returns.\n\n[b]INTELLIGENCE[/b]\nCircles indicate uncertain reports. The RWR gives only direction and strength. Current defensive rules are practice placeholders."
		route_description.text="LOCAL PAPER SECTION / SEED %d\nThis sheet is a moving window, not the edge of the world." % int(data.get("seed",42))
		return
	briefing_text.text="[b]ORDERS[/b]\nProceed to the charted ZULU objective. Execute the assigned mission, then return to EGRESS.\n\n[b]INTELLIGENCE[/b]\nCircles are suspected areas, not exact sites. Some reports are stale. The receiver gives bearing and strength only.\n\n[b]WORKFLOW[/b]\nPlan on paper. Choose a scan box ahead and press SCAN. Compare real returns with uncertain reports. Adjust course, suppress an emitting threat or deploy countermeasures.\n\n[b]REGION[/b]\n12 × 18 km / seed %d\nThreat reports are incomplete. Some marked areas may be empty; silence is not confirmation of safety.\n\n[b]CONTROLS[/b]\nZ changes paper scale independently of scan size. Shift-click replaces a route; Ctrl+Shift-click adds a fix.\n\nNo reply from ground control is expected after release." % int(data.get("seed",42))
	preview(selected_route)

func preview(name_: String) -> void:
	selected_route=name_;chart.route_name=name_;chart.queue_redraw()
	var points:Array=public_data.get("suggested_routes",{}).get(name_,[])
	var previous:Array=public_data.get("start",[0,0]);var distance:=0.0
	for p in points:
		distance+=Vector2(p[0],p[1]).distance_to(Vector2(previous[0],previous[1]));previous=p
	route_description.text="%s / %.1f km inbound. These pencilled suggestions use the briefing, not hidden emitter coordinates; neither is guaranteed clear." % [name_.to_upper(),distance/1000]
