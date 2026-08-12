class_name GameFlowTests
extends RefCounted

## Game orchestration checks: shot-gating (can_shoot/_can_strike/eight-ball
## call requirement), ball-in-hand placement validity, cloth-bounds clamping,
## and the ai_turn_active aim-sync/HUD-visibility split in _process().
##
## The Game script is instantiated directly and never added to the
## SceneTree, so @onready fields are populated by hand instead - this avoids
## needing the full Game.tscn scene, matching the rest of the suite. Real
## CueStick/CameraRig instances are used where their own state machines
## matter; a plain Node3D stub stands in for Table where only the cloth-
## bounds predicate is needed. GameManager is the live autoload singleton
## shared by every suite in this process, so every test resets it with
## _gm().reset_state() before returning.

const CUE_STICK := preload("res://scripts/cue_stick.gd")
const CAMERA_RIG := preload("res://scripts/camera_rig.gd")

## game.gd references the GameManager autoload as a bare identifier, which
## this suite's --script entry point cannot resolve until after the engine
## has finished registering autoloads. preload()ing it (like every other
## const above) would compile it too early and permanently poison it - load()
## defers that compile until the first Game is actually built, by which
## point the run_headless.gd entry point's call_deferred("_run") has let
## autoload registration finish.
var _game_script: GDScript = load("res://scripts/game.gd")


class TableStub extends Node3D:
	var half_x := 5.0
	var half_z := 2.5

	func is_position_on_cloth(position: Vector3, _radius: float) -> bool:
		return absf(position.x) <= half_x and absf(position.z) <= half_z


class PhysicsWorldStub extends Node:
	var settled := true

	func is_settled() -> bool:
		return settled


class HudStub extends Control:
	var shot_controls_visible_log: Array[bool] = []

	func set_shot_controls_visible(is_visible: bool) -> void:
		shot_controls_visible_log.append(is_visible)


## Duck-typed stand-in for EightBallRules/NineBallRules, injected directly
## into the live _gm().rules field (untyped, so this is accepted) to
## drive Game's own gating logic without re-driving a real rules phase
## machine - that machine is already covered by test_eight_ball_rules.gd and
## test_nine_ball_rules.gd.
## Stand-in for a BilliardsBall in the one test that needs a ball actually
## inside the SceneTree (global_position only resolves there). The real
## ball script's _ready() awaits texture generation and expects
## MeshInstance3D/CollisionShape3D scene children that a bare .new() doesn't
## have, so a minimal RigidBody3D avoids that entirely.
class BallStub extends RigidBody3D:
	var pocketed := false


class RulesStub extends RefCounted:
	var game_over := false
	var force_call_eight := false

	func is_game_over() -> bool:
		return game_over

	func can_call_eight_pocket(_remaining: Array) -> bool:
		return force_call_eight


var _passed := 0
var _failed: Array[String] = []


func run() -> int:
	_run_case("_can_strike allows a ready table and rejects mid-shot", _test_can_strike_active_shot_gate)
	_run_case("_can_strike rejects when the cue ball is missing", _test_can_strike_null_cue_ball)
	_run_case("_can_strike rejects while a shot is already in progress", _test_can_strike_shot_in_progress)
	_run_case("_can_strike gates on ball-in-hand placement validity", _test_can_strike_ball_in_hand_validity)
	_run_case("_can_strike defers to the cue stick's own input state", _test_can_strike_cue_stick_gate)
	_run_case("_can_strike waits for the physics world to settle", _test_can_strike_physics_settled_gate)
	_run_case("can_shoot requires the 8-ball pocket to be called first", _test_can_shoot_eight_ball_call_gate)
	_run_case("can_call_eight_pocket is unavailable during the AI's turn", _test_can_call_eight_pocket_ai_turn_gate)
	_run_case("3D table clicks do not call a pocket", _test_table_click_does_not_call_pocket)
	_run_case("AI turn blocks player cue-elevation keys", _test_ai_turn_blocks_elevation_input)
	_run_case("any_ball_moving mirrors can_shoot", _test_any_ball_moving_mirrors_can_shoot)
	_run_case("_valid_cue_position rejects off-cloth and overlapping placements", _test_valid_cue_position)
	_run_case("_clamped_cloth_position slides along the axis that stays on the cloth", _test_clamped_cloth_position)
	_run_case("_process only syncs cue aim from the camera outside the AI's turn", _test_process_ai_turn_aim_sync)
	_run_case("_process hides shot controls during a shot or the AI's turn", _test_process_shot_controls_visibility)

	if _failed.is_empty():
		print("PASS: %d game flow checks" % _passed)
		return 0
	printerr("FAIL: %d/%d game flow checks failed" % [_failed.size(), _passed + _failed.size()])
	for failure in _failed:
		printerr("  - %s" % failure)
	return 1


