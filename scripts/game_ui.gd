extends Control
## In-game HUD: power charge zone, spin (english) pad, status text and
## navigation buttons. Talks directly to the running Game node - it never
## touches ball physics itself, only sets aim/power/spin values that the
## cue stick turns into a single physics impulse.

const TABLE_PROFILE := preload("res://scripts/table_profile.gd")

@onready var status_label: Label = $StatusLabel
@onready var pocketed_label: Label = $PocketedLabel
@onready var menu_button: Button = $MenuButton
@onready var rerack_button: Button = $RerackButton
@onready var aim_guide_button: Button = $AimGuideButton
@onready var precision_button: Button = $PrecisionButton
@onready var power_zone: Control = $PowerZone
@onready var power_fill: ColorRect = $PowerZone/Fill
@onready var spin_pad: Control = $SpinPad
@onready var spin_ball: TextureRect = $SpinPad/PadBg
@onready var spin_dot: Panel = $SpinPad/Dot
@onready var ball_pad: Control = $BallInHandPad
@onready var ball_pad_up: Button = $BallInHandPad/Up
@onready var ball_pad_down: Button = $BallInHandPad/Down
@onready var ball_pad_left: Button = $BallInHandPad/Left
@onready var ball_pad_right: Button = $BallInHandPad/Right
@onready var birds_eye_preview: Panel = $BirdsEyePreview
@onready var birds_eye_texture: TextureRect = $BirdsEyePreview/Texture
@onready var pocket_markers: Control = $BirdsEyePreview/Texture/Markers
@onready var pick_pocket_label: Label = $BirdsEyePreview/PickPocketLabel

var game_ref: Node = null

var _charging := false
var _press_y := 0.0
var _spin_dragging := false
var _pad_up := false
var _pad_down := false
var _pad_left := false
var _pad_right := false
var _eight_call_available := false
var _rolling_preview_visible := false
var _pocket_marker_buttons: Dictionary = {} # pocket id -> Button
var _preview_style_normal: StyleBoxFlat
var _preview_style_alert: StyleBoxFlat

const MARKER_SIZE := 32.0

const EIGHT_BALL_POCKETS := [
	{"label": "Top-right corner", "id": "corner_right_top"},
	{"label": "Top-left corner", "id": "corner_left_top"},
	{"label": "Bottom-right corner", "id": "corner_right_bottom"},
	{"label": "Bottom-left corner", "id": "corner_left_bottom"},
	{"label": "Top side", "id": "side_top"},
	{"label": "Bottom side", "id": "side_bottom"},
]

func setup(game_node: Node) -> void:
	game_ref = game_node
	_refresh_eight_ball_call()
	if game_ref.camera_rig != null and game_ref.camera_rig.has_method("get_birds_eye_texture"):
		birds_eye_texture.texture = game_ref.camera_rig.get_birds_eye_texture()
	_build_pocket_markers()


## Shown while a struck ball is rolling, so players can watch the whole
## table without losing their orbit-camera aim setup underneath it. Also
## kept visible whenever the 8-ball pocket picker is available (see
## _refresh_eight_ball_call), independent of this flag.
func set_birds_eye_preview_visible(shown: bool) -> void:
	_rolling_preview_visible = shown
	_update_preview_visibility()

func _update_preview_visibility() -> void:
	var shown: bool = _rolling_preview_visible or _eight_call_available
	birds_eye_preview.visible = shown
	if game_ref != null and game_ref.camera_rig != null and game_ref.camera_rig.has_method("set_birds_eye_active"):
		game_ref.camera_rig.set_birds_eye_active(shown)


## Power/spin controls only make sense while it's the human's turn to strike;
## hidden while balls are rolling or the AI is taking its shot.
func set_shot_controls_visible(shown: bool) -> void:
	power_zone.visible = shown
	spin_pad.visible = shown

