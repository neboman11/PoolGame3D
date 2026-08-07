extends Node3D
## Orbit camera around the cue ball. One-finger / left-drag rotates &
## tilts the view, pinch (or mouse wheel) zooms. The camera's horizontal
## facing direction doubles as the cue's aim direction - purely a control
## mapping, the physics engine still owns the actual shot outcome.

const TABLE_PROFILE := preload("res://scripts/table_profile.gd")

@export var distance: float = 9.0
@export var min_distance: float = 1.6
@export var max_distance: float = 16.0
@export var pitch: float = 38.0
@export var min_pitch: float = 10.0
@export var max_pitch: float = 75.0
@export var birds_eye_height: float = 10.0
@export var birds_eye_margin: float = 3.0

var yaw: float = PI * 0.5   # face down the table's length axis (+X) by default
var target: Node3D = null
var aim_direction: Vector3 = Vector3.FORWARD
var input_enabled: bool = true
var sensitivity_multiplier: float = 1.0

@onready var camera: Camera3D = $Camera3D
@onready var birds_eye_viewport: SubViewport = $BirdsEyeViewport
@onready var birds_eye_camera: Camera3D = $BirdsEyeViewport/BirdsEyeCamera

var _touches: Dictionary = {}
var _pinch_start_dist: float = 0.0
var _pinch_start_zoom: float = 0.0
var _mouse_dragging: bool = false

func _ready() -> void:
	camera.current = true
	camera.fov = 55.0
	birds_eye_camera.current = true
	_place_birds_eye_camera()
	if OS.get_name() == "Android":
		_platform_sensitivity_scale = ANDROID_SENSITIVITY_SCALE


## Fixed top-down shot framing the whole table for the rolling-balls preview,
## set once at startup since the table itself never moves.
func _place_birds_eye_camera() -> void:
	birds_eye_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	var half_length: float = TABLE_PROFILE.PLAYING_SURFACE_LENGTH * 0.5
	var half_width: float = TABLE_PROFILE.PLAYING_SURFACE_WIDTH * 0.5
	birds_eye_camera.size = max(half_length, half_width) * 2.0 + birds_eye_margin
	birds_eye_camera.global_position = Vector3(0.0, birds_eye_height, 0.0)
	birds_eye_camera.look_at(Vector3.ZERO, Vector3.FORWARD)


## Texture the rolling-balls preview widget reads from every frame.
func get_birds_eye_texture() -> Texture2D:
	return birds_eye_viewport.get_texture()


## The birds-eye viewport is a second full 3D render of the table. It costs
## nothing while its HUD panel is hidden (most of every turn, spent aiming),
## so only run it while the preview widget is actually on screen.
func set_birds_eye_active(active: bool) -> void:
	birds_eye_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS if active else SubViewport.UPDATE_DISABLED


## Maps a world-space table point (e.g. a pocket) to a 0..1 fraction within
## the birds-eye preview texture, so the HUD can overlay clickable pocket
## markers without duplicating the top-down camera's framing math.
func get_birds_eye_fraction(world_pos: Vector3) -> Vector2:
	var size: float = max(birds_eye_camera.size, 0.001)
	return Vector2(world_pos.x / size + 0.5, world_pos.z / size + 0.5)


## Disables every orbit-camera gesture as one operation.  Resetting the
## in-progress gesture prevents a drag that started before a power press from
## resuming when camera input is restored.
func set_input_enabled(enabled: bool) -> void:
	if input_enabled == enabled:
		return
	input_enabled = enabled
	if not input_enabled:
		_reset_input_state()


func _reset_input_state() -> void:
	_touches.clear()
	_pinch_start_dist = 0.0
	_pinch_start_zoom = 0.0
	_mouse_dragging = false

func _process(_delta: float) -> void:
	if target == null:
		return
	var focus: Vector3 = target.global_position
	var rad_pitch: float = deg_to_rad(pitch)
	var horiz: float = cos(rad_pitch) * distance
	var vert: float = sin(rad_pitch) * distance
	var offset := Vector3(sin(yaw), 0.0, cos(yaw)) * horiz
	camera.global_position = focus - offset + Vector3(0.0, vert + 0.3, 0.0)
	camera.look_at(focus + Vector3(0.0, 0.15, 0.0), Vector3.UP)
	aim_direction = Vector3(sin(yaw), 0.0, cos(yaw)).normalized()

func _unhandled_input(event: InputEvent) -> void:
	if not input_enabled:
		return

	if event is InputEventScreenTouch:
		if event.pressed:
			_touches[event.index] = event.position
			if _touches.size() == 2:
				_pinch_start_dist = _get_touch_distance()
				_pinch_start_zoom = distance
		else:
			_touches.erase(event.index)
	elif event is InputEventScreenDrag:
		_touches[event.index] = event.position
		if _touches.size() >= 2:
			var d := _get_touch_distance()
			if _pinch_start_dist > 0.001:
				var ratio: float = _pinch_start_dist / max(d, 0.001)
				distance = clamp(_pinch_start_zoom * ratio, min_distance, max_distance)
		elif _touches.size() == 1:
			_apply_drag(event.relative)
	elif event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_RIGHT or event.button_index == MOUSE_BUTTON_LEFT:
			_mouse_dragging = event.pressed
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP:
			distance = clamp(distance - 0.4, min_distance, max_distance)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			distance = clamp(distance + 0.4, min_distance, max_distance)
	elif event is InputEventMouseMotion and _mouse_dragging:
		_apply_drag(event.relative)

## Precision aim toggle: cuts drag sensitivity so long shots aren't at the
## mercy of pixel-sized jumps. It is a deliberate per-shot opt-in (touch has
## no modifier key to hold), so the caller resets it after every shot.
const YAW_SENSITIVITY: float = 0.008
const PITCH_SENSITIVITY: float = 0.15
# Touch drag on a phone screen covers far more pixels per gesture than a
# mouse does, so the same raw sensitivity feels twitchy on Android. Scaled
# down at the source rather than in the user-facing sensitivity setting, so
# that setting's 0.5x-2.0x range still means the same thing on both platforms.
const ANDROID_SENSITIVITY_SCALE: float = 0.55
var precision_aim_factor: float = 0.2
var precision_aim: bool = false
var _platform_sensitivity_scale: float = 1.0

func set_precision_aim(enabled: bool) -> void:
	precision_aim = enabled

func _apply_drag(delta: Vector2) -> void:
	var factor: float = (precision_aim_factor if precision_aim else 1.0) * sensitivity_multiplier * _platform_sensitivity_scale
	yaw -= delta.x * YAW_SENSITIVITY * factor
	pitch = clamp(pitch + delta.y * PITCH_SENSITIVITY * factor, min_pitch, max_pitch)

func _get_touch_distance() -> float:
	var vals: Array = _touches.values()
	if vals.size() < 2:
		return 0.0
	return vals[0].distance_to(vals[1])

## Intersects the camera ray with the cloth plane for ball-in-hand placement.
func table_point_from_screen(screen_position: Vector2, cloth_y: float) -> Variant:
	var origin := camera.project_ray_origin(screen_position)
	var ray := camera.project_ray_normal(screen_position)
	if absf(ray.y) < 0.00001:
		return null
	var distance := (cloth_y - origin.y) / ray.y
	if distance < 0.0:
		return null
	return origin + ray * distance
