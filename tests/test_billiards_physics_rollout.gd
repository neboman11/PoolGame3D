class_name BilliardsPhysicsRolloutTests
extends "res://tests/billiards_physics_test_harness.gd"

## Straight-line rollout/friction calibration and cross-run determinism checks.


func run() -> void:
	_run_case("friction rollout calibration", _test_friction_rollout)
	_run_case("profile center-ball rollout calibration", _test_default_table_and_cue_calibration)
	_run_case("profile residual-slip rollout settles", _test_profile_residual_slip_rollout)
	_run_case("rolling orientation is normalized deterministic", _test_rolling_orientation_is_normalized_deterministic)
	_run_case("snapshot determinism", _test_snapshot_determinism)


func _test_friction_rollout() -> String:
	var config: Dictionary = _base_config()
	config["gravity"] = 9.8
	config["rolling_friction"] = 0.016
	config["sliding_friction"] = 0.0
	config["spin_friction"] = 0.0
	var world_or_error: Variant = _make_world(config)
	if world_or_error is String:
		return world_or_error
	var world: Object = world_or_error

	var error: String = _add_ball(world, 0, Vector3.ZERO, Vector3(1.0, 0.0, 0.0))
	if error != "":
		_free_world(world)
		return error
	error = _advance(world, FIXED_STEP, 720) # exactly two seconds
	if error != "":
		_free_world(world)
		return error
	var state_or_error: Variant = _ball_state(world, 0)
	_free_world(world)
	if state_or_error is String:
		return state_or_error
	var state: Dictionary = state_or_error

	# v = 1 - (mu * g * t) = 0.6864 m/s; trapezoidal transport gives
	# x = ((1.0 + 0.6864) / 2) * 2 = 1.6864 m.
	var speed: float = _velocity(state).length()
	if absf(speed - 0.6864) > 0.012:
		return "rolling speed %.6f; expected 0.6864 +/- 0.012 after 2 s" % speed
	var distance: float = _position(state).x
	if absf(distance - 1.6864) > 0.025:
		return "rollout distance %.6f; expected 1.6864 +/- 0.025 after 2 s" % distance
	return ""


func _test_default_table_and_cue_calibration() -> String:
	# Use the exact calibration dictionary Game receives from TableProfile.
	# A 2.0 m/s pure roll should cover 5.831 m under production μ=0.035:
	# farther than the old 5.102 m calibration but short of μ=0.016's 12.76 m glide.
	var config: Dictionary = TABLE_PROFILE.get_calibration().duplicate(true)
	config["sliding_friction"] = 0.0
	config["spin_friction"] = 0.0
	var world_or_error: Variant = _make_world(config)
	if world_or_error is String:
		return world_or_error
	var world: Object = world_or_error
	var error := _add_ball(world, 0, Vector3.ZERO, Vector3(10.0, 0.0, 0.0))
	if error == "":
		error = _advance(world, FIXED_STEP, 2340) # 6.5 seconds; includes 5.83 m roll and sleep delay
	if error != "":
		_free_world(world)
		return error
	var state_or_error: Variant = _ball_state(world, 0)
	_free_world(world)
	if state_or_error is String:
		return state_or_error
	var state: Dictionary = state_or_error
	var distance_meters := TABLE_PROFILE.units_to_meters(_position(state).x)
	if absf(distance_meters - 5.8309) > 0.006:
		return "profile center-ball rollout %.4f m; expected 5.8309 +/- 0.006 m" % distance_meters
	if _velocity(state).length() > 0.01:
		return "profile center-ball rollout still moving at %.6f scene units/s" % _velocity(state).length()

	# The nonlinear curve reserves the lower half of the input range for
	# touch shots, while a full-strength stroke is still useful for breaks.
	var half_speed: float = CUE_STICK.cue_speed_mps_for_power(0.5)
	if absf(half_speed - 2.0692) > 0.0001:
		return "50%% cue speed %.4f m/s; expected 2.0692 m/s" % half_speed
	var half_launch_speed: float = CUE_STICK.cue_ball_speed_mps_for_power(0.5)
	if absf(half_launch_speed - 2.7068) > 0.0001:
		return "50%% cue-ball launch %.4f m/s; expected 2.7068 m/s" % half_launch_speed
	var full_launch_speed: float = CUE_STICK.cue_ball_speed_mps_for_power(1.0)
	if absf(full_launch_speed - 5.8868) > 0.0001:
		return "full cue-ball launch %.4f m/s; expected 5.8868 m/s" % full_launch_speed
	return ""


func _test_profile_residual_slip_rollout() -> String:
	# Use the same calibration Dictionary Game receives from TableProfile. A
	# near-rolling ball used to alternate around the slide threshold forever,
	# so its configured rolling resistance was never reached.
	var config: Dictionary = TABLE_PROFILE.get_calibration().duplicate(true)
	var world_or_error: Variant = _make_world(config)
	if world_or_error is String:
		return world_or_error
	var world: Object = world_or_error
	var launch_speed := TABLE_PROFILE.meters_to_units(2.0)
	var residual_slip := 0.03
	var angular_velocity := Vector3(0.0, 0.0, -(launch_speed - residual_slip) / BALL_RADIUS)
	var add_result: Variant = world.call(
		"add_ball",
		0,
		Vector3.ZERO,
		Vector3(launch_speed, 0.0, 0.0),
		BALL_RADIUS,
		BALL_MASS,
		angular_velocity
	)
	if add_result is String and not String(add_result).is_empty():
		_free_world(world)
		return "add_ball() reported: %s" % add_result
	var error := _advance(world, FIXED_STEP, 2340)
	if error != "":
		_free_world(world)
		return error
	var state_or_error: Variant = _ball_state(world, 0)
	var settled: bool = bool(world.call("is_settled"))
	_free_world(world)
	if state_or_error is String:
		return state_or_error
	var state: Dictionary = state_or_error
	var distance_meters := TABLE_PROFILE.units_to_meters(_position(state).x)
	if not settled:
		return "profile near-roll ball did not settle after 6.5 s (speed %.6f scene units/s)" % _velocity(state).length()
	if absf(distance_meters - 5.8319) > 0.006:
		return "profile near-roll rollout %.4f m; expected 5.8319 +/- 0.006 m" % distance_meters
	return ""