func _ready() -> void:
	_apply_spin_ball_texture()
	_build_preview_alert_styles()
	menu_button.pressed.connect(func(): GameManager.goto_menu())
	rerack_button.pressed.connect(func():
		if game_ref:
			game_ref.rerack()
	)
	aim_guide_button.toggled.connect(func(_pressed: bool):
		if game_ref:
			game_ref.toggle_aim_guide()
	)
	precision_button.toggled.connect(func(pressed: bool):
		if game_ref:
			game_ref.set_precision_aim(pressed)
	)
	power_zone.gui_input.connect(_on_power_gui_input)
	spin_pad.gui_input.connect(_on_spin_gui_input)
	ball_pad_up.button_down.connect(func(): _pad_up = true)
	ball_pad_up.button_up.connect(func(): _pad_up = false)
	ball_pad_down.button_down.connect(func(): _pad_down = true)
	ball_pad_down.button_up.connect(func(): _pad_down = false)
	ball_pad_left.button_down.connect(func(): _pad_left = true)
	ball_pad_left.button_up.connect(func(): _pad_left = false)
	ball_pad_right.button_down.connect(func(): _pad_right = true)
	ball_pad_right.button_up.connect(func(): _pad_right = false)
	GameManager.ball_pocketed.connect(_on_ball_pocketed)
	update_pocketed_label()
	set_status("Drag the power bar to shoot")

func _process(_delta: float) -> void:
	_sync_eight_pocket_highlight()
	# A finished rack owns the status label (for example, "Player 2 wins").
	# Do not replace that result with the ordinary rolling-ball prompt.
	if GameManager.is_game_over():
		pocket_markers.visible = false
		pick_pocket_label.visible = false
		_eight_call_available = false
		_update_preview_visibility()
		return
	# Ball-in-hand placement owns the status label while it's active (turn
	# message vs. the invalid-position warning) - don't stomp it every frame.
	ball_pad.visible = GameManager.ball_in_hand
	# The 8-ball can become callable while the cue ball is still being placed
	# (for example, ball in hand after the opponent's foul on a cleared
	# table), so the picker must stay available alongside the placement pad
	# rather than being hidden for the whole ball-in-hand duration.
	_refresh_eight_ball_call()
	if GameManager.ball_in_hand:
		return
	if game_ref and not _charging:
		if not game_ref.can_shoot():
			set_status("Balls rolling...")
		elif status_label.text == "Balls rolling...":
			set_status("Drag the power bar to shoot")


## Keeps the on-table glowing ring and the preview-window marker in sync
## with whichever pocket is currently called, however it was called (preview
## marker or clicking the pocket directly on the table).
func _sync_eight_pocket_highlight() -> void:
	_update_marker_highlight(GameManager.called_eight_pocket)
	if game_ref == null or game_ref.table == null:
		return
	if game_ref.table.has_method("set_eight_pocket_highlight"):
		game_ref.table.call("set_eight_pocket_highlight", GameManager.called_eight_pocket)

func set_status(text: String) -> void:
	status_label.text = text


func _refresh_eight_ball_call() -> void:
	var can_call := game_ref != null and game_ref.has_method("can_call_eight_pocket") and bool(game_ref.call("can_call_eight_pocket"))
	pocket_markers.visible = can_call
	_eight_call_available = can_call
	_update_preview_visibility()


## Clones the preview panel's base style plus a red-bordered "you still need
## to call a pocket" variant, swapped in by _update_marker_highlight.
func _build_preview_alert_styles() -> void:
	var base := birds_eye_preview.get_theme_stylebox("panel")
	_preview_style_normal = base.duplicate() if base is StyleBoxFlat else StyleBoxFlat.new()
	_preview_style_alert = _preview_style_normal.duplicate()
	_preview_style_alert.border_color = Color(0.95, 0.15, 0.1, 1.0)
	_preview_style_alert.border_width_left = 3
	_preview_style_alert.border_width_top = 3
	_preview_style_alert.border_width_right = 3
	_preview_style_alert.border_width_bottom = 3


