class_name CueInputStateTests
extends RefCounted

## Keeps visual/input state-machine tests independent of the solver suite.

const CUE_STICK := preload("res://scripts/cue_stick.gd")
const CAMERA_RIG := preload("res://scripts/camera_rig.gd")
const BALL_SCENE := preload("res://scenes/Ball.tscn")


class PhysicsWorldStub extends Node:
	var was_struck := false

	func strike_ball(_ball: RigidBody3D, _impulse: Vector3, _tip_offset: Vector3) -> void:
		was_struck = true

var _passed := 0
var _failed: Array[String] = []


func run() -> int:
	_run_case("power press locks aim before drag", _test_power_press_locks_aim)
	_run_case("power drag locks aim until cancellation", _test_power_drag_locks_aim)
	_run_case("spin drag locks aim until released", _test_spin_drag_locks_aim)
	_run_case("successful stroke clears selected spin", _test_successful_stroke_clears_spin)
	_run_case("ready state restores aim control", _test_ready_state_restores_aim_control)
	_run_case("cue state gates camera input", _test_cue_state_gates_camera_input)
	_run_case("camera lock clears active orbit gesture", _test_camera_lock_clears_active_gesture)
	_run_case("cue fades after strike hold", _test_post_strike_fade)
	if _failed.is_empty():
		print("PASS: %d cue input state checks" % _passed)
		return 0
	printerr("FAIL: %d/%d cue input state checks failed" % [_failed.size(), _passed + _failed.size()])
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


func _test_power_press_locks_aim() -> String:
	var cue: Node3D = CUE_STICK.new()
	var initial_aim := Vector3.FORWARD
	cue.aim_direction = initial_aim
	cue.begin_power_input()
	if cue.input_phase != cue.InputPhase.POWERING:
		return _free_cue(cue, "power press did not enter POWERING")
	cue.aim_direction = Vector3.LEFT
	if not cue.aim_direction.is_equal_approx(initial_aim):
		return _free_cue(cue, "aim changed after power press but before drag")
	return _free_cue(cue, "")


func _test_power_drag_locks_aim() -> String:
	var cue: Node3D = CUE_STICK.new()
	var initial_aim := Vector3.FORWARD
	var changed_aim := Vector3.RIGHT
	cue.aim_direction = initial_aim
	cue.pull_amount = 0.5
	if cue.input_phase != cue.InputPhase.POWERING:
		return _free_cue(cue, "power write did not enter POWERING")
	if not cue.is_aim_locked():
		return _free_cue(cue, "POWERING state did not lock aim")
	cue.aim_direction = changed_aim
	if not cue.aim_direction.is_equal_approx(initial_aim):
		return _free_cue(cue, "aim changed while power drag was active")
	cue.cancel_shot_input()
	if cue.input_phase != cue.InputPhase.READY:
		return _free_cue(cue, "cancelling power drag did not return READY")
	return _free_cue(cue, "")


func _test_spin_drag_locks_aim() -> String:
	var cue: Node3D = CUE_STICK.new()
	var initial_aim := Vector3.FORWARD
	var changed_aim := Vector3.LEFT
	cue.aim_direction = initial_aim
	if not cue.begin_spin_input():
		return _free_cue(cue, "spin press was rejected while cue was READY")
	if not cue.is_aim_locked():
		return _free_cue(cue, "spin press did not lock aim")
	cue.aim_direction = changed_aim
	if not cue.aim_direction.is_equal_approx(initial_aim):
		return _free_cue(cue, "aim changed while spin drag was active")
	cue.end_spin_input()
	if not cue.can_adjust_aim():
		return _free_cue(cue, "aim did not unlock after spin drag release")
	cue.aim_direction = changed_aim
	if not cue.aim_direction.is_equal_approx(changed_aim):
		return _free_cue(cue, "aim did not accept a direction after spin drag release")
	return _free_cue(cue, "")


