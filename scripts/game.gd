extends Node3D

## Match orchestration: it owns rack setup and translates solver events into
## rules/UI state. BilliardsPhysics owns every moving-ball calculation.

const BALL_SCENE := preload("res://scenes/Ball.tscn")
const PHYSICS_SCENE := preload("res://scripts/billiards_physics.gd")
const SHOT_RECORDER := preload("res://scripts/shot_recorder.gd")
const TABLE_PROFILE := preload("res://scripts/table_profile.gd")
const AI_OPPONENT := preload("res://scripts/ai_opponent.gd")
const CUE_STICK_SCRIPT := preload("res://scripts/cue_stick.gd")
const BALL_RADIUS := 0.142875
const BALL_DIAMETER := BALL_RADIUS * 2.0
const CUE_BALL_MOVE_SPEED := 3.0 # world units/sec while placing ball in hand
const CUE_BALL_PRECISION_SPEED_FACTOR := 0.8 # precision toggle: 20% slower
## Bank-shot aim correction: how many secant-search shadow simulations to run
## per bank shot, and the step used to bracket the first pair of guesses.
const AI_BANK_REFINE_ITERATIONS := 5
const AI_BANK_REFINE_ANGLE_STEP_DEG := 2.0
const AI_BANK_REFINE_MAX_STEPS := 900
const AI_BANK_REFINE_TOLERANCE := 0.01
## Real cushion throw can be large enough that the idealized aim whiffs the
## target ball outright, leaving the secant search with no local gradient to
## follow. This coarse sweep (tried once, only if the idealized angle itself
## misses) finds any angle that actually reaches the target ball to seed it.
const AI_BANK_BRACKET_RANGE_DEG := 30.0
const AI_BANK_BRACKET_STEP_DEG := 5.0
## Position-play / defensive-play read-ahead: how long the shadow solver is
## allowed to run a struck shot forward before giving up on it settling. Most
## real shots settle in a fraction of this; it is only a safety cap.
const AI_OUTCOME_SIM_MAX_STEPS := 1500
## Target object-ball speed (m/s) on arrival at the pocket: enough to drop
## with confidence rather than die on the lip, not so much it rattles out.
const AI_POT_ARRIVAL_SPEED_MPS := 0.35
const EIGHT_BALL_RACK_LAYOUT := [
	[1], [9, 2], [10, 8, 3], [4, 11, 5, 15], [12, 6, 14, 7, 13],
]
const NINE_BALL_RACK_LAYOUT := [
	[1], [2, 3], [4, 9, 5], [6, 7], [8],
]

@onready var table: Node3D = $Table
@onready var camera_rig: Node3D = $CameraRig
@onready var cue_stick: Node3D = $CueStick
@onready var balls_root: Node3D = $Balls
@onready var aim_guide: Node3D = $AimGuide
@onready var hud: Control = $HUD

var cue_ball: RigidBody3D = null
var balls: Array[RigidBody3D] = []
var physics_world: Node = null
var shot_in_progress := false
var shot_recorder := SHOT_RECORDER.new()
var ai_turn_active := false
var _ai_rng := RandomNumberGenerator.new()
var _ball_in_hand_valid := true
# Disposable, off-tree physics clone used only to correct bank-shot aim
# against real cushion friction before a bank shot is actually struck. See
# _refine_bank_direction.
var _ai_shadow: BilliardsPhysics = null
var _ai_shadow_contact: Array = []
var _ai_shadow_pocketed: Array = []
# Shot planning and ball-in-hand placement both re-simulate several candidate
# shots on the shadow solver, which is slow enough to freeze a frame if run
# inline. Both instead run on a WorkerThreadPool task (same off-thread pattern
# as aim_guide.gd's _run_prediction) so the camera keeps responding while the
# AI "thinks". Only one of these may be in flight at a time - _run_ai_turn
# always awaits one before starting the next.
var _ai_pending_plan: Dictionary = {}
var _ai_pending_cue_position: Vector3 = Vector3.ZERO
var _ai_task_id := -1

func _ready() -> void:
	GameManager.register_game(self)
	hud.setup(self)
	aim_guide.setup(self)
	aim_guide.enabled = Settings.aim_guide_default
	hud.set_aim_guide_pressed(Settings.aim_guide_default)
	camera_rig.sensitivity_multiplier = Settings.camera_sensitivity
	camera_rig.precision_aim_factor = Settings.precision_aim_sensitivity
	_ai_rng.randomize()
	_create_physics_world()
	rerack()
	GameManager.shot_resolved.connect(_on_shot_resolved)
	_sync_camera_input_with_cue_state()

func _exit_tree() -> void:
	if _ai_task_id != -1 and not WorkerThreadPool.is_task_completed(_ai_task_id):
		WorkerThreadPool.wait_for_task_completion(_ai_task_id)
	if _ai_shadow != null:
		_ai_shadow.free()
		_ai_shadow = null

func _process(delta: float) -> void:
	_sync_camera_input_with_cue_state()
	hud.set_shot_controls_visible(not shot_in_progress and not ai_turn_active)
	if GameManager.ball_in_hand and not ai_turn_active:
		_process_ball_in_hand_movement(delta)
	if not GameManager.is_game_over() and cue_stick.can_adjust_aim():
		cue_stick.aim_direction = camera_rig.aim_direction


## The camera only yields to the cue's power/spin drag gesture itself - it
## stays free to orbit while the struck balls roll and during the AI's turn,
## so the player can always look around the table.
func begin_power_input() -> bool:
	if ai_turn_active or not can_shoot():
		return false
	if GameManager.ball_in_hand:
		_finalize_ball_in_hand_placement()
	cue_stick.begin_power_input()
	_sync_camera_input_with_cue_state()
	return true


func begin_spin_input() -> bool:
	if ai_turn_active or not can_shoot():
		return false
	var accepted: bool = cue_stick.begin_spin_input()
	_sync_camera_input_with_cue_state()
	return accepted