func _run_case(label: String, test: Callable) -> void:
	var result: String = test.call()
	if result.is_empty():
		_passed += 1
		print("PASS: %s" % label)
	else:
		_failed.append("%s: %s" % [label, result])


## The GameManager autoload isn't resolvable as a bare identifier from a
## RefCounted script preloaded under this suite's own --script entry point,
## even though the singleton node is live under /root - so it is looked up
## by path and accessed dynamically (untyped) instead.
func _gm():
	return Engine.get_main_loop().root.get_node("GameManager")


func _new_game() -> Node:
	var game: Node = _game_script.new()
	game.table = TableStub.new()
	game.cue_stick = CUE_STICK.new()
	game.camera_rig = CAMERA_RIG.new()
	game.hud = HudStub.new()
	return game


func _free_game(game: Node) -> void:
	if is_instance_valid(game.table):
		game.table.free()
	if is_instance_valid(game.cue_stick):
		game.cue_stick.free()
	if is_instance_valid(game.camera_rig):
		game.camera_rig.free()
	if is_instance_valid(game.hud):
		game.hud.free()
	if game.physics_world is Node and is_instance_valid(game.physics_world):
		game.physics_world.free()
	game.free()


func _new_ball(number: int) -> RigidBody3D:
	var ball: RigidBody3D = BilliardsBall.new()
	ball.ball_number = number
	return ball


func _ready_game_for_shot() -> Node:
	var game := _new_game()
	game.cue_ball = _new_ball(0)
	game.physics_world = null
	game.shot_in_progress = false
	return game


func _test_can_strike_active_shot_gate() -> String:
	_gm().reset_state()
	var game := _ready_game_for_shot()
	var error := ""
	if not game._can_strike():
		error = "a fresh, settled table should be ready to strike"
	_gm().active_shot = true
	if error.is_empty() and game._can_strike():
		error = "a shot already in progress must block another strike"
	_gm().active_shot = false
	game.cue_ball.free()
	_free_game(game)
	_gm().reset_state()
	return error


func _test_can_strike_null_cue_ball() -> String:
	_gm().reset_state()
	var game := _ready_game_for_shot()
	game.cue_ball.free()
	game.cue_ball = null
	var error := ""
	if game._can_strike():
		error = "a missing cue ball must block the strike"
	_free_game(game)
	_gm().reset_state()
	return error


func _test_can_strike_shot_in_progress() -> String:
	_gm().reset_state()
	var game := _ready_game_for_shot()
	game.shot_in_progress = true
	var error := ""
	if game._can_strike():
		error = "shot_in_progress must block another strike"
	game.cue_ball.free()
	_free_game(game)
	_gm().reset_state()
	return error


func _test_can_strike_ball_in_hand_validity() -> String:
	_gm().reset_state()
	var game := _ready_game_for_shot()
	_gm().ball_in_hand = true
	game._ball_in_hand_valid = false
	var error := ""
	if game._can_strike():
		error = "an invalid ball-in-hand placement must block the strike"
	game._ball_in_hand_valid = true
	if error.is_empty() and not game._can_strike():
		error = "a valid ball-in-hand placement should allow the strike"
	_gm().ball_in_hand = false
	game.cue_ball.free()
	_free_game(game)
	_gm().reset_state()
	return error