## Builds one small clickable marker per pocket over the birds-eye preview
## texture, positioned from the pockets' real table coordinates so they stay
## correct if pocket geometry changes.
func _build_pocket_markers() -> void:
	if game_ref == null or game_ref.camera_rig == null or not game_ref.camera_rig.has_method("get_birds_eye_fraction"):
		return
	var descriptors_by_id: Dictionary = {}
	for descriptor in TABLE_PROFILE.get_pocket_capture_descriptors():
		descriptors_by_id[String(descriptor["id"])] = descriptor
	for pocket in EIGHT_BALL_POCKETS:
		var pocket_id: String = pocket["id"]
		if not descriptors_by_id.has(pocket_id):
			continue
		var world_pos: Vector3 = descriptors_by_id[pocket_id]["position"]
		var fraction: Vector2 = game_ref.camera_rig.call("get_birds_eye_fraction", world_pos)
		var button := Button.new()
		button.text = ""
		button.focus_mode = Control.FOCUS_NONE
		button.tooltip_text = pocket["label"]
		button.custom_minimum_size = Vector2(MARKER_SIZE, MARKER_SIZE)
		button.anchor_left = fraction.x
		button.anchor_right = fraction.x
		button.anchor_top = fraction.y
		button.anchor_bottom = fraction.y
		button.offset_left = -MARKER_SIZE * 0.5
		button.offset_right = MARKER_SIZE * 0.5
		button.offset_top = -MARKER_SIZE * 0.5
		button.offset_bottom = MARKER_SIZE * 0.5
		button.add_theme_stylebox_override("normal", _make_marker_style(false))
		button.add_theme_stylebox_override("hover", _make_marker_style(false, true))
		button.add_theme_stylebox_override("pressed", _make_marker_style(true))
		button.pressed.connect(_on_pocket_marker_pressed.bind(pocket_id))
		pocket_markers.add_child(button)
		_pocket_marker_buttons[pocket_id] = button


## Selected pockets get a fully opaque solid disc so they read clearly
## against the small preview texture; unselected pockets get a faint
## outline so they stay unobtrusive but tappable.
func _make_marker_style(selected: bool, hovered: bool = false) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.corner_radius_top_left = int(MARKER_SIZE)
	style.corner_radius_top_right = int(MARKER_SIZE)
	style.corner_radius_bottom_left = int(MARKER_SIZE)
	style.corner_radius_bottom_right = int(MARKER_SIZE)
	if selected:
		style.bg_color = Color(1.0, 0.82, 0.15, 1.0)
		style.border_color = Color(1.0, 1.0, 1.0, 1.0)
		style.border_width_left = 3
		style.border_width_top = 3
		style.border_width_right = 3
		style.border_width_bottom = 3
	else:
		style.bg_color = Color(1.0, 1.0, 1.0, 0.55 if hovered else 0.25)
		style.border_color = Color(1.0, 1.0, 1.0, 0.9)
		style.border_width_left = 2
		style.border_width_top = 2
		style.border_width_right = 2
		style.border_width_bottom = 2
	return style


## Updates marker styling to match a pocket called from either input path
## (see Game._try_click_eight_pocket for the on-table click path), and keeps
## the preview panel's "pick a pocket" alert in sync with the same state.
func _update_marker_highlight(pocket_id: String) -> void:
	for id in _pocket_marker_buttons:
		var button: Button = _pocket_marker_buttons[id]
		button.add_theme_stylebox_override("normal", _make_marker_style(id == pocket_id))
	var needs_pick := _eight_call_available and pocket_id == ""
	if _preview_style_alert != null:
		birds_eye_preview.add_theme_stylebox_override("panel", _preview_style_alert if needs_pick else _preview_style_normal)
	pick_pocket_label.visible = needs_pick


func _on_pocket_marker_pressed(pocket_id: String) -> void:
	if game_ref == null:
		return
	if GameManager.called_eight_pocket == pocket_id:
		if game_ref.has_method("clear_eight_pocket_call") and bool(game_ref.call("clear_eight_pocket_call")):
			set_status("8-ball pocket call cleared.")
		return
	if not game_ref.has_method("call_eight_pocket"):
		return
	if bool(game_ref.call("call_eight_pocket", pocket_id)):
		set_status("8-ball called: %s" % _pocket_label(pocket_id))


## Syncs the preview marker to a pocket called by clicking it directly on
## the table (see Game._try_click_eight_pocket), so both input paths agree.
func select_called_pocket(pocket_id: String) -> void:
	_update_marker_highlight(pocket_id)
	set_status("8-ball called: %s" % _pocket_label(pocket_id))


func _pocket_label(pocket_id: String) -> String:
	for pocket in EIGHT_BALL_POCKETS:
		if pocket["id"] == pocket_id:
			return str(pocket["label"])
	return pocket_id