## Exercises the same cue speed, 15-ball layout, dimensions, mass, table
## descriptors, and cloth calibration the Game uses for a center break.


func _test_rolling_orientation_is_normalized_deterministic() -> String:
	var config := _elastic_config()
	var first_or_error: Variant = _make_world(config)
	if first_or_error is String:
		return first_or_error
	var second_or_error: Variant = _make_world(config)
	if second_or_error is String:
		_free_world(first_or_error)
		return second_or_error
	var first: Object = first_or_error
	var second: Object = second_or_error
	# v = +x, ω = -z/r is an exact no-slip rolling state. Friction is disabled
	# here so this isolates orientation integration from cloth deceleration.
	first.call("add_ball", 0, Vector3.ZERO, Vector3(1.0, 0.0, 0.0), BALL_RADIUS, BALL_MASS, Vector3(0.0, 0.0, -10.0))
	second.call("add_ball", 0, Vector3.ZERO, Vector3(1.0, 0.0, 0.0), BALL_RADIUS, BALL_MASS, Vector3(0.0, 0.0, -10.0))
	var error := _advance(first, FIXED_STEP, 360)
	if error.is_empty():
		# Same fixed simulation time with a different caller delta.
		error = _advance(second, 1.0 / 120.0, 120)
	if not error.is_empty():
		_free_world(first)
		_free_world(second)
		return error
	var first_state_or_error: Variant = _ball_state(first, 0)
	var second_state_or_error: Variant = _ball_state(second, 0)
	_free_world(first)
	_free_world(second)
	if first_state_or_error is String:
		return first_state_or_error
	if second_state_or_error is String:
		return second_state_or_error
	var first_orientation: Variant = first_state_or_error.get("orientation", null)
	var second_orientation: Variant = second_state_or_error.get("orientation", null)
	if not first_orientation is Quaternion or not second_orientation is Quaternion:
		return "snapshot does not expose Quaternion orientation for a rolling ball"
	var first_quaternion: Quaternion = first_orientation
	var second_quaternion: Quaternion = second_orientation
	if absf(first_quaternion.length() - 1.0) > EPSILON:
		return "rolling orientation length %.9f; expected normalized quaternion" % first_quaternion.length()
	if absf(absf(first_quaternion.dot(Quaternion.IDENTITY)) - 1.0) < 0.01:
		return "rolling orientation did not change from identity"
	if absf(absf(first_quaternion.dot(second_quaternion)) - 1.0) > EPSILON:
		return "rolling orientation differs across equivalent fixed-step advances"
	return ""


func _test_snapshot_determinism() -> String:
	var first_or_error: Variant = _make_world(_elastic_config())
	if first_or_error is String:
		return first_or_error
	var second_or_error: Variant = _make_world(_elastic_config())
	if second_or_error is String:
		_free_world(first_or_error)
		return second_or_error
	var first: Object = first_or_error
	var second: Object = second_or_error
	var error: String = _seed_determinism_shot(first)
	if error == "":
		error = _seed_determinism_shot(second)
	if error == "":
		error = _advance(first, FIXED_STEP, 480)
	if error == "":
		error = _advance(second, FIXED_STEP, 480)
	if error != "":
		_free_world(first)
		_free_world(second)
		return error
	var first_snapshot_or_error: Variant = _snapshot(first)
	var second_snapshot_or_error: Variant = _snapshot(second)
	var repeat_snapshot_or_error: Variant = _snapshot(first)
	_free_world(first)
	_free_world(second)
	if first_snapshot_or_error is String:
		return first_snapshot_or_error
	if second_snapshot_or_error is String:
		return second_snapshot_or_error
	if repeat_snapshot_or_error is String:
		return repeat_snapshot_or_error
	var first_snapshot: Dictionary = first_snapshot_or_error
	var second_snapshot: Dictionary = second_snapshot_or_error
	var repeat_snapshot: Dictionary = repeat_snapshot_or_error

	for ball_id in [0, 1]:
		var first_state_or_error: Variant = _state_from_snapshot(first_snapshot, ball_id)
		var second_state_or_error: Variant = _state_from_snapshot(second_snapshot, ball_id)
		var repeat_state_or_error: Variant = _state_from_snapshot(repeat_snapshot, ball_id)
		if first_state_or_error is String:
			return first_state_or_error
		if second_state_or_error is String:
			return second_state_or_error
		if repeat_state_or_error is String:
			return repeat_state_or_error
		var first_state: Dictionary = first_state_or_error
		var second_state: Dictionary = second_state_or_error
		var repeat_state: Dictionary = repeat_state_or_error
		if not _states_match(first_state, second_state, EPSILON):
			return "ball %s differs between identical fixed-step simulations" % ball_id
		if not _states_match(first_state, repeat_state, 0.0):
			return "snapshot() changed simulation state for ball %s" % ball_id
	return ""


func _seed_determinism_shot(world: Object) -> String:
	var error: String = _add_ball(world, 0, Vector3(-0.5, 0.0, 0.0), Vector3(1.7, 0.0, 0.15))
	if error == "":
		error = _add_ball(world, 1, Vector3(0.35, 0.0, 0.08), Vector3.ZERO)
	return error