func end_spin_input() -> void:
	cue_stick.end_spin_input()
	_sync_camera_input_with_cue_state()


func _sync_camera_input_with_cue_state() -> void:
	if camera_rig == null or cue_stick == null:
		return
	if camera_rig.has_method("set_input_enabled"):
		camera_rig.set_input_enabled(
			not GameManager.is_game_over() and not cue_stick.is_shot_gesture_active()
		)

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_try_click_eight_pocket(event.position)
	elif event is InputEventScreenTouch and event.pressed:
		_try_click_eight_pocket(event.position)
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	if event.keycode == KEY_Q:
		cue_stick.set_elevation(cue_stick.cue_elevation_degrees - 2.0)
	elif event.keycode == KEY_E:
		cue_stick.set_elevation(cue_stick.cue_elevation_degrees + 2.0)
	if event.keycode == KEY_Q or event.keycode == KEY_E:
		hud.set_status("Cue elevation: %.0f°" % cue_stick.cue_elevation_degrees)
	elif event.keycode == KEY_G:
		hud.set_status("Aim guide: %s" % ("on" if toggle_aim_guide() else "off"))

func toggle_aim_guide() -> bool:
	var is_enabled: bool = aim_guide.toggle()
	hud.set_aim_guide_pressed(is_enabled)
	return is_enabled

func set_precision_aim(enabled: bool) -> void:
	if camera_rig.has_method("set_precision_aim"):
		camera_rig.set_precision_aim(enabled)

## Continuously drives the cue ball with arrow-key input while ball in hand
## is active. Movement is unrestricted through other balls (the ball is a
## transparent "ghost" and not registered with the solver yet); it can only
## be blocked from leaving the cloth or entering a pocket.
func _process_ball_in_hand_movement(delta: float) -> void:
	if cue_ball == null:
		return
	var input_dir := Vector2.ZERO
	if Input.is_key_pressed(KEY_LEFT):
		input_dir.x -= 1.0
	if Input.is_key_pressed(KEY_RIGHT):
		input_dir.x += 1.0
	if Input.is_key_pressed(KEY_UP):
		input_dir.y += 1.0
	if Input.is_key_pressed(KEY_DOWN):
		input_dir.y -= 1.0
	if hud.has_method("get_ball_in_hand_input"):
		input_dir += hud.get_ball_in_hand_input()
	if input_dir != Vector2.ZERO:
		input_dir = input_dir.normalized()
		var forward: Vector3 = camera_rig.aim_direction
		var right := Vector3(-forward.z, 0.0, forward.x)
		var speed: float = CUE_BALL_MOVE_SPEED
		if camera_rig.precision_aim:
			speed *= CUE_BALL_PRECISION_SPEED_FACTOR
		var movement: Vector3 = (right * input_dir.x + forward * input_dir.y) * speed * delta
		cue_ball.global_position = _clamped_cloth_position(cue_ball.global_position, cue_ball.global_position + movement)
	_update_ball_in_hand_validity()

## Slides the move along whichever axis stays on the cloth so the ball hugs
## the rail/pocket boundary instead of simply refusing diagonal motion there.
func _clamped_cloth_position(from: Vector3, to: Vector3) -> Vector3:
	if _on_cloth_bounds(to):
		return to
	var slide_x := Vector3(to.x, to.y, from.z)
	if _on_cloth_bounds(slide_x):
		return slide_x
	var slide_z := Vector3(from.x, to.y, to.z)
	if _on_cloth_bounds(slide_z):
		return slide_z
	return from

func _on_cloth_bounds(position: Vector3) -> bool:
	if table.has_method("is_position_on_cloth"):
		return table.is_position_on_cloth(position, BALL_RADIUS)
	return true

func _cue_ball_overlaps_other_ball(position: Vector3) -> bool:
	for ball in balls:
		if ball != cue_ball and is_instance_valid(ball) and not ball.pocketed:
			if ball.global_position.distance_to(position) < BALL_DIAMETER:
				return true
	return false

func _update_ball_in_hand_validity() -> void:
	if cue_ball == null:
		return
	var was_valid := _ball_in_hand_valid
	_ball_in_hand_valid = not _cue_ball_overlaps_other_ball(cue_ball.global_position)
	if _ball_in_hand_valid == was_valid:
		return
	if _ball_in_hand_valid:
		hud.set_status("Ball in hand — move with arrow keys, then shoot.")
	else:
		hud.set_status("Invalid position — cue ball overlaps another ball. Move it clear before shooting.")

func _finalize_ball_in_hand_placement() -> void:
	if cue_ball == null:
		return
	cue_ball.set_ghost_placement(false)
	if physics_world != null and physics_world.has_method("restore_ball"):
		physics_world.restore_ball(cue_ball, cue_ball.global_position)
	GameManager.ball_in_hand = false
	hud.set_status("%s — drag power to shoot" % GameManager.turn_label())

func can_shoot() -> bool:
	if not GameManager.can_begin_shot():
		return false
	if cue_ball == null or shot_in_progress:
		return false
	if GameManager.ball_in_hand and not _ball_in_hand_valid:
		return false
	if not cue_stick.can_take_shot():
		return false
	return physics_world == null or physics_world.is_settled()

func any_ball_moving() -> bool:
	return not can_shoot()

func attempt_shot(power_ratio: float) -> void:
	if not can_shoot():
		cue_stick.cancel_shot_input()
		_sync_camera_input_with_cue_state()
		return
	var initial_snapshot: Dictionary = physics_world.snapshot() if physics_world != null else {}
	if cue_stick.take_shot(power_ratio, physics_world):
		if not GameManager.begin_shot():
			cue_stick.cancel_shot_input()
			_sync_camera_input_with_cue_state()
			return
		shot_in_progress = true
		hud.reset_spin_selection()
		hud.reset_precision_aim()
		shot_recorder.begin(initial_snapshot, cue_stick.last_strike)
		hud.set_birds_eye_preview_visible(true)
	_sync_camera_input_with_cue_state()

