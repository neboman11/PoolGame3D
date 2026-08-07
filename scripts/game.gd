extends Node3D

## Match orchestration: it owns rack setup and translates solver events into
## rules/UI state. BilliardsPhysics owns every moving-ball calculation.

const BALL_SCENE := preload("res://scenes/Ball.tscn")
const PHYSICS_SCENE := preload("res://scripts/billiards_physics.gd")
const SHOT_RECORDER := preload("res://scripts/shot_recorder.gd")
const TABLE_PROFILE := preload("res://scripts/table_profile.gd")
const AI_TURN_CONTROLLER := preload("res://scripts/ai_turn_controller.gd")
const BALL_RADIUS := 0.142875
const BALL_DIAMETER := BALL_RADIUS * 2.0
const CUE_BALL_MOVE_SPEED := 3.0 # world units/sec while placing ball in hand
const CUE_BALL_PRECISION_SPEED_FACTOR := 0.8 # precision toggle: 20% slower
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
var _ai := AI_TURN_CONTROLLER.new()
var _rng := RandomNumberGenerator.new()
var _ball_in_hand_valid := true

func _ready() -> void:
	GameManager.register_game(self)
	hud.setup(self)
	aim_guide.setup(self)
	aim_guide.enabled = Settings.aim_guide_default
	hud.set_aim_guide_pressed(Settings.aim_guide_default)
	camera_rig.sensitivity_multiplier = Settings.camera_sensitivity
	camera_rig.precision_aim_factor = Settings.precision_aim_sensitivity
	_rng.randomize()
	_ai.setup(self)
	_create_physics_world()
	rerack()
	GameManager.shot_resolved.connect(_on_shot_resolved)
	_sync_camera_input_with_cue_state()

func _exit_tree() -> void:
	_ai.cleanup()

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
		positions[i].x += _rng.randf_range(-jitter, jitter)
		positions[i].z += _rng.randf_range(-jitter, jitter)
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
	_ai.maybe_start_turn()

## `GameManager.shot_resolved` fires synchronously from inside `settle_shot()`,
## i.e. mid-way through `_on_solver_settled()` and before it resets
## `cue_stick` to READY. Starting the AI turn from here would run its
## `can_shoot()` gate while the cue is still RESOLVING, so it would silently
## no-op every time - `_ai.maybe_start_turn()` is instead called at the end of
## `_on_solver_settled()`, once the cue stick is actually ready.
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
