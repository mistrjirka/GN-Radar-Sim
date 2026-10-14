extends CanvasLayer
## Captions, controls and paper-like debrief, outside the three instrument screens.
## Emits intent only; cannot move aircraft, consume stores or read emitter data.
signal resume_requested
signal restart_requested
signal new_seed_requested
signal quit_requested
signal briefing_requested
signal reduced_flash_changed(enabled: bool)

var flash: ColorRect
var captions: Label
var caption_panel: PanelContainer
var hint: Label
var menu: PanelContainer
var result_panel: PanelContainer
var journal: RichTextLabel
var result_title: Label
var result_body: RichTextLabel
var reduced_toggle: CheckBox
var caption_seconds := 0.0


func _style(color: Color, margin: int = 22) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.set_content_margin_all(margin)
	style.border_color = Color(0.31, 0.20, 0.12)
	style.set_border_width_all(2)
	style.set_corner_radius_all(5)
	return style


func _button(text: String, action: Callable, parent: Node) -> void:
	var button := Button.new()
	button.text = text
	button.pressed.connect(action)
	parent.add_child(button)


func _center_panel(width: float, height: float) -> PanelContainer:
	var panel := PanelContainer.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	panel.offset_left = -width / 2
	panel.offset_right = width / 2
	panel.offset_top = -height / 2
	panel.offset_bottom = height / 2
	add_child(panel)
	panel.add_theme_stylebox_override("panel", _style(Color(0.018, 0.025, 0.025, 0.98)))
	panel.hide()
	return panel


func build() -> void:
	flash = ColorRect.new()
	flash.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	flash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	flash.color = Color(1, 0.97, 0.90, 0)
	add_child(flash)
	var bottom := MarginContainer.new()
	bottom.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	bottom.offset_top = -48
	bottom.offset_left = 50
	bottom.offset_right = -50
	bottom.offset_bottom = -4
	bottom.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bottom)
	caption_panel = PanelContainer.new()
	caption_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	caption_panel.add_theme_stylebox_override("panel", _style(Color(0.006, 0.009, 0.008, 0.88), 10))
	bottom.add_child(caption_panel)
	captions = Label.new()
	captions.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	captions.add_theme_font_size_override("font_size", 16)
	captions.add_theme_color_override("font_color", Color(0.88, 0.68, 0.43))
	caption_panel.add_child(captions)
	hint = Label.new()
	hint.position = Vector2(22, 16)
	hint.add_theme_font_size_override("font_size", 14)
	hint.add_theme_color_override("font_color", Color(0.55, 0.43, 0.30))
	hint.text = "H / FLIGHT NOTES"
	add_child(hint)
	_build_menu()
	_build_debrief()


func _build_menu() -> void:
	menu = _center_panel(780, 700)
	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 14)
	menu.add_child(content)
	var title := Label.new()
	title.text = "RAVEN TWO / FLIGHT NOTES"
	title.add_theme_font_size_override("font_size", 25)
	content.add_child(title)
	var text := RichTextLabel.new()
	text.bbcode_enabled = true
	text.custom_minimum_size.y = 325
	text.size_flags_vertical = Control.SIZE_EXPAND_FILL
	text.add_theme_font_size_override("normal_font_size", 17)
	text.text = "[b]RIGHT / PAPER CHART[/b]\nAircraft stays bottom-center; the map turns underneath.\nClick moves the guides. Wheel adjusts area; Z changes paper scale.\nShift-click commands direction; Ctrl+Shift-click adds a fix.\nB opens the local chart. Delete removes the last navigation fix.\n\n[b]CENTER / RADAR[/b]\nSpace / SCAN measures a forward area. RES or 1/2/3 changes detail.\nMAP HOLD locks the paper during measurement and CRT writing; flight continues.\nIn endless mode, click a completed radar image to mark a coordinate.\nM master arm / F sends a provisional coordinate round / CLEAR removes the mark.\n\n[b]LEFT / WARNING RECEIVER[/b]\nEndless: bearing plus uncertain range on a circular scope.\nC selects a contact for inspection only; it does not aim the coordinate round.\nX deploys a countermeasure. Reference mode retains the old ARM/receiver rules.\n\n[b]FLIGHT[/b]\nA/D heading; Q/E altitude; W/S speed. Turns are gradual.\nF1/F2/F3 inspect instruments; F4 normal view; right-drag look.\nP pause / H or Esc notes / Backspace skip intro / R restart / N new seed."
	content.add_child(text)
	reduced_toggle = CheckBox.new()
	reduced_toggle.text = "Reduced-flash intro"
	reduced_toggle.button_pressed = true
	reduced_toggle.toggled.connect(func(value): reduced_flash_changed.emit(value))
	content.add_child(reduced_toggle)
	var label := Label.new()
	label.text = "RECEIVED RADIO / MOST RECENT FIRST"
	label.add_theme_font_size_override("font_size", 14)
	content.add_child(label)
	journal = RichTextLabel.new()
	journal.custom_minimum_size.y = 125
	journal.size_flags_vertical = Control.SIZE_EXPAND_FILL
	journal.add_theme_font_size_override("normal_font_size", 15)
	content.add_child(journal)
	var buttons := HBoxContainer.new()
	content.add_child(buttons)
	_button("Return to station", func(): resume_requested.emit(), buttons)
	_button("Sortie chart [B]",func():briefing_requested.emit(),buttons)
	_button("Restart", func(): restart_requested.emit(), buttons)
	_button("New seed", func(): new_seed_requested.emit(), buttons)
	_button("Quit", func(): quit_requested.emit(), buttons)