func rerack() -> void:
	if physics_world != null:
		physics_world.unregister_all()
	for ball in balls:
		if is_instance_valid(ball):
			ball.queue_free()
	balls.clear()
	GameManager.reset_state()
	shot_in_progress = false
	shot_recorder.cancel()
	hud.set_birds_eye_preview_visible(false)

	var head_spot := _head_spot()
	cue_ball = _spawn_ball(0, head_spot)
	var apex := _rack_apex()
	var row_dx := TABLE_PROFILE.get_rack_row_advance()
	var ball_dz := TABLE_PROFILE.get_rack_lateral_ball_spacing()
	var rack_layout: Array = NINE_BALL_RACK_LAYOUT if GameManager.game_type == GameManager.GameType.NINE_BALL else EIGHT_BALL_RACK_LAYOUT
	var rack_positions: Array[Vector3] = []
	var rack_numbers: Array[int] = []
	for row_index in rack_layout.size():
		var row: Array = rack_layout[row_index]
		var x := apex.x + row_index * row_dx
		for index in row.size():
			var z := apex.z + (index - (row.size() - 1) / 2.0) * ball_dz
			rack_numbers.append(row[index])
			rack_positions.append(Vector3(x, BALL_RADIUS + 0.0025, z))
	_loosen_rack_positions(rack_positions)
	for i in rack_positions.size():
		_spawn_ball(rack_numbers[i], rack_positions[i])

	cue_stick.cue_ball = cue_ball
	cue_stick.set_ready_to_shoot()
	_sync_camera_input_with_cue_state()
	camera_rig.target = cue_ball
	hud.update_pocketed_label()
	hud.set_status("%s — drag power to shoot" % GameManager.turn_label())

## Nudges each racked ball off its perfect touching position by a small random
## amount, scaled by Settings.rack_tightness, then separates any balls that
## end up overlapping. Mirrors how a real rack is never laser-perfect.
func _loosen_rack_positions(positions: Array[Vector3]) -> void:
	if Settings.rack_tightness <= 0.0:
		return
	var jitter := BALL_RADIUS * 0.35 * Settings.rack_tightness
	for i in positions.size():
		positions[i].x += _ai_rng.randf_range(-jitter, jitter)
		positions[i].z += _ai_rng.randf_range(-jitter, jitter)
	_separate_rack_overlaps(positions)

## Pairwise push-apart pass so jittered rack balls never spawn interpenetrating.
func _separate_rack_overlaps(positions: Array[Vector3]) -> void:
	var min_dist := BALL_DIAMETER + 0.0015
	for _iteration in 8:
		var settled := true
		for i in positions.size():
			for j in range(i + 1, positions.size()):
				var delta := positions[j] - positions[i]
				delta.y = 0.0
				var dist := delta.length()
				if dist < min_dist:
					settled = false
					var dir := delta / dist if dist > 0.0001 else Vector3.RIGHT
					var push := (min_dist - dist) * 0.5
					positions[i] -= dir * push
					positions[j] += dir * push
		if settled:
			break

func place_cue_ball(position: Vector3) -> bool:
	if not GameManager.ball_in_hand or cue_ball == null or not _valid_cue_position(position):
		return false
	cue_ball.reset_to(position)
	if physics_world != null and physics_world.has_method("restore_ball"):
		physics_world.restore_ball(cue_ball, position)
	GameManager.ball_in_hand = false
	cue_stick.set_ready_to_shoot()
	_sync_camera_input_with_cue_state()
	hud.set_status("Cue ball placed — %s" % GameManager.turn_label())
	return true

func _create_physics_world() -> void:
	physics_world = PHYSICS_SCENE.new()
	physics_world.name = "BilliardsPhysics"
	add_child(physics_world)
	var descriptors: Variant = []
	if table.has_method("get_physics_descriptors"):
		descriptors = table.get_physics_descriptors()
	var physics_config: Dictionary = {"descriptors": descriptors}
	if table.has_method("get_table_calibration"):
		physics_config = table.get_table_calibration().duplicate()
		physics_config["descriptors"] = descriptors
	physics_world.configure(physics_config)
	physics_world.ball_pocketed.connect(_on_solver_pocketed)
	physics_world.ball_entered_pocket.connect(_on_solver_ball_entered_pocket)
	physics_world.balls_settled.connect(_on_solver_settled)
	physics_world.ball_contacted.connect(_on_solver_ball_contacted)
	physics_world.ball_hit_cushion.connect(_on_solver_cushion)

func _spawn_ball(number: int, position: Vector3) -> RigidBody3D:
	var ball: RigidBody3D = BALL_SCENE.instantiate()
	ball.ball_number = number
	balls_root.add_child(ball)
	ball.global_position = position
	balls.append(ball)
	physics_world.register_ball(ball)
	return ball

func _on_solver_pocketed(ball: RigidBody3D) -> void:
	if is_instance_valid(ball):
		shot_recorder.record_event("pocket", {"ball": ball.ball_number})
		if not ball.pocketed:
			ball.pocket()


func _on_solver_ball_entered_pocket(ball: RigidBody3D, pocket_id: String) -> void:
	if is_instance_valid(ball):
		GameManager.on_ball_entered_pocket(ball, pocket_id)

func _on_solver_cushion(ball: RigidBody3D, _cushion_id: String) -> void:
	if is_instance_valid(ball):
		shot_recorder.record_event("cushion", {"ball": ball.ball_number, "cushion": _cushion_id})
		GameManager.on_ball_hit_cushion(ball.ball_number)

func _on_solver_ball_contacted(first: Variant, second: Variant) -> void:
	var first_number := _ball_number(first)
	var second_number := _ball_number(second)
	shot_recorder.record_event("ball_contact", {"first": first_number, "second": second_number})
	GameManager.on_ball_contacted(first_number, second_number)