func set_aim_guide_pressed(pressed: bool) -> void:
	aim_guide_button.set_pressed_no_signal(pressed)

func reset_precision_aim() -> void:
	precision_button.set_pressed_no_signal(false)
	if game_ref:
		game_ref.set_precision_aim(false)

## On-screen D-pad input for ball-in-hand placement (Android/touch support).
## Combined with keyboard arrows by the caller.
func get_ball_in_hand_input() -> Vector2:
	var dir := Vector2.ZERO
	if _pad_left:
		dir.x -= 1.0
	if _pad_right:
		dir.x += 1.0
	if _pad_up:
		dir.y += 1.0
	if _pad_down:
		dir.y -= 1.0
	return dir

func update_pocketed_label() -> void:
	pocketed_label.text = "Pocketed: %d / %d" % [GameManager.pocketed_balls.size(), GameManager.rack_ball_count()]

func _on_ball_pocketed(_n: int) -> void:
	update_pocketed_label()


func _apply_spin_ball_texture() -> void:
	# The pad is the cue ball's actual procedural albedo, rendered as a lit
	# sphere in 2D. Keeping its source in TextureGen prevents the controller
	# from drifting to a different white or fabric-like texture.
	var texture_gen := get_node_or_null("/root/TextureGen")
	if texture_gen != null:
		spin_ball.texture = texture_gen.call("get_spin_selector_texture")

## ------------------------------------------------------------------
## Power zone: press near the bottom, drag up to charge, release to fire.
## ------------------------------------------------------------------

func _on_power_gui_input(event: InputEvent) -> void:
	if event is InputEventScreenTouch or event is InputEventMouseButton:
		if event.pressed:
			if game_ref == null or not game_ref.begin_power_input():
				return
			_charging = true
			_press_y = event.position.y
			_update_power_fill(0.0)
		elif _charging:
			_charging = false
			var ratio: float = _ratio_from_y(event.position.y)
			_update_power_fill(0.0)
			if game_ref:
				game_ref.attempt_shot(ratio)
	elif (event is InputEventScreenDrag or event is InputEventMouseMotion) and _charging:
		var ratio: float = _ratio_from_y(event.position.y)
		_update_power_fill(ratio)
		if game_ref and game_ref.cue_stick:
			game_ref.cue_stick.pull_amount = ratio

func _ratio_from_y(y: float) -> float:
	var h: float = max(power_zone.size.y, 1.0)
	return clamp((_press_y - y) / h, 0.0, 1.0)

func _update_power_fill(ratio: float) -> void:
	power_fill.anchor_top = 1.0 - ratio
	power_fill.offset_top = 0.0

## ------------------------------------------------------------------
## Spin pad: drag the dot within the circle to set english / top-back spin.
## ------------------------------------------------------------------

func _on_spin_gui_input(event: InputEvent) -> void:
	if event is InputEventScreenTouch or event is InputEventMouseButton:
		if event.pressed:
			if game_ref == null or not game_ref.begin_spin_input():
				return
			_spin_dragging = true
			_update_spin(event.position)
		elif _spin_dragging:
			_spin_dragging = false
			if game_ref:
				game_ref.end_spin_input()
	elif (event is InputEventScreenDrag or event is InputEventMouseMotion) and _spin_dragging:
		_update_spin(event.position)

func _update_spin(local_pos: Vector2) -> void:
	var center: Vector2 = spin_pad.size * 0.5
	var offset: Vector2 = (local_pos - center) / (spin_pad.size * 0.5)
	if offset.length() > 1.0:
		offset = offset.normalized()
	var ball_radius := minf(spin_pad.size.x, spin_pad.size.y) * 0.5
	var marker_radius := maxf(spin_dot.size.x, spin_dot.size.y) * 0.5
	spin_dot.position = center + offset * maxf(0.0, ball_radius - marker_radius) - spin_dot.size * 0.5
	if game_ref and game_ref.cue_stick:
		game_ref.cue_stick.spin_offset = Vector2(offset.x, -offset.y)


func reset_spin_selection() -> void:
	_spin_dragging = false
	var center := spin_pad.size * 0.5
	spin_dot.position = center - spin_dot.size * 0.5
	if game_ref and game_ref.cue_stick:
		game_ref.cue_stick.spin_offset = Vector2.ZERO
