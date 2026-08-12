extends Node3D

## Cue visual and strike model. The cue converts a player stroke into a
## ball impulse at the selected tip offset; it never predicts trajectories.

const TIP_GAP := 0.06
const SHAFT_LENGTH := 6.75
const MAX_PULL_DISTANCE := 1.75
const BALL_RADIUS := 0.142875
const CUE_MASS := 0.54 # kg, typical two-piece playing cue
const BALL_MASS := 0.17 # kg
const TIP_RESTITUTION := 0.72
## A 1.35 power exponent gives the lower half of the input range useful
## touch-shot resolution. With the cue/ball transfer ratio below, 50% power
## launches at 2.71 m/s and full power at 5.89 m/s: a stronger break than the
## former 3.60 m/s ceiling allowed, still well short of the 7.58 m/s blast.
const MIN_CUE_SPEED_MPS := 0.50
const MAX_CUE_SPEED_MPS := 4.50
const POWER_RESPONSE_EXPONENT := 1.35
const WORLD_SCALE := 5.0
const MAX_TIP_OFFSET := 0.88
const POST_IMPACT_HOLD_SECONDS := 0.045
const FADE_OUT_SECONDS := 0.12
## Animated stand-in for a human's live drag (see animate_ai_stroke) - slowed
## well past a real stroke's speed so the AI's shot reads as a deliberate
## swing instead of an instant snap.
const AI_BACKSWING_SECONDS := 0.9
const AI_BACKSWING_HOLD_SECONDS := 0.15
const AI_FORWARD_SWING_SECONDS := 0.5
## No real stroke lands on a mathematically perfect line: grip, tip contact,
## and the stick's own flex all carry a hair of unavoidable wobble. A truly
## zero-error hit collapses a dead-center rack contact into a pure stun (the
## cue's whole tangential velocity survives the impulse), so a sub-millimeter
## line-of-centers offset is enough to turn that into a natural glancing
## deflection instead - without touching restitution/friction, which would
## bring back the "cue rolls forward into the rack" behavior.
const STROKE_JITTER_RADIANS := deg_to_rad(0.05)

## Input and visual lifetime are intentionally separate from ball physics. The
## solver receives the same single impulse as before; these phases only decide
## when the player may change the stroke and when the visual cue is present.
enum InputPhase {
	READY,
	POWERING,
	STRIKING,
	RESOLVING,
}

var cue_ball: RigidBody3D = null
var input_phase: InputPhase = InputPhase.READY
var _locked_aim_direction := Vector3.FORWARD
var _spin_input_active := false
var _suppress_power_phase_change := false
var _post_impact_elapsed := 0.0
var _fade_elapsed := 0.0
var _hidden_for_thinking := false
var _ai_exact_aim_lock := false

var aim_direction := Vector3.FORWARD:
	set(value):
		# Camera aim writes are accepted only before a power or spin drag begins.
		if can_adjust_aim():
			aim_direction = value

var pull_amount := 0.0:
	set(value):
		pull_amount = clampf(value, 0.0, 1.0)
		if not _suppress_power_phase_change and input_phase == InputPhase.READY:
			_lock_aim()
			input_phase = InputPhase.POWERING
var spin_offset := Vector2.ZERO # x: english, y: top/back
var cue_elevation_degrees := 0.0
var last_strike: Dictionary = {}

@onready var mesh_instance: MeshInstance3D = $MeshInstance3D

func _ready() -> void:
	var mesh := CylinderMesh.new()
	mesh.top_radius = 0.03
	mesh.bottom_radius = 0.065
	mesh.height = SHAFT_LENGTH
	mesh.radial_segments = 12
	mesh_instance.mesh = mesh

	var mat := StandardMaterial3D.new()
	var texture_gen := get_node_or_null("/root/TextureGen")
	if texture_gen != null:
		mat.albedo_texture = texture_gen.call("generate_wood_texture")
	mat.roughness = 0.4
	mat.metallic = 0.1
	mesh_instance.set_surface_override_material(0, mat)

func _process(delta: float) -> void:
	if cue_ball == null or cue_ball.pocketed:
		visible = false
		return
	if _hidden_for_thinking:
		visible = false
		return
	if input_phase != InputPhase.RESOLVING:
		_set_cue_visible(true)
	var direction := _strike_direction()
	var pull_distance := pull_amount * MAX_PULL_DISTANCE
	var tip_position := cue_ball.global_position - direction * (BALL_RADIUS + TIP_GAP + pull_distance)
	var butt_position := tip_position - direction * SHAFT_LENGTH
	global_position = (tip_position + butt_position) * 0.5
	global_transform.basis = Basis(Quaternion(Vector3.UP, direction))
	_update_post_impact_visibility(delta)

func can_adjust_aim() -> bool:
	return input_phase == InputPhase.READY and not _spin_input_active