func _ball_number(value: Variant) -> int:
	if value is BilliardsBall:
		return value.ball_number
	if value is int:
		return value
	return -1

func _on_solver_settled() -> void:
	if not shot_in_progress:
		return
	shot_in_progress = false
	hud.set_birds_eye_preview_visible(false)
	var result := GameManager.settle_shot(_remaining_object_ball_numbers())
	_respot_balls(result.get("respot", []))
	if physics_world != null:
		shot_recorder.complete(physics_world.snapshot(), result)
	if GameManager.is_game_over():
		cue_stick.cancel_shot_input()
	else:
		cue_stick.set_ready_to_shoot()
	_sync_camera_input_with_cue_state()

func _on_shot_resolved(result: Dictionary) -> void:
	var ball_in_hand := bool(result.get("ball_in_hand", false))
	if ball_in_hand:
		_restore_cue_ball_for_ball_in_hand()
	var message: String = result.get("message", "")
	var status := "%s %s" % [GameManager.turn_label(), message]
	if ball_in_hand:
		if _ball_in_hand_valid:
			status = "Ball in hand — use arrow keys to move the ball, then shoot. %s" % status
		else:
			status = "Invalid position — cue ball overlaps another ball. Move it clear before shooting."
	hud.set_status(status)
	hud.update_pocketed_label()
	_maybe_start_ai_turn()


## ------------------------------------------------------------------
## AI opponent: same public surface a human uses (aim_direction, power,
## place_cue_ball) so the solver and rules see an ordinary shot.
## ------------------------------------------------------------------

func _maybe_start_ai_turn() -> void:
	if not GameManager.vs_ai or ai_turn_active:
		return
	if GameManager.is_game_over():
		return
	if GameManager.rules.current_player != GameManager.AI_PLAYER_INDEX:
		return
	if shot_in_progress or physics_world == null or not physics_world.is_settled():
		return
	ai_turn_active = true
	_sync_camera_input_with_cue_state()
	_run_ai_turn()

func _run_ai_turn() -> void:
	if GameManager.ball_in_hand:
		hud.set_status("%s — placing ball in hand..." % GameManager.turn_label())
		await get_tree().create_timer(0.6).timeout
		await _ai_place_cue_ball()
	hud.set_status("%s — thinking..." % GameManager.turn_label())
	var min_delay: SceneTreeTimer = get_tree().create_timer(randf_range(0.7, 1.3))
	var plan: Dictionary = await _ai_plan_shot()
	if min_delay.time_left > 0.0:
		await min_delay.timeout
	_ai_apply_shot(plan)
	ai_turn_active = false
	_sync_camera_input_with_cue_state()

## Polls a WorkerThreadPool task to completion a frame at a time instead of
## blocking, so callers can `await` it without stalling the main thread (and
## with it, camera input) for however long the task takes.
func _await_ai_task(task_id: int) -> void:
	while not WorkerThreadPool.is_task_completed(task_id):
		await get_tree().process_frame
	WorkerThreadPool.wait_for_task_completion(task_id)

func _ai_plan_shot() -> Dictionary:
	if cue_ball == null or not can_shoot():
		return {}
	_ensure_ai_shadow()
	var context: Dictionary = _ai_build_context(cue_ball.global_position)
	_ai_pending_plan = {}
	_ai_task_id = WorkerThreadPool.add_task(_run_ai_plan_task.bind(context))
	await _await_ai_task(_ai_task_id)
	return _ai_pending_plan

func _run_ai_plan_task(context: Dictionary) -> void:
	_ai_pending_plan = AI_OPPONENT.plan_shot(context)

func _ai_apply_shot(plan: Dictionary) -> void:
	if plan.is_empty() or cue_ball == null or not can_shoot():
		return
	cue_stick.aim_direction = plan["direction"]
	cue_stick.spin_offset = Vector2.ZERO
	if int(plan.get("target_ball", -1)) == 8:
		GameManager.call_eight_pocket(str(plan.get("pocket_id", "")))
	attempt_shot(plan["power"])

func _ai_place_cue_ball() -> void:
	if cue_ball == null:
		return
	var candidates: Array = []
	for _attempt in 28:
		var candidate: Variant = _random_valid_cue_position()
		if candidate != null:
			candidates.append(candidate)
	if candidates.is_empty():
		place_cue_ball(_head_spot())
		return
	_ai_pending_cue_position = _head_spot()
	_ai_task_id = WorkerThreadPool.add_task(_run_ai_cue_placement_task.bind(candidates))
	await _await_ai_task(_ai_task_id)
	place_cue_ball(_ai_pending_cue_position)

func _run_ai_cue_placement_task(candidates: Array) -> void:
	var best_position: Vector3 = _head_spot()
	var best_score := -INF
	for candidate in candidates:
		var score: float = AI_OPPONENT.best_score(_ai_build_context(candidate))
		if score > best_score:
			best_score = score
			best_position = candidate
	_ai_pending_cue_position = best_position

func _random_valid_cue_position() -> Variant:
	var half_length: float = TABLE_PROFILE.PLAYING_SURFACE_LENGTH * 0.5 - BALL_RADIUS * 1.3
	var half_width: float = TABLE_PROFILE.PLAYING_SURFACE_WIDTH * 0.5 - BALL_RADIUS * 1.3
	var point := Vector3(randf_range(-half_length, half_length), BALL_RADIUS + 0.0025, randf_range(-half_width, half_width))
	return point if _valid_cue_position(point) else null