func _build_debrief() -> void:
	result_panel = _center_panel(720, 560)
	result_panel.add_theme_stylebox_override("panel", _style(Color(0.70, 0.63, 0.44, 0.99), 28))
	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 15)
	result_panel.add_child(content)
	result_title = Label.new()
	result_title.add_theme_font_size_override("font_size", 27)
	result_title.add_theme_color_override("font_color", Color(0.20, 0.16, 0.11))
	content.add_child(result_title)
	result_body = RichTextLabel.new()
	result_body.bbcode_enabled = true
	result_body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	result_body.custom_minimum_size.y = 340
	result_body.add_theme_color_override("default_color", Color(0.19, 0.17, 0.12))
	result_body.add_theme_font_size_override("normal_font_size", 19)
	content.add_child(result_body)
	var buttons := HBoxContainer.new()
	content.add_child(buttons)
	_button("Replay this seed", func(): restart_requested.emit(), buttons)
	_button("New seed", func(): new_seed_requested.emit(), buttons)
	_button("Inspect cockpit", func(): result_panel.hide(), buttons)
	_button("Quit", func(): quit_requested.emit(), buttons)


func say(text: String, duration: float = 7.0) -> void:
	captions.text = text
	caption_panel.show()
	caption_seconds = duration


func tick(dt: float) -> void:
	caption_seconds = maxf(0, caption_seconds - dt)
	if caption_seconds <= 0:
		caption_panel.hide()


func show_notes(visible_now: bool, entries: Array) -> void:
	menu.visible = visible_now
	if not visible_now:
		return
	journal.clear()
	for i in range(entries.size() - 1, maxi(-1, entries.size() - 9), -1):
		var row: Dictionary = entries[i]
		journal.append_text(
			(
				"%02d:%02d  %s\n\n"
				% [int(row["seconds"]) / 60, int(row["seconds"]) % 60, str(row["text"])]
			)
		)


func show_debrief(data: Dictionary) -> void:
	menu.hide()
	result_panel.show()
	result_title.text = "RAVEN TWO / FLIGHT RECORD"
	var duration := int(data["seconds"])
	result_body.text = (
		"[b]%s[/b]\n%s\n\nTIME AIRBORNE     %02d:%02d\nDISTANCE FLOWN   %.2f km\nRADAR FRAMES     %d\nCHART FIXES PASSED  %d\nARM STORES USED  %d\nDEFENSIVE CHARGES %d\nAIRFRAME REMAINING %d%%\nFUEL REMAINING   %d%%\n\nSEED %d\n\n%s"
		% [
			data["phase"],
			data["reason"],
			duration / 60,
			duration % 60,
			float(data["distance_m"]) / 1000.0,
			int(data["scans"]),
			int(data["fixes_passed"]),
			int(data["arm_used"]),
			int(data["countermeasures_used"]),
			int(float(data["integrity"]) * 100),
			int(float(data["fuel"]) * 100),
			int(data["seed"]),
			"No reply from ground control." if data["survived"] else "Aircraft unable to continue."
		]
	)


func blocks_cockpit_input() -> bool:
	return menu.visible or result_panel.visible


func debrief_visible() -> bool:
	return result_panel.visible