func _test_can_strike_cue_stick_gate() -> String:
	_gm().reset_state()
	var game := _ready_game_for_shot()
	game.cue_stick.input_phase = game.cue_stick.InputPhase.STRIKING
	var error := ""
	if game._can_strike():
		error = "a cue stick mid-strike must block another strike"
	game.cue_stick.input_phase = game.cue_stick.InputPhase.READY
	if error.is_empty() and not game._can_strike():
		error = "a ready cue stick should allow the strike"
	game.cue_ball.free()
	_free_game(game)
	_gm().reset_state()
	return error


func _test_can_strike_physics_settled_gate() -> String:
	_gm().reset_state()
	var game := _ready_game_for_shot()
	var physics := PhysicsWorldStub.new()
	physics.settled = false
	game.physics_world = physics
	var error := ""
	if game._can_strike():
		error = "an unsettled physics world must block the strike"
	physics.settled = true
	if error.is_empty() and not game._can_strike():
		error = "a settled physics world should allow the strike"
	game.cue_ball.free()
	_free_game(game)
	_gm().reset_state()
	return error


func _test_can_shoot_eight_ball_call_gate() -> String:
	_gm().reset_state()
	var rules := RulesStub.new()
	rules.force_call_eight = true
	_gm().rules = rules
	_gm().called_eight_pocket = ""
	var game := _ready_game_for_shot()
	var error := ""
	if not game._can_strike():
		error = "table should otherwise be ready to strike"
	if error.is_empty() and game.can_shoot():
		error = "can_shoot must stay false until the 8-ball pocket is called"
	_gm().called_eight_pocket = "corner_right_top"
	if error.is_empty() and not game.can_shoot():
		error = "can_shoot should allow the stroke once the 8-ball pocket is called"
	game.cue_ball.free()
	_free_game(game)
	_gm().reset_state()
	return error


func _test_can_call_eight_pocket_ai_turn_gate() -> String:
	_gm().reset_state()
	var rules := RulesStub.new()
	rules.force_call_eight = true
	_gm().rules = rules
	var game := _ready_game_for_shot()
	game.ai_turn_active = false
	var error := ""
	if not game.can_call_eight_pocket():
		error = "a human turn ready to strike should be able to call the 8-ball pocket"
	game.ai_turn_active = true
	if error.is_empty() and game.can_call_eight_pocket():
		error = "the AI's turn must not allow a pocket call through the player's own input path"
	game.cue_ball.free()
	_free_game(game)
	_gm().reset_state()
	return error


func _test_table_click_does_not_call_pocket() -> String:
	var game := _new_game()
	var original_call: String = str(_gm().called_eight_pocket)
	var click := InputEventMouseButton.new()
	click.pressed = true
	click.button_index = MOUSE_BUTTON_LEFT
	click.position = Vector2(400.0, 300.0)
	game._unhandled_input(click)
	var error := ""
	if _gm().called_eight_pocket != original_call:
		error = "a 3D table click must not select a called pocket"
	_free_game(game)
	_gm().reset_state()
	return error


func _test_any_ball_moving_mirrors_can_shoot() -> String:
	_gm().reset_state()
	var game := _ready_game_for_shot()
	var error := ""
	if game.any_ball_moving() == game.can_shoot():
		error = "any_ball_moving() must be the exact negation of can_shoot()"
	if game.any_ball_moving():
		error = "a settled, ready table should report no ball moving"
	game.shot_in_progress = true
	if error.is_empty() and not game.any_ball_moving():
		error = "any_ball_moving() should be true while a shot is in progress"
	game.cue_ball.free()
	_free_game(game)
	_gm().reset_state()
	return error


## _cue_ball_overlaps_other_ball() reads global_position, which Godot only
## computes for a node inside the SceneTree (it returns an identity
## Transform3D otherwise, regardless of parentage) - so other_ball has to
## actually be added under the root for this one check to see its real
## position.
func _test_valid_cue_position() -> String:
	var game := _new_game()
	var cue_ball := _new_ball(0)
	var other_ball := BallStub.new()
	var root: Node = Engine.get_main_loop().root
	root.add_child(other_ball)
	other_ball.global_position = Vector3(1.0, 0.142875, 0.0)
	game.cue_ball = cue_ball
	var balls: Array[RigidBody3D] = [cue_ball, other_ball]
	game.balls = balls
	var error := ""
	if not game._valid_cue_position(Vector3(-2.0, 0.142875, 0.0)):
		error = "an on-cloth position clear of other balls should be valid"
	if error.is_empty() and game._valid_cue_position(Vector3(1.05, 0.142875, 0.0)):
		error = "a position overlapping another ball must be invalid"
	if error.is_empty() and game._valid_cue_position(Vector3(50.0, 0.142875, 0.0)):
		error = "a position off the cloth must be invalid"
	root.remove_child(other_ball)
	cue_ball.free()
	other_ball.free()
	_free_game(game)
	return error