func _ai_build_context(cue_position: Vector3) -> Dictionary:
	var ball_infos: Array = []
	var remaining_numbers: Array[int] = []
	for ball in balls:
		if is_instance_valid(ball) and not ball.pocketed and ball.ball_number != 0:
			ball_infos.append({"number": ball.ball_number, "position": ball.global_position})
			remaining_numbers.append(ball.ball_number)
	return {
		"cue_position": cue_position,
		"balls": ball_infos,
		"pockets": TABLE_PROFILE.get_pocket_capture_descriptors(),
		"legal_numbers": GameManager.rules.legal_targets(remaining_numbers),
		"difficulty": GameManager.ai_difficulty,
		"rng": _ai_rng,
		# The half extents a ball's *center* actually reflects off, not the
		# nominal cloth rectangle: the rendered cushion nose overhangs the
		# cloth edge by RENDERED_CUSHION_NOSE_OUTSET_X/Z, and AIOpponent
		# accounts for the ball's own radius on top of this. Handing it the
		# bare cloth half-width here would aim every bank at a cushion plane
		# noticeably short of where the ball actually bounces.
		"table_bounds": {
			"half_length": TABLE_PROFILE.PLAYING_SURFACE_LENGTH * 0.5 + TABLE_PROFILE.RENDERED_CUSHION_NOSE_OUTSET_X,
			"half_width": TABLE_PROFILE.PLAYING_SURFACE_WIDTH * 0.5 + TABLE_PROFILE.RENDERED_CUSHION_NOSE_OUTSET_Z,
		},
		"bank_refiner": _refine_bank_direction,
		"shot_outcome": _ai_shot_outcome,
		"power_for_shot": _ai_power_for_shot,
	}


## AIOpponent's "power_for_shot" context callable. Works backward from real
## rolling-friction deceleration to how fast the cue ball must leave the tip:
## enough to survive the approach leg and still send the object ball across
## its own leg(s) to the pocket at a confident arrival speed, rather than the
## flat "further pot = more power" guess AIOpponent falls back to without one.
## Ghost-ball geometry only gives the object ball roughly cos(cut angle) of
## the cue ball's speed at contact, so a thin cut needs noticeably more pace
## than a straight-in shot of the same length to arrive with the same energy.
func _ai_power_for_shot(shot: Dictionary) -> float:
	var calibration: Dictionary = TABLE_PROFILE.get_calibration()
	var slide_friction: float = float(calibration["sliding_friction"])
	var roll_friction: float = float(calibration["rolling_friction"])
	var gravity: float = float(calibration["gravity"])
	var arrival_speed: float = AI_POT_ARRIVAL_SPEED_MPS * CUE_STICK_SCRIPT.WORLD_SCALE
	var approach_distance: float = maxf(float(shot.get("approach_distance", 0.0)), 0.0)

	var launch_speed_needed: float
	if bool(shot.get("is_combo", false)):
		# Two chained transfers, worked out back to front: the assist ball
		# needs arrival_speed at the pocket after its own leg's friction, the
		# primary ball needs enough contact speed to hand it that at
		# cos(transfer angle), and the cue ball needs enough contact speed
		# with the primary ball to hand *that* on at cos(the cue's own cut
		# angle onto the primary) -- a cut cue-to-primary shot loses speed
		# here even before the primary/assist transfer does.
		var assist_leg: float = maxf(float(shot.get("assist_leg_distance", 0.0)), 0.0)
		var primary_leg: float = maxf(float(shot.get("primary_leg_distance", 0.0)), 0.0)
		var transfer_cut_factor: float = maxf(cos(deg_to_rad(float(shot.get("cut_angle_deg", 0.0)))), 0.2)
		var primary_cut_factor: float = maxf(cos(deg_to_rad(float(shot.get("primary_cut_angle_deg", 0.0)))), 0.2)

		var assist_launch_needed: float = _launch_speed_for_leg(arrival_speed, assist_leg, slide_friction, roll_friction, gravity)
		var primary_contact_needed: float = assist_launch_needed / transfer_cut_factor
		var primary_launch_needed: float = _launch_speed_for_leg(primary_contact_needed, primary_leg, slide_friction, roll_friction, gravity)
		var cue_contact_needed: float = primary_launch_needed / primary_cut_factor
		launch_speed_needed = _launch_speed_for_leg(cue_contact_needed, approach_distance, slide_friction, roll_friction, gravity)
	else:
		var cut_factor: float = maxf(cos(deg_to_rad(float(shot.get("cut_angle_deg", 0.0)))), 0.2)
		var pot_distance: float = maxf(float(shot.get("pot_distance", shot.get("travel_distance", 0.0))), 0.0)
		var contact_speed_needed: float = _launch_speed_for_leg(arrival_speed, pot_distance, slide_friction, roll_friction, gravity) / cut_factor
		launch_speed_needed = _launch_speed_for_leg(contact_speed_needed, approach_distance, slide_friction, roll_friction, gravity)

		if bool(shot.get("is_bank", false)):
			# The friction-distance model above has no notion of the cushion
			# itself eating speed. Each bounce reflects the incoming
			# velocity's component along the cushion normal at only
			# cushion_restitution, while the tangential (along-the-rail)
			# component survives close to intact -- so a near-head-on bounce
			# costs far more pace than a grazing one. Divide the launch speed
			# up by each bounce's actual retention instead of a flat
			# per-rail guess.
			var restitution: float = float(calibration["cushion_restitution"])
			var retention := 1.0
			for incidence_degrees in shot.get("bank_incidence_degrees", []):
				var theta := deg_to_rad(float(incidence_degrees))
				retention *= sqrt(pow(sin(theta), 2.0) + pow(restitution * cos(theta), 2.0))
			launch_speed_needed /= maxf(retention, 0.15)

	var cue_ball_speed_mps: float = launch_speed_needed / CUE_STICK_SCRIPT.WORLD_SCALE
	return CUE_STICK_SCRIPT.power_for_cue_ball_speed_mps(cue_ball_speed_mps)