func can_take_shot() -> bool:
	return not _spin_input_active and (input_phase == InputPhase.READY or input_phase == InputPhase.POWERING)


func is_aim_locked() -> bool:
	return not can_adjust_aim()


## True only while a power/spin drag gesture is actively in flight - the
## narrow window where the orbit camera must yield the touch to that gesture.
## Unlike can_adjust_aim(), this stays false through RESOLVING so the camera
## keeps working while the struck balls are still rolling.
func is_shot_gesture_active() -> bool:
	return _spin_input_active or input_phase == InputPhase.POWERING or input_phase == InputPhase.STRIKING


func begin_power_input() -> void:
	if input_phase != InputPhase.READY:
		return
	_lock_aim()
	input_phase = InputPhase.POWERING


func begin_spin_input() -> bool:
	if input_phase != InputPhase.READY or _spin_input_active:
		return false
	# Spin changes should not introduce the tiny stroke jitter used for a fired shot.
	_locked_aim_direction = aim_direction
	_spin_input_active = true
	return true


func end_spin_input() -> void:
	if not _spin_input_active:
		return
	_spin_input_active = false
	_locked_aim_direction = aim_direction


func cancel_shot_input() -> void:
	if input_phase == InputPhase.STRIKING or input_phase == InputPhase.RESOLVING:
		return
	_spin_input_active = false
	_reset_pull_amount()
	input_phase = InputPhase.READY
	_locked_aim_direction = aim_direction
	if cue_ball != null and not cue_ball.pocketed:
		_set_cue_visible(true)


## Hides the cue stick while the AI is "thinking" (planning a shot or placing
## a ball-in-hand cue ball) instead of leaving it resting idle at the table -
## it only reappears for animate_ai_stroke()'s backswing.
func set_hidden_for_thinking(hidden: bool) -> void:
	_hidden_for_thinking = hidden


## Animated stand-in for a human's live power-drag: pulls the cue back to the
## given power's distance, holds briefly, then drives it forward onto the
## ball, entirely through the ordinary pull_amount used by human input so the
## visual matches a real stroke. Leaves the cue aimed and at pull_amount 0,
## ready for take_shot() to fire the actual impulse.
func animate_ai_stroke(power_ratio: float, exact_aim: bool = false) -> void:
	if cue_ball == null or cue_ball.pocketed:
		return
	_ai_exact_aim_lock = exact_aim
	set_hidden_for_thinking(false)
	_reset_pull_amount()
	var target_pull := clampf(power_ratio, 0.0, 1.0)
	var tree := get_tree()
	var backswing := tree.create_tween()
	backswing.tween_property(self, "pull_amount", target_pull, AI_BACKSWING_SECONDS).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	await backswing.finished
	await tree.create_timer(AI_BACKSWING_HOLD_SECONDS).timeout
	var forward_swing := tree.create_tween()
	forward_swing.tween_property(self, "pull_amount", 0.0, AI_FORWARD_SWING_SECONDS).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	await forward_swing.finished


func set_ready_to_shoot() -> void:
	_reset_pull_amount()
	input_phase = InputPhase.READY
	_spin_input_active = false
	_locked_aim_direction = aim_direction
	_ai_exact_aim_lock = false
	_post_impact_elapsed = 0.0
	_fade_elapsed = 0.0
	if cue_ball != null and not cue_ball.pocketed:
		_set_cue_visible(true)


func _lock_aim() -> void:
	if _ai_exact_aim_lock:
		_locked_aim_direction = aim_direction
		return
	var jitter := randf_range(-STROKE_JITTER_RADIANS, STROKE_JITTER_RADIANS)
	_locked_aim_direction = aim_direction.rotated(Vector3.UP, jitter)


func _reset_pull_amount() -> void:
	_suppress_power_phase_change = true
	pull_amount = 0.0
	_suppress_power_phase_change = false


func _set_cue_visible(show: bool) -> void:
	visible = show
	if is_instance_valid(mesh_instance):
		mesh_instance.transparency = 0.0 if show else 1.0


func _update_post_impact_visibility(delta: float) -> void:
	if input_phase == InputPhase.STRIKING:
		_post_impact_elapsed += delta
		if _post_impact_elapsed >= POST_IMPACT_HOLD_SECONDS:
			input_phase = InputPhase.RESOLVING
			_fade_elapsed = 0.0
	elif input_phase == InputPhase.RESOLVING:
		_fade_elapsed += delta
		if is_instance_valid(mesh_instance):
			mesh_instance.transparency = clampf(_fade_elapsed / FADE_OUT_SECONDS, 0.0, 1.0)
		if _fade_elapsed >= FADE_OUT_SECONDS:
			visible = false