func _test_clamped_cloth_position() -> String:
	var game := _new_game()
	var from := Vector3(0.0, 0.142875, 0.0)
	var error := ""

	var x_only: Vector3 = game._clamped_cloth_position(from, Vector3(3.0, 0.142875, 5.0))
	if not x_only.is_equal_approx(Vector3(3.0, 0.142875, 0.0)):
		error = "movement should slide along x when only z leaves the cloth, got %s" % x_only

	var z_only: Vector3 = game._clamped_cloth_position(from, Vector3(10.0, 0.142875, 1.0))
	if error.is_empty() and not z_only.is_equal_approx(Vector3(0.0, 0.142875, 1.0)):
		error = "movement should slide along z when only x leaves the cloth, got %s" % z_only

	var blocked: Vector3 = game._clamped_cloth_position(from, Vector3(10.0, 0.142875, 10.0))
	if error.is_empty() and not blocked.is_equal_approx(from):
		error = "movement leaving the cloth on both axes should stay put, got %s" % blocked

	_free_game(game)
	return error


func _test_ai_turn_blocks_elevation_input() -> String:
	var game := _new_game()
	game.ai_turn_active = true
	game.cue_stick.set_elevation(18.0)
	var elevation_key := InputEventKey.new()
	elevation_key.pressed = true
	elevation_key.keycode = KEY_Q
	game._unhandled_input(elevation_key)
	if not is_equal_approx(game.cue_stick.cue_elevation_degrees, 18.0):
		return "Q should not change elevation during the AI turn"
	return ""


func _test_process_ai_turn_aim_sync() -> String:
	_gm().reset_state()
	var game := _ready_game_for_shot()
	game.camera_rig.aim_direction = Vector3(0.0, 0.0, -1.0)
	game.cue_stick.aim_direction = Vector3.FORWARD
	game.ai_turn_active = true
	game._process(0.016)
	var error := ""
	if not game.cue_stick.aim_direction.is_equal_approx(Vector3.FORWARD):
		error = "cue aim must not follow the camera while the AI's turn is active"
	game.ai_turn_active = false
	game._process(0.016)
	if error.is_empty() and not game.cue_stick.aim_direction.is_equal_approx(Vector3(0.0, 0.0, -1.0)):
		error = "cue aim should follow the camera once control returns to the player"
	game.cue_ball.free()
	_free_game(game)
	_gm().reset_state()
	return error


func _test_process_shot_controls_visibility() -> String:
	_gm().reset_state()
	var game := _ready_game_for_shot()
	var hud: HudStub = game.hud
	game.shot_in_progress = false
	game.ai_turn_active = false
	game._process(0.016)
	var error := ""
	if hud.shot_controls_visible_log.is_empty() or not hud.shot_controls_visible_log.back():
		error = "shot controls should be visible when it is the player's turn to strike"
	hud.shot_controls_visible_log.clear()
	game.ai_turn_active = true
	game._process(0.016)
	if error.is_empty() and (hud.shot_controls_visible_log.is_empty() or hud.shot_controls_visible_log.back()):
		error = "shot controls must be hidden during the AI's turn"
	game.ai_turn_active = false
	game.shot_in_progress = true
	hud.shot_controls_visible_log.clear()
	game._process(0.016)
	if error.is_empty() and (hud.shot_controls_visible_log.is_empty() or hud.shot_controls_visible_log.back()):
		error = "shot controls must be hidden while a shot is resolving"
	game.cue_ball.free()
	_free_game(game)
	_gm().reset_state()
	return error