## Every leg of a shot -- the cue ball's own run to contact, and each object
## ball's run after being struck -- starts with zero spin: a stun transfer
## along the line of centers, same as a plain center-ball cue strike, carries
## no rotation with it. A freshly launched ball like that skids under the
## much higher slide_friction until its rotation catches up to its
## translation (natural roll), then decelerates at the far gentler
## roll_friction for whatever distance remains. Solving with roll_friction
## alone -- as if the whole leg were already rolling -- understates the
## launch speed a leg needs by a wide margin whenever the skid phase covers
## a meaningful fraction of it, which is most real shot distances on this
## table. Returns the launch speed this leg needs to still be moving at
## end_speed after covering distance, accounting for both phases.
func _launch_speed_for_leg(end_speed: float, distance: float, slide_friction: float, roll_friction: float, gravity: float) -> float:
	if distance <= 0.0:
		return end_speed
	var slide_decel: float = maxf(slide_friction * gravity, 0.000001)
	var roll_decel: float = roll_friction * gravity

	# If the ball is still skidding when it reaches the end of this leg, the
	# whole distance decelerates at slide_friction alone.
	var skid_only_launch: float = sqrt(end_speed * end_speed + 2.0 * slide_decel * distance)
	# Classic billiards skid-to-roll result for a solid sphere struck with no
	# spin: it reaches natural roll (5/7 of launch speed) after covering
	# (12/49) * v0^2 / (slide_friction * gravity).
	var skid_distance_for_launch: float = (12.0 / 49.0) * skid_only_launch * skid_only_launch / slide_decel
	if skid_distance_for_launch >= distance:
		return skid_only_launch

	# Otherwise it transitions to natural roll partway through the leg, then
	# only decelerates at roll_friction for the rest.
	var transition_factor: float = (25.0 * slide_friction + 24.0 * roll_friction) / (49.0 * maxf(slide_friction, 0.000001))
	return sqrt((end_speed * end_speed + 2.0 * roll_decel * distance) / maxf(transition_factor, 0.000001))


## AIOpponent's bank candidates are read off an idealized mirror reflection
## off the cushion. Real cushions add friction (see BilliardsPhysics's
## _resolve_static_contact) that throws a rolling ball's rebound away from
## that ideal angle, so a bank aimed purely at the geometry misses. This
## nudges the pre-jitter launch angle with a secant search against a
## disposable physics clone until the simulated first contact with the
## target ball actually lands on the intended ghost-ball spot; difficulty's
## own aim jitter is layered on top afterwards, same as any other shot.
func _refine_bank_direction(choice: Dictionary, power: float) -> Vector3:
	var initial_direction: Vector3 = choice["direction"]
	if cue_ball == null:
		return initial_direction
	var pot_direction: Vector3 = choice.get("pot_direction", Vector3.ZERO)
	var ghost_position: Vector3 = choice.get("ghost_position", Vector3.ZERO)
	if pot_direction.length_squared() < 0.000001:
		return initial_direction
	var target_number: int = int(choice["target_ball"])

	_ensure_ai_shadow()
	var ball_snapshots: Array = []
	for ball in balls:
		if is_instance_valid(ball) and not ball.pocketed:
			ball_snapshots.append({"number": ball.ball_number, "position": ball.global_position})
	var cue_number: int = cue_ball.ball_number
	var lateral_axis: Vector3 = Vector3.UP.cross(pot_direction).normalized()

	var best_direction := initial_direction
	var best_error := INF
	var angle_offset := 0.0
	var previous_offset := 0.0
	var previous_error := 0.0
	var have_previous := false
	var bracketed := false

	for _attempt in AI_BANK_REFINE_ITERATIONS:
		var candidate_direction: Vector3 = initial_direction.rotated(Vector3.UP, deg_to_rad(angle_offset))
		var contact: Variant = _simulate_ai_strike(ball_snapshots, cue_number, candidate_direction, power)
		if contact == null or int(contact["ball"]) != target_number:
			if bracketed:
				break # already tried a coarse sweep once; no gradient to follow
			bracketed = true
			var bracket_offset: Variant = _bracket_bank_direction(ball_snapshots, cue_number, initial_direction, power, target_number)
			if bracket_offset == null:
				break # no angle within the sweep range reaches the target ball
			angle_offset = bracket_offset
			continue
		var error: float = (Vector3(contact["position"]) - ghost_position).dot(lateral_axis)
		if absf(error) < absf(best_error):
			best_error = error
			best_direction = candidate_direction
		if absf(error) < AI_BANK_REFINE_TOLERANCE:
			break
		if not have_previous:
			have_previous = true
			previous_offset = angle_offset
			previous_error = error
			angle_offset += AI_BANK_REFINE_ANGLE_STEP_DEG if error > 0.0 else -AI_BANK_REFINE_ANGLE_STEP_DEG
			continue
		var denom: float = error - previous_error
		if absf(denom) < 0.000001:
			break
		var next_offset: float = angle_offset - error * (angle_offset - previous_offset) / denom
		previous_offset = angle_offset
		previous_error = error
		angle_offset = clampf(next_offset, -35.0, 35.0)

	return best_direction


## Sweeps outward from zero in both directions looking for any launch angle
## whose simulated first contact is the target ball at all, ignoring where on
## it. Returns the first such offset found (closest to the idealized aim), or
## null if nothing within the range reaches the target ball.
func _bracket_bank_direction(ball_snapshots: Array, cue_number: int, initial_direction: Vector3, power: float, target_number: int) -> Variant:
	var offset := AI_BANK_BRACKET_STEP_DEG
	while offset <= AI_BANK_BRACKET_RANGE_DEG:
		for direction_sign in [1.0, -1.0]:
			var candidate_offset: float = offset * direction_sign
			var candidate_direction: Vector3 = initial_direction.rotated(Vector3.UP, deg_to_rad(candidate_offset))
			var contact: Variant = _simulate_ai_strike(ball_snapshots, cue_number, candidate_direction, power)
			if contact != null and int(contact["ball"]) == target_number:
				return candidate_offset
		offset += AI_BANK_BRACKET_STEP_DEG
	return null


