class_name BilliardsPhysicsCollisionsTests
extends "res://tests/billiards_physics_test_harness.gd"

## Ball-ball impulse transfer and cushion reflection checks.


func run() -> void:
	_run_case("elastic head-on impact", _test_elastic_head_on)
	_run_case("unequal-mass head-on impulse", _test_unequal_mass_head_on)
	_run_case("elastic cut collision", _test_elastic_cut)
	_run_case("finite rotated cushion reflection", _test_rotated_cushion_reflection)


func _test_unequal_mass_head_on() -> String:
	var world_or_error: Variant = _make_world(_elastic_config())
	if world_or_error is String:
		return world_or_error
	var world: Object = world_or_error
	var light_mass := 0.17
	var heavy_mass := 0.34
	world.call("add_ball", 0, Vector3.ZERO, Vector3(2.0, 0.0, 0.0), BALL_RADIUS, light_mass)
	world.call("add_ball", 1, Vector3(0.8, 0.0, 0.0), Vector3.ZERO, BALL_RADIUS, heavy_mass)
	var error := _advance(world, FIXED_STEP, 240)
	if error != "":
		_free_world(world)
		return error
	var light_or_error: Variant = _ball_state(world, 0)
	var heavy_or_error: Variant = _ball_state(world, 1)
	_free_world(world)
	if light_or_error is String:
		return light_or_error
	if heavy_or_error is String:
		return heavy_or_error
	var light_velocity := _velocity(light_or_error)
	var heavy_velocity := _velocity(heavy_or_error)
	if absf(light_velocity.x + 2.0 / 3.0) > 0.035:
		return "light ball %.6f; expected -2/3 from elastic mass ratio" % light_velocity.x
	if absf(heavy_velocity.x - 4.0 / 3.0) > 0.035:
		return "heavy ball %.6f; expected 4/3 from elastic mass ratio" % heavy_velocity.x
	var initial_momentum := light_mass * 2.0
	var final_momentum := light_mass * light_velocity.x + heavy_mass * heavy_velocity.x
	if absf(final_momentum - initial_momentum) > 0.012:
		return "unequal-mass impact momentum %.6f; expected %.6f" % [final_momentum, initial_momentum]
	return ""


func _test_elastic_head_on() -> String:
	var world_or_error: Variant = _make_world(_elastic_config())
	if world_or_error is String:
		return world_or_error
	var world: Object = world_or_error
	var error: String = _add_ball(world, 0, Vector3.ZERO, Vector3(1.4, 0.0, 0.0))
	if error == "":
		error = _add_ball(world, 1, Vector3(0.8, 0.0, 0.0), Vector3.ZERO)
	if error == "":
		error = _advance(world, FIXED_STEP, 240) # 2/3 second, comfortably after impact
	if error != "":
		_free_world(world)
		return error
	var cue_or_error: Variant = _ball_state(world, 0)
	var object_or_error: Variant = _ball_state(world, 1)
	_free_world(world)
	if cue_or_error is String:
		return cue_or_error
	if object_or_error is String:
		return object_or_error

	var cue_state: Dictionary = cue_or_error
	var object_state: Dictionary = object_or_error
	var cue_velocity: Vector3 = _velocity(cue_state)
	var object_velocity: Vector3 = _velocity(object_state)
	if cue_velocity.length() > 0.035:
		return "cue speed %.6f; equal-mass elastic impact should stop it" % cue_velocity.length()
	if absf(object_velocity.x - 1.4) > 0.035 or absf(object_velocity.z) > 0.035:
		return "object velocity %s; expected approximately (1.4, 0, 0)" % object_velocity
	return ""


func _test_elastic_cut() -> String:
	var world_or_error: Variant = _make_world(_elastic_config())
	if world_or_error is String:
		return world_or_error
	var world: Object = world_or_error
	var error: String = _add_ball(world, 0, Vector3.ZERO, Vector3(2.0, 0.0, 0.0))
	if error == "":
		# At contact this produces a normal near (sqrt(3)/2, 0, 1/2).
		error = _add_ball(world, 1, Vector3(0.7, 0.0, 0.1), Vector3.ZERO)
	if error == "":
		error = _advance(world, FIXED_STEP, 180) # 0.5 second
	if error != "":
		_free_world(world)
		return error
	var cue_or_error: Variant = _ball_state(world, 0)
	var object_or_error: Variant = _ball_state(world, 1)
	_free_world(world)
	if cue_or_error is String:
		return cue_or_error
	if object_or_error is String:
		return object_or_error

	var cue_state: Dictionary = cue_or_error
	var object_state: Dictionary = object_or_error
	var cue_velocity: Vector3 = _velocity(cue_state)
	var object_velocity: Vector3 = _velocity(object_state)
	var expected_cue := Vector3(0.5, 0.0, -0.8660254)
	var expected_object := Vector3(1.5, 0.0, 0.8660254)
	if _vector_distance(cue_velocity, expected_cue) > 0.09:
		return "cue cut velocity %s; expected approximately %s" % [cue_velocity, expected_cue]
	if _vector_distance(object_velocity, expected_object) > 0.09:
		return "object cut velocity %s; expected approximately %s" % [object_velocity, expected_object]
	var momentum_error := _vector_distance(cue_velocity + object_velocity, Vector3(2.0, 0.0, 0.0))
	if momentum_error > 0.07:
		return "cut collision loses momentum by %.6f" % momentum_error
	return ""


func _test_rotated_cushion_reflection() -> String:
	var rotation_y: float = deg_to_rad(31.0)
	var face_axis: Vector3 = Vector3(cos(rotation_y), 0.0, -sin(rotation_y))
	var config: Dictionary = _elastic_config()
	config["descriptors"] = [{
		"id": "calibration_rotated_cushion",
		"type": "cushion",
		"center": Vector3(0.0, BALL_RADIUS, 0.0),
		"size": Vector3(0.10, BALL_RADIUS * 2.0, 1.20),
		"rotation_y": rotation_y,
		"friction": 0.0,
		"restitution": 1.0,
	}]
	var world_or_error: Variant = _make_world(config)
	if world_or_error is String:
		return world_or_error
	var world: Object = world_or_error
	var error: String = _add_ball(
		world,
		0,
		face_axis * -0.35 + Vector3(0.0, BALL_RADIUS, 0.0),
		face_axis * 3.0
	)
	if error == "":
		error = _advance(world, FIXED_STEP, 40)
	if error != "":
		_free_world(world)
		return error
	var state_or_error: Variant = _ball_state(world, 0)
	_free_world(world)
	if state_or_error is String:
		return state_or_error
	var state: Dictionary = state_or_error
	var expected_velocity: Vector3 = -face_axis * 3.0
	var actual_velocity: Vector3 = _velocity(state)
	if _vector_distance(actual_velocity, expected_velocity) > 0.07:
		return "finite rotated cushion returned %s; expected %s" % [actual_velocity, expected_velocity]
	return ""