func take_shot(power_ratio: float, physics_world: Node = null) -> bool:
	if cue_ball == null or cue_ball.pocketed or not can_take_shot():
		return false
	if input_phase == InputPhase.READY:
		_lock_aim()
		input_phase = InputPhase.POWERING
	var power := clampf(power_ratio, 0.0, 1.0)
	_reset_pull_amount()
	if power < 0.03:
		cancel_shot_input()
		return false

	var strike := predicted_strike(power)
	var tip_offset: Vector3 = strike["tip_offset"]
	# A strike beyond this zone would be a miscue. Reject it instead of applying
	# unrealistically unlimited side-spin.
	if tip_offset.length() > BALL_RADIUS * MAX_TIP_OFFSET:
		cancel_shot_input()
		return false

	var impulse: Vector3 = strike["direction"] * float(strike["transfer_speed"]) * cue_ball.mass
	last_strike = {
		"power": power,
		"cue_speed_mps": cue_speed_mps_for_power(power),
		"direction": strike["direction"],
		"tip_offset": tip_offset,
		"impulse": impulse,
		"elevation_degrees": cue_elevation_degrees,
	}
	# The impact has consumed the selected english. The HUD mirrors this reset
	# immediately after a committed shot so the next turn starts centered.
	spin_offset = Vector2.ZERO
	# This happens before handing the impulse to the solver, so the cue remains
	# present through the actual impact and only fades on later frames.
	input_phase = InputPhase.STRIKING
	_post_impact_elapsed = 0.0
	_fade_elapsed = 0.0
	_set_cue_visible(true)
	if physics_world != null and physics_world.has_method("strike_ball"):
		physics_world.strike_ball(cue_ball, impulse, tip_offset)
	else:
		cue_ball.apply_impulse(impulse, tip_offset)
	return true


## Read-only strike parameters for a given power, at the current aim/spin,
## without applying anything. Shared by take_shot() and the aim-prediction
## guide so the preview always matches the impulse an actual shot would use.
func predicted_strike(power_ratio: float) -> Dictionary:
	var power := clampf(power_ratio, 0.0, 1.0)
	return {
		"direction": _strike_direction(),
		"tip_offset": _tip_offset(),
		"transfer_speed": cue_ball_speed_mps_for_power(power) * WORLD_SCALE,
	}


static func cue_speed_mps_for_power(power_ratio: float) -> float:
	var power := clampf(power_ratio, 0.0, 1.0)
	return lerpf(MIN_CUE_SPEED_MPS, MAX_CUE_SPEED_MPS, pow(power, POWER_RESPONSE_EXPONENT))


static func cue_ball_speed_mps_for_power(power_ratio: float) -> float:
	return cue_speed_mps_for_power(power_ratio) * _cue_to_ball_transfer_ratio()


## Inverse of cue_ball_speed_mps_for_power(): the power ratio whose impulse
## sends the cue ball off the tip at (about) the given speed. Lets a caller
## work backward from "how fast does this ball need to leave the cue" (e.g.
## AIOpponent picking power for a planned shot) instead of only forward from
## an already-chosen power ratio.
static func power_for_cue_ball_speed_mps(speed_mps: float) -> float:
	var cue_speed := speed_mps / _cue_to_ball_transfer_ratio()
	var t := clampf((cue_speed - MIN_CUE_SPEED_MPS) / (MAX_CUE_SPEED_MPS - MIN_CUE_SPEED_MPS), 0.0, 1.0)
	return clampf(pow(t, 1.0 / POWER_RESPONSE_EXPONENT), 0.0, 1.0)


static func _cue_to_ball_transfer_ratio() -> float:
	return (1.0 + TIP_RESTITUTION) * CUE_MASS / (CUE_MASS + BALL_MASS)

func set_elevation(degrees: float) -> void:
	cue_elevation_degrees = clampf(degrees, 0.0, 60.0)

func _strike_direction() -> Vector3:
	var source_direction := _locked_aim_direction if is_aim_locked() else aim_direction
	var horizontal := Vector3(source_direction.x, 0.0, source_direction.z)
	if horizontal.length_squared() < 0.000001:
		horizontal = Vector3.FORWARD
	horizontal = horizontal.normalized()
	return (horizontal * cos(deg_to_rad(cue_elevation_degrees)) + Vector3.UP * sin(deg_to_rad(cue_elevation_degrees))).normalized()

func _tip_offset() -> Vector3:
	var source_direction := _locked_aim_direction if is_aim_locked() else aim_direction
	var horizontal := Vector3(source_direction.x, 0.0, source_direction.z)
	if horizontal.length_squared() < 0.000001:
		horizontal = Vector3.FORWARD
	var right := horizontal.normalized().cross(Vector3.UP).normalized()
	var offset := spin_offset.limit_length(1.0) * (BALL_RADIUS * MAX_TIP_OFFSET)
	return right * offset.x + Vector3.UP * offset.y