func _ensure_ai_shadow() -> void:
	if _ai_shadow != null:
		return
	_ai_shadow = PHYSICS_SCENE.new()
	var config: Dictionary = TABLE_PROFILE.get_calibration().duplicate(true)
	config["descriptors"] = TABLE_PROFILE.get_physics_descriptors()
	_ai_shadow.configure(config)
	_ai_shadow.ball_contacted.connect(_on_ai_shadow_contact)
	_ai_shadow.ball_pocketed.connect(_on_ai_shadow_pocketed)


func _on_ai_shadow_contact(a: Variant, b: Variant) -> void:
	if _ai_shadow_contact.is_empty():
		_ai_shadow_contact.append(int(a))
		_ai_shadow_contact.append(int(b))


func _on_ai_shadow_pocketed(ball: Variant) -> void:
	_ai_shadow_pocketed.append(int(ball))


## Strikes a fresh copy of the current table on the shadow solver and steps
## it until the cue ball's first contact with any ball (or it runs out of
## steps/settles without one). Synchronous and only invoked a handful of
## times per bank shot at AI decision time, not per frame.
func _simulate_ai_strike(ball_snapshots: Array, cue_number: int, direction: Vector3, power: float) -> Variant:
	_ai_shadow.unregister_all()
	for entry in ball_snapshots:
		_ai_shadow.add_ball(entry["number"], entry["position"], Vector3.ZERO, BALL_RADIUS, BilliardsBall.MASS, Vector3.ZERO)
	var transfer_speed: float = CUE_STICK_SCRIPT.cue_ball_speed_mps_for_power(power) * CUE_STICK_SCRIPT.WORLD_SCALE
	var impulse: Vector3 = direction.normalized() * transfer_speed * BilliardsBall.MASS

	_ai_shadow_contact.clear()
	_ai_shadow.strike_ball(cue_number, impulse, Vector3.ZERO)
	var steps := 0
	while _ai_shadow_contact.is_empty() and steps < AI_BANK_REFINE_MAX_STEPS:
		_ai_shadow.step(_ai_shadow.fixed_step)
		steps += 1
		if _ai_shadow.is_settled():
			break
	if _ai_shadow_contact.is_empty():
		return null
	var snapshot: Dictionary = _ai_shadow.snapshot()
	var contact_ball: int = _ai_shadow_contact[1] if _ai_shadow_contact[0] == cue_number else _ai_shadow_contact[0]
	return {"ball": contact_ball, "position": snapshot[cue_number]["position"]}


## Strikes a fresh copy of the current table on the shadow solver and steps it
## all the way to rest (not just first contact, unlike _simulate_ai_strike).
## Used by AIOpponent's position-play and defensive-play read-ahead to see
## where a candidate shot actually leaves every ball, not just whether it
## makes the pot.
func _simulate_ai_outcome(ball_snapshots: Array, cue_number: int, direction: Vector3, power: float) -> Dictionary:
	_ensure_ai_shadow()
	_ai_shadow.unregister_all()
	for entry in ball_snapshots:
		_ai_shadow.add_ball(entry["number"], entry["position"], Vector3.ZERO, BALL_RADIUS, BilliardsBall.MASS, Vector3.ZERO)
	var transfer_speed: float = CUE_STICK_SCRIPT.cue_ball_speed_mps_for_power(power) * CUE_STICK_SCRIPT.WORLD_SCALE
	var impulse: Vector3 = direction.normalized() * transfer_speed * BilliardsBall.MASS

	_ai_shadow_contact.clear()
	_ai_shadow_pocketed.clear()
	_ai_shadow.strike_ball(cue_number, impulse, Vector3.ZERO)
	var steps := 0
	while not _ai_shadow.is_settled() and steps < AI_OUTCOME_SIM_MAX_STEPS:
		_ai_shadow.step(_ai_shadow.fixed_step)
		steps += 1

	var first_contact := -1
	if not _ai_shadow_contact.is_empty():
		first_contact = _ai_shadow_contact[1] if _ai_shadow_contact[0] == cue_number else _ai_shadow_contact[0]
	var scratched: bool = cue_number in _ai_shadow_pocketed
	var result := {"scratched": scratched, "first_contact": first_contact}
	if scratched:
		return result

	var snapshot: Dictionary = _ai_shadow.snapshot()
	var cue_state: Variant = snapshot.get(cue_number, null)
	result["cue_position"] = cue_state["position"] if cue_state != null else Vector3.ZERO
	var ball_entries: Array = []
	for id in snapshot:
		if id == cue_number or id in _ai_shadow_pocketed:
			continue
		ball_entries.append({"number": id, "position": snapshot[id]["position"]})
	result["balls"] = ball_entries
	return result


## AIOpponent's `shot_outcome` context callable. Simulates a candidate shot to
## rest and reads back how good the resulting layout is both for the AI's own
## next shot (`own_leave_score`, position play) and for the opponent's
## (`opponent_score`, defensive play) -- pure geometric reads via
## AIOpponent.best_score(), same as any other shot-quality check, just against
## the post-shot table instead of the current one.
func _ai_shot_outcome(direction: Vector3, power: float, _hint: Dictionary) -> Dictionary:
	if cue_ball == null:
		return {"scratched": true}
	var ball_snapshots: Array = []
	for ball in balls:
		if is_instance_valid(ball) and not ball.pocketed:
			ball_snapshots.append({"number": ball.ball_number, "position": ball.global_position})
	var cue_number: int = cue_ball.ball_number

	var settled := _simulate_ai_outcome(ball_snapshots, cue_number, direction, power)
	if bool(settled.get("scratched", false)):
		return {"scratched": true, "first_contact": settled.get("first_contact", -1)}

	var remaining_numbers: Array[int] = []
	for entry in settled["balls"]:
		remaining_numbers.append(int(entry["number"]))

	return {
		"scratched": false,
		"first_contact": settled.get("first_contact", -1),
		"own_leave_score": AI_OPPONENT.best_score(_ai_shape_context(settled["cue_position"], settled["balls"], GameManager.rules.legal_targets(remaining_numbers))),
		"opponent_score": AI_OPPONENT.best_score(_ai_shape_context(settled["cue_position"], settled["balls"], _opponent_legal_numbers(remaining_numbers))),
	}