func _test_successful_stroke_clears_spin() -> String:
	var cue: Node3D = CUE_STICK.new()
	var cue_ball: RigidBody3D = BALL_SCENE.instantiate()
	cue_ball.mass = 0.17
	cue.cue_ball = cue_ball
	cue.spin_offset = Vector2(0.45, -0.3)
	var physics_world := PhysicsWorldStub.new()
	if not cue.take_shot(0.5, physics_world):
		cue_ball.free()
		return _free_cue(cue, "valid cue stroke was rejected")
	var error := ""
	if not physics_world.was_struck:
		error = "successful cue stroke did not reach the physics world"
	if not cue.spin_offset.is_zero_approx():
		error = "successful cue stroke retained the prior spin selection"
	cue_ball.free()
	physics_world.free()
	return _free_cue(cue, error)


func _test_ready_state_restores_aim_control() -> String:
	var cue: Node3D = CUE_STICK.new()
	cue.pull_amount = 0.25
	cue.cancel_shot_input()
	var resumed_aim := Vector3(-1.0, 0.0, 0.25).normalized()
	cue.aim_direction = resumed_aim
	var error := ""
	if not cue.aim_direction.is_equal_approx(resumed_aim):
		error = "READY state did not accept a new aim direction"
	return _free_cue(cue, error)


func _test_cue_state_gates_camera_input() -> String:
	var camera: Node3D = CAMERA_RIG.new()
	var cue: Node3D = CUE_STICK.new()

	cue.begin_power_input()
	camera.set_input_enabled(cue.can_adjust_aim())
	var error := ""
	if camera.input_enabled:
		error = "camera remained enabled while cue was powering"

	cue.cancel_shot_input()
	camera.set_input_enabled(cue.can_adjust_aim())
	if error.is_empty() and not camera.input_enabled:
		error = "camera did not re-enable when cue returned READY"

	cue.input_phase = cue.InputPhase.RESOLVING
	camera.set_input_enabled(cue.can_adjust_aim())
	if error.is_empty() and camera.input_enabled:
		error = "camera re-enabled before shot resolution finished"

	cue.set_ready_to_shoot()
	camera.set_input_enabled(cue.can_adjust_aim())
	if error.is_empty() and not camera.input_enabled:
		error = "camera did not re-enable after shot resolution"

	camera.free()
	cue.free()
	return error


func _test_camera_lock_clears_active_gesture() -> String:
	var camera: Node3D = CAMERA_RIG.new()
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	var drag := InputEventMouseMotion.new()
	drag.relative = Vector2(12.0, 0.0)

	camera._unhandled_input(press)
	camera._unhandled_input(drag)
	var yaw_before_lock: float = camera.yaw
	camera.set_input_enabled(false)
	camera._unhandled_input(drag)
	var error := ""
	if not is_equal_approx(camera.yaw, yaw_before_lock):
		error = "camera rotated while power input was locked"

	camera.set_input_enabled(true)
	camera._unhandled_input(drag)
	if error.is_empty() and not is_equal_approx(camera.yaw, yaw_before_lock):
		error = "stale drag resumed after camera input was restored"

	camera._unhandled_input(press)
	camera._unhandled_input(drag)
	if error.is_empty() and is_equal_approx(camera.yaw, yaw_before_lock):
		error = "camera did not accept a new gesture after unlock"

	camera.free()
	return error


func _test_post_strike_fade() -> String:
	var cue: Node3D = CUE_STICK.new()
	var mesh := MeshInstance3D.new()
	mesh.name = "MeshInstance3D"
	cue.add_child(mesh)
	cue.input_phase = cue.InputPhase.STRIKING
	cue._update_post_impact_visibility(cue.POST_IMPACT_HOLD_SECONDS + 0.001)
	if cue.input_phase != cue.InputPhase.RESOLVING or not cue.visible:
		return _free_cue(cue, "cue did not stay visible through the impact hold")
	cue._update_post_impact_visibility(cue.FADE_OUT_SECONDS * 0.5)
	if not cue.visible:
		return _free_cue(cue, "cue disappeared before the fade completed")
	cue._update_post_impact_visibility(cue.FADE_OUT_SECONDS * 0.6)
	if cue.visible:
		return _free_cue(cue, "cue remained visible after the fade completed")
	return _free_cue(cue, "")


func _free_cue(cue: Node3D, error: String) -> String:
	cue.free()
	return error