func _ai_shape_context(cue_position: Vector3, ball_entries: Array, legal_numbers: Array) -> Dictionary:
	return {
		"cue_position": cue_position,
		"balls": ball_entries,
		"pockets": TABLE_PROFILE.get_pocket_capture_descriptors(),
		"legal_numbers": legal_numbers,
		"difficulty": GameManager.ai_difficulty,
		"allow_advanced_shots": false,
	}


## The rules object only exposes legal_targets() for whoever's turn it
## currently is; briefly flipping current_player is a synchronous, read-only
## way to ask the same question for the other player, without duplicating the
## eight-ball/nine-ball group logic here.
func _opponent_legal_numbers(remaining: Array[int]) -> Array[int]:
	var rules = GameManager.rules
	var original_player: int = rules.current_player
	rules.current_player = 1 - original_player
	var result: Array[int] = rules.legal_targets(remaining)
	rules.current_player = original_player
	return result


func can_call_eight_pocket() -> bool:
	return not ai_turn_active and can_shoot() and GameManager.can_call_eight_pocket()


## Lets the player call the 8-ball's pocket by clicking/tapping directly on
## it, instead of only through the HUD dropdown. Raycasts against the pocket
## Area3D nodes (collision layer 4, built by TableBuilder) rather than the
## dropdown's pocket list, so it stays correct if pocket geometry changes.
func _try_click_eight_pocket(screen_position: Vector2) -> bool:
	if not can_call_eight_pocket():
		return false
	var camera: Camera3D = camera_rig.camera
	if camera == null:
		return false
	var origin := camera.project_ray_origin(screen_position)
	var direction := camera.project_ray_normal(screen_position)
	var query := PhysicsRayQueryParameters3D.create(origin, origin + direction * 50.0)
	query.collision_mask = 4
	query.collide_with_areas = true
	query.collide_with_bodies = false
	var result := get_world_3d().direct_space_state.intersect_ray(query)
	if result.is_empty():
		return false
	var collider: Object = result.get("collider")
	if collider == null or not (collider is Area3D):
		return false
	var area_name: String = collider.name
	if not area_name.begins_with("Pocket_"):
		return false
	var pocket_id := area_name.substr(len("Pocket_"))
	if not call_eight_pocket(pocket_id):
		return false
	if hud.has_method("select_called_pocket"):
		hud.call("select_called_pocket", pocket_id)
	return true


func call_eight_pocket(pocket_id: String) -> bool:
	if not can_call_eight_pocket():
		return false
	return GameManager.call_eight_pocket(pocket_id)


func clear_eight_pocket_call() -> bool:
	return GameManager.clear_eight_pocket_call()


func _remaining_object_ball_numbers() -> Array[int]:
	var remaining: Array[int] = []
	for ball in balls:
		if is_instance_valid(ball) and not ball.pocketed and ball.ball_number != 0:
			remaining.append(ball.ball_number)
	return remaining

func _restore_cue_ball_for_ball_in_hand() -> void:
	if cue_ball == null:
		return
	# The cue ball remains out of the solver, ghosted and free to pass through
	# other balls, until a shot commits its arrow-key placement.
	GameManager.ball_in_hand = true
	if cue_ball.pocketed:
		cue_ball.reset_to(_head_spot())
	cue_ball.set_ghost_placement(true)
	if physics_world != null and physics_world.has_method("unregister_ball"):
		physics_world.unregister_ball(cue_ball)
	_ball_in_hand_valid = not _cue_ball_overlaps_other_ball(cue_ball.global_position)

func _head_spot() -> Vector3:
	if table.has_method("get_head_spot"):
		return table.get_head_spot()
	return Vector3(-10.0 * 0.28, BALL_RADIUS + 0.0025, 0.0)

func _rack_apex() -> Vector3:
	if table.has_method("get_rack_apex"):
		return table.get_rack_apex()
	return Vector3(10.0 * 0.22, BALL_RADIUS + 0.0025, 0.0)

func _valid_cue_position(position: Vector3) -> bool:
	return _on_cloth_bounds(position) and not _cue_ball_overlaps_other_ball(position)

## Nine-ball: a ball pocketed on a foul (the 9-ball) is respotted rather than
## staying down. WPA rule: as near as possible to the foot spot without
## shifting other balls, sliding toward the head spot along the long string
## if the foot spot itself is occupied.
func _respot_balls(numbers: Array) -> void:
	for number in numbers:
		var ball := _find_ball(int(number))
		if ball == null:
			continue
		var spot := _open_respot_position(_rack_apex())
		ball.reset_to(spot)
		if physics_world != null and physics_world.has_method("restore_ball"):
			physics_world.restore_ball(ball, spot)

func _find_ball(number: int) -> RigidBody3D:
	for ball in balls:
		if is_instance_valid(ball) and ball.ball_number == number:
			return ball
	return null

func _open_respot_position(preferred: Vector3) -> Vector3:
	if _on_cloth_bounds(preferred) and not _respot_position_blocked(preferred):
		return preferred
	var head := _head_spot()
	for step_index in range(1, 21):
		var candidate: Vector3 = preferred.lerp(head, float(step_index) / 20.0)
		if _on_cloth_bounds(candidate) and not _respot_position_blocked(candidate):
			return candidate
	return preferred

func _respot_position_blocked(position: Vector3) -> bool:
	for ball in balls:
		if is_instance_valid(ball) and not ball.pocketed and ball.global_position.distance_to(position) < BALL_DIAMETER:
			return true
	return false
