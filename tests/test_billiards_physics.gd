class_name BilliardsPhysicsTests
extends RefCounted

## Deterministic calibration tests for the pure-state BilliardsPhysics adapter.
##
## This script intentionally has no preload of the production physics code. That
## keeps a fresh checkout runnable while the core is being developed and avoids
## coupling tests to scene/class-registration order.

const BALL_RADIUS := 0.1
const BALL_MASS := 0.17
const FIXED_STEP := 1.0 / 360.0
const EPSILON := 0.000001
const TABLE_PROFILE := preload("res://scripts/table_profile.gd")
const CUE_STICK := preload("res://scripts/cue_stick.gd")
## Mirrors Game.RACK_LAYOUT; positions are generated through TableProfile so
## production and the deterministic break regression share tangent geometry.
const PRODUCTION_RACK_LAYOUT := [[1], [9, 2], [10, 8, 3], [4, 11, 5, 15], [12, 6, 14, 7, 13]]

var _passed := 0
var _failed: Array[String] = []


func run() -> int:
	var prototype_or_error: Variant = _make_world(_base_config())
	if prototype_or_error is String:
		printerr("BilliardsPhysics test harness cannot run: %s" % prototype_or_error)
		printerr("Expected deterministic adapter: configure(Dictionary), add_ball(id, position, velocity, radius, mass), step(delta), snapshot().")
		return 2
	_free_world(prototype_or_error)

	_run_case("friction rollout calibration", _test_friction_rollout)
	_run_case("profile center-ball rollout calibration", _test_default_table_and_cue_calibration)
	_run_case("profile residual-slip rollout settles", _test_profile_residual_slip_rollout)
	_run_case("production tangent-rack break propagation", _test_production_tangent_rack_break_propagation)
	_run_case("production tangent-rack break settles once", _test_production_tangent_rack_break_settles_once)
	_run_case("tangent resting rack sleeps without contacts", _test_tangent_resting_rack_sleeps_without_contacts)
	_run_case("dead-center break cue stuns and settles", _test_dead_center_break_cue_stuns_and_settles)
	_run_case("rolling orientation is normalized deterministic", _test_rolling_orientation_is_normalized_deterministic)
	_run_case("elastic head-on impact", _test_elastic_head_on)
	_run_case("unequal-mass head-on impulse", _test_unequal_mass_head_on)
	_run_case("elastic cut collision", _test_elastic_cut)
	_run_case("finite rotated cushion reflection", _test_rotated_cushion_reflection)
	_run_case("pocket approach gating", _test_pocket_approach_gating)
	_run_case("production profile pocket capture", _test_profile_pocket_capture)
	_run_case("production pocket dimensions edge capture", _test_production_pocket_dimensions_edge_capture)
	_run_case("production side pocket straight entry", _test_production_side_pocket_straight_entry)
	_run_case("production full-power side pocket entry", _test_production_full_power_side_pocket_entry)
	_run_case("production full-power corner pocket entry", _test_production_full_power_corner_pocket_entry)
	_run_case("production pocket shelf rejects premature capture", _test_production_pocket_shelf_rejects_premature_capture)
	_run_case("production corner jaw deflects a shot beyond the mouth", _test_production_corner_jaw_deflects_missed_throat_entry)
	_run_case("production corner jaw does not block an in-mouth entry", _test_production_corner_jaw_does_not_block_in_mouth_entry)
	_run_case("ball creeping to rest inside the mouth annulus is captured, not left resting on the rim", _test_production_corner_creep_in_mouth_annulus_is_captured)
	_run_case("snapshot determinism", _test_snapshot_determinism)

	if _failed.is_empty():
		print("PASS: %d deterministic billiards physics checks" % _passed)
		return 0

	printerr("FAIL: %d/%d deterministic billiards physics checks failed" % [_failed.size(), _passed + _failed.size()])
	for failure in _failed:
		printerr("  - %s" % failure)
	return 1


func _run_case(label: String, test: Callable) -> void:
	var result: Variant = test.call()
	if result == "":
		_passed += 1
		print("PASS: %s" % label)
	else:
		_failed.append("%s: %s" % [label, str(result)])


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
func _test_production_tangent_rack_break_propagation() -> String:
	var config: Dictionary = TABLE_PROFILE.get_calibration().duplicate(true)
	config["descriptors"] = TABLE_PROFILE.get_physics_descriptors()
	var world_or_error: Variant = _make_world(config)
	if world_or_error is String:
		return world_or_error
	var world: Object = world_or_error
	var error := _seed_production_tangent_break(world)
	if error != "":
		_free_world(world)
		return error
	var initial_or_error: Variant = _snapshot(world)
	if initial_or_error is String:
		_free_world(world)
		return initial_or_error
	error = _advance(world, FIXED_STEP, 180) # 0.5 seconds after the full-power break.
	if error != "":
		_free_world(world)
		return error
	var final_or_error: Variant = _snapshot(world)
	_free_world(world)
	if final_or_error is String:
		return final_or_error
	var initial: Dictionary = initial_or_error
	var final: Dictionary = final_or_error
	var moved_balls := 0
	var reached_rows := 0
	for row in PRODUCTION_RACK_LAYOUT:
		var row_moved := false
		for ball_id: int in row:
			var before_or_error: Variant = _state_from_snapshot(initial, ball_id)
			var after_or_error: Variant = _state_from_snapshot(final, ball_id)
			if before_or_error is String:
				return before_or_error
			if after_or_error is String:
				return after_or_error
			var displacement := _vector_distance(
				_position(after_or_error),
				_position(before_or_error)
			)
			if displacement > TABLE_PROFILE.BALL_RADIUS * 0.5:
				moved_balls += 1
				row_moved = true
		if row_moved:
			reached_rows += 1
	if reached_rows != PRODUCTION_RACK_LAYOUT.size():
		return "break reached %s/%s rack rows" % [reached_rows, PRODUCTION_RACK_LAYOUT.size()]
	if moved_balls < 12:
		return "break moved %s object balls; expected at least 12 with a tangent rack" % moved_balls
	return ""


## Game only returns the cue to READY after this signal. A rack must therefore
## settle once after a real break rather than repeatedly waking tangent balls.
func _test_production_tangent_rack_break_settles_once() -> String:
	var config: Dictionary = TABLE_PROFILE.get_calibration().duplicate(true)
	config["descriptors"] = TABLE_PROFILE.get_physics_descriptors()
	var world_or_error: Variant = _make_world(config)
	if world_or_error is String:
		return world_or_error
	var world: Object = world_or_error
	if not world.has_signal("balls_settled"):
		_free_world(world)
		return "BilliardsPhysics lacks balls_settled signal required by Game"
	var settled_events := {"count": 0}
	world.connect("balls_settled", func() -> void: settled_events["count"] += 1)

	var error := _seed_production_tangent_break(world)
	if error.is_empty():
		error = _advance(world, FIXED_STEP, 7200) # 20 s simulation window
	var settled: bool = bool(world.call("is_settled"))
	var settled_count: int = int(settled_events["count"])
	_free_world(world)
	if not error.is_empty():
		return error
	if not settled:
		return "production tangent-rack break did not settle within 20 s"
	if settled_count != 1:
		return "production tangent-rack break emitted balls_settled %d times; expected once" % settled_count
	return ""


func _test_tangent_resting_rack_sleeps_without_contacts() -> String:
	var config: Dictionary = TABLE_PROFILE.get_calibration().duplicate(true)
	config["descriptors"] = TABLE_PROFILE.get_physics_descriptors()
	var world_or_error: Variant = _make_world(config)
	if world_or_error is String:
		return world_or_error
	var world: Object = world_or_error
	var contact_events := {"count": 0}
	world.connect("ball_contacted", func(_first: Variant, _second: Variant) -> void: contact_events["count"] += 1)
	var error := _seed_production_tangent_rack_at_rest(world)
	if error.is_empty():
		error = _advance(world, FIXED_STEP, 180) # Exceeds the configured 0.18 s sleep delay.
	var settled: bool = bool(world.call("is_settled"))
	var emitted_contacts: int = int(contact_events["count"])
	_free_world(world)
	if not error.is_empty():
		return error
	if not settled:
		return "a motionless tangent rack did not sleep after 0.5 s"
	if emitted_contacts != 0:
		return "a motionless tangent rack emitted %d ball_contacted events" % emitted_contacts
	return ""


func _test_dead_center_break_cue_stuns_and_settles() -> String:
	var config: Dictionary = TABLE_PROFILE.get_calibration().duplicate(true)
	config["descriptors"] = TABLE_PROFILE.get_physics_descriptors()
	var world_or_error: Variant = _make_world(config)
	if world_or_error is String:
		return world_or_error
	var world: Object = world_or_error
	var error := _seed_production_tangent_break(world)
	if error.is_empty():
		error = _advance(world, FIXED_STEP, 180) # Inspect after the rack impact and cloth conversion.
	if not error.is_empty():
		_free_world(world)
		return error
	var rolling_cue_or_error: Variant = _ball_state(world, 0)
	if rolling_cue_or_error is String:
		_free_world(world)
		return rolling_cue_or_error
	var rolling_cue: Dictionary = rolling_cue_or_error
	var velocity := _velocity(rolling_cue)
	var angular_velocity: Vector3 = rolling_cue["angular_velocity"]
	var radius: float = float(rolling_cue["radius"])
	var contact_slip := velocity + angular_velocity.cross(Vector3(0.0, -radius, 0.0))
	contact_slip.y = 0.0
	# For a zero-offset cue strike there is no initial topspin. The small
	# residual cue-ball velocity after an e=.93 equal-mass impact must be
	# converted by cloth into a near-rolling state, not sustained forward slip.
	if velocity.x > 0.35:
		_free_world(world)
		return "dead-center cue retained excessive forward speed %.6f" % velocity.x
	if contact_slip.length() > 0.02:
		_free_world(world)
		return "dead-center cue has contact slip %.6f instead of rolling" % contact_slip.length()
	# On the real 8-foot head-spot-to-apex distance the cue is still mostly
	# sliding (not yet rolling) when it reaches the rack, so an e=.93
	# equal-mass impact stuns it almost dead rather than sending it forward
	# with a strong follow roll. Any leftover spin/velocity must still decay
	# to a full stop, not persist as sustained forward motion.
	# Complete the real break, then ensure residual horizontal spin has been
	# dissipated and the game-facing settled predicate can become true.
	error = _advance(world, FIXED_STEP, 900)
	var final_cue_or_error: Variant = _ball_state(world, 0)
	var settled: bool = bool(world.call("is_settled"))
	_free_world(world)
	if not error.is_empty():
		return error
	if final_cue_or_error is String:
		return final_cue_or_error
	var final_cue: Dictionary = final_cue_or_error
	if not settled:
		return "dead-center production break did not settle after 3.0 s"
	if _velocity(final_cue).length() > EPSILON or (final_cue["angular_velocity"] as Vector3).length() > EPSILON:
		return "settled cue retains velocity %s and angular velocity %s" % [_velocity(final_cue), final_cue["angular_velocity"]]
	return ""


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


func _test_pocket_approach_gating() -> String:
	var config: Dictionary = _elastic_config()
	config["descriptors"] = [{
		"id": "calibration_corner_pocket",
		"type": "pocket",
		"center": Vector3.ZERO,
		"capture_radius": 0.30,
		"mouth_width": 0.44,
		"throat_width": 0.32,
		"shelf_depth": 0.0,
		"approach_direction": Vector3(1.0, 0.0, 0.0),
	}]
	var outbound_or_error: Variant = _make_world(config)
	if outbound_or_error is String:
		return outbound_or_error
	var outbound: Object = outbound_or_error
	var error: String = _add_ball(outbound, 0, Vector3(0.04, BALL_RADIUS, 0.0), Vector3(-1.0, 0.0, 0.0))
	if error == "":
		error = _advance(outbound, FIXED_STEP, 2) # solver runs at 1/180 s
	if error != "":
		_free_world(outbound)
		return error
	var outbound_state_or_error: Variant = _ball_state(outbound, 0)
	_free_world(outbound)
	if outbound_state_or_error is String:
		return outbound_state_or_error
	var outbound_state: Dictionary = outbound_state_or_error
	if bool(outbound_state.get("pocketed", false)):
		return "outbound ball inside pocket throat was captured"

	var inbound_or_error: Variant = _make_world(config)
	if inbound_or_error is String:
		return inbound_or_error
	var inbound: Object = inbound_or_error
	error = _add_ball(inbound, 0, Vector3(0.04, BALL_RADIUS, 0.0), Vector3(1.0, 0.0, 0.0))
	if error == "":
		error = _advance(inbound, FIXED_STEP, 2) # solver runs at 1/180 s
	if error != "":
		_free_world(inbound)
		return error
	var inbound_state_or_error: Variant = _ball_state(inbound, 0)
	_free_world(inbound)
	if inbound_state_or_error is String:
		return inbound_state_or_error
	var inbound_state: Dictionary = inbound_state_or_error
	if not bool(inbound_state.get("pocketed", false)):
		return "inward ball inside pocket throat was not captured"
	return ""


func _test_production_pocket_shelf_rejects_premature_capture() -> String:
	var descriptor_or_error: Variant = _first_profile_pocket_descriptor()
	if descriptor_or_error is String:
		return descriptor_or_error
	var descriptor: Dictionary = descriptor_or_error
	var center: Vector3 = descriptor["center"]
	var inward_normal: Vector3 = descriptor["inward_normal"]
	var approach := -inward_normal.normalized()
	var shelf_depth: float = descriptor["shelf_depth"]
	var capture_radius: float = descriptor["capture_radius"]
	var shelf_position := center - approach * (shelf_depth + 0.01)
	shelf_position.y = TABLE_PROFILE.BALL_RADIUS
	if shelf_position.distance_to(Vector3(center.x, shelf_position.y, center.z)) >= capture_radius:
		return "production shelf test is outside the corner capture radius"
	var config := _elastic_config()
	config["descriptors"] = [descriptor]
	var world_or_error: Variant = _make_world(config)
	if world_or_error is String:
		return world_or_error
	var world: Object = world_or_error
	# This ball is moving toward the drop but is still 1 cm on the cloth side
	# of the shelf plane. The old radius-shifted guard could never reject it.
	world.call("add_ball", 0, shelf_position, approach, TABLE_PROFILE.BALL_RADIUS, CUE_STICK.BALL_MASS)
	var error := _advance(world, FIXED_STEP, 2)
	if not error.is_empty():
		_free_world(world)
		return error
	var state_or_error: Variant = _ball_state(world, 0)
	_free_world(world)
	if state_or_error is String:
		return state_or_error
	if bool(state_or_error.get("pocketed", false)):
		return "production corner captured a ball still on its shelf"
	return ""


## The cushion ring leaves a mouth_width gap at each pocket. Beyond the visible
## mouth edge (outside mouth_width) there is solid table, not cloth, so a ball
## on that line must rattle off the rubber jaw and stay on the table rather
## than sail through the uncollided gap and off the playing surface.
func _test_production_corner_jaw_deflects_missed_throat_entry() -> String:
	var corner: Dictionary = {}
	for candidate in TABLE_PROFILE.get_pocket_capture_descriptors():
		if String(candidate.get("pocket_type", "")) == "corner":
			corner = candidate
			break
	if corner.is_empty():
		return "TableProfile did not expose a corner-pocket descriptor"
	var approach: Vector3 = -corner["inward_normal"]
	approach.y = 0.0
	approach = approach.normalized()
	var lateral := Vector3(-approach.z, 0.0, approach.x)
	var mouth_radius: float = float(corner["mouth_width"]) * 0.5
	# Just outside the visible hole: still solid table, must be blocked.
	var beyond_mouth_offset := mouth_radius + 0.05
	# Start well inboard of the cushion nose, on the cloth-edge axis (lateral
	# offset is unaffected by the visible-center outset, since that outset
	# runs purely along the approach axis), then travel outward through the
	# nose exactly as a real off-mouth rattle would.
	var cloth_center: Vector3 = corner["cloth_center"]
	var start: Vector3 = cloth_center - approach * 2.0 + lateral * beyond_mouth_offset
	start.y = TABLE_PROFILE.BALL_RADIUS
	var config := _elastic_config()
	config["descriptors"] = TABLE_PROFILE.get_physics_descriptors()
	var world_or_error: Variant = _make_world(config)
	if world_or_error is String:
		return world_or_error
	var world: Object = world_or_error
	var error := _add_ball(world, 0, start, approach * 23.5)
	if error.is_empty():
		error = _advance(world, FIXED_STEP, 360)
	if not error.is_empty():
		_free_world(world)
		return error
	var state_or_error: Variant = _ball_state(world, 0)
	_free_world(world)
	if state_or_error is String:
		return state_or_error
	if bool(state_or_error.get("pocketed", false)):
		return "beyond-mouth corner entry should rattle out, not be captured"
	var position: Vector3 = state_or_error["position"]
	var half_length := TABLE_PROFILE.PLAYING_SURFACE_LENGTH * 0.5
	var half_width := TABLE_PROFILE.PLAYING_SURFACE_WIDTH * 0.5
	var escape_margin := TABLE_PROFILE.CUSHION_THICKNESS + TABLE_PROFILE.RAIL_WIDTH
	if absf(position.x) > half_length + escape_margin or absf(position.z) > half_width + escape_margin:
		return "ball escaped the table through an uncollided corner mouth gap at %s" % position
	return ""


## The jaw must stay outside the visible mouth (matching the model's actual
## hole edge) so an off-center shot that is still within the mouth can drop
## normally, instead of rattling off rubber that was never really there.
func _test_production_corner_jaw_does_not_block_in_mouth_entry() -> String:
	var corner: Dictionary = {}
	for candidate in TABLE_PROFILE.get_pocket_capture_descriptors():
		if String(candidate.get("pocket_type", "")) == "corner":
			corner = candidate
			break
	if corner.is_empty():
		return "TableProfile did not expose a corner-pocket descriptor"
	var approach: Vector3 = -corner["inward_normal"]
	approach.y = 0.0
	approach = approach.normalized()
	var lateral := Vector3(-approach.z, 0.0, approach.x)
	var capture_radius: float = corner["capture_radius"]
	var mouth_radius: float = float(corner["mouth_width"]) * 0.5
	if mouth_radius <= capture_radius:
		return "corner mouth is not wider than its capture throat"
	var in_mouth_offset := capture_radius + (mouth_radius - capture_radius) * 0.5
	var center: Vector3 = corner["center"]
	var shelf_depth: float = corner["shelf_depth"]
	# At this lateral offset the true funnel between the cushion nose and the
	# jaw is only open close to the pocket; starting much farther back on a
	# straight approach line would cross the real (correctly placed) cushion
	# nose well before reaching the mouth, which is a genuine rail hit rather
	# than the jaw-blocks-the-mouth bug this test targets.
	var start: Vector3 = center - approach * (shelf_depth + TABLE_PROFILE.BALL_RADIUS + 0.12) + lateral * in_mouth_offset
	start.y = TABLE_PROFILE.BALL_RADIUS
	var config := _elastic_config()
	config["descriptors"] = TABLE_PROFILE.get_physics_descriptors()
	var world_or_error: Variant = _make_world(config)
	if world_or_error is String:
		return world_or_error
	var world: Object = world_or_error
	var error := _add_ball(world, 0, start, approach * 23.5)
	if error.is_empty():
		error = _advance(world, FIXED_STEP, 360)
	if not error.is_empty():
		_free_world(world)
		return error
	var state_or_error: Variant = _ball_state(world, 0)
	_free_world(world)
	if state_or_error is String:
		return state_or_error
	if not bool(state_or_error.get("pocketed", false)):
		return "an in-mouth off-center shot was blocked by the jaw instead of dropping"
	return ""


## A ball that decelerates to a near-stop past the throat capture circle but
## still inside the visible mouth has no jaw and no floor cutout holding it up
## there; it must be captured instead of resting clipped into the pocket's
## rendered rim/hole mesh.
func _test_production_corner_creep_in_mouth_annulus_is_captured() -> String:
	var corner: Dictionary = {}
	for candidate in TABLE_PROFILE.get_pocket_capture_descriptors():
		if String(candidate.get("pocket_type", "")) == "corner":
			corner = candidate
			break
	if corner.is_empty():
		return "TableProfile did not expose a corner-pocket descriptor"
	var approach: Vector3 = -corner["inward_normal"]
	approach.y = 0.0
	approach = approach.normalized()
	var lateral := Vector3(-approach.z, 0.0, approach.x)
	var capture_radius: float = corner["capture_radius"]
	var mouth_radius: float = float(corner["mouth_width"]) * 0.5
	if mouth_radius <= capture_radius:
		return "corner mouth is not wider than its capture throat"
	var annulus_offset := capture_radius + (mouth_radius - capture_radius) * 0.5
	var center: Vector3 = corner["center"]
	var start: Vector3 = center + lateral * annulus_offset
	start.y = TABLE_PROFILE.BALL_RADIUS
	var config := _elastic_config()
	config["descriptors"] = TABLE_PROFILE.get_physics_descriptors()
	var world_or_error: Variant = _make_world(config)
	if world_or_error is String:
		return world_or_error
	var world: Object = world_or_error
	var error := _add_ball(world, 0, start, Vector3.ZERO)
	if error.is_empty():
		error = _advance(world, FIXED_STEP, 60)
	if not error.is_empty():
		_free_world(world)
		return error
	var state_or_error: Variant = _ball_state(world, 0)
	_free_world(world)
	if state_or_error is String:
		return state_or_error
	if not bool(state_or_error.get("pocketed", false)):
		return "a ball at rest inside the mouth annulus was left resting on the pocket rim instead of captured"
	return ""


func _test_production_pocket_dimensions_edge_capture() -> String:
	var pockets: Variant = TABLE_PROFILE.get_pocket_capture_descriptors()
	if not pockets is Array:
		return "TableProfile pockets must be an Array"
	var corner: Dictionary = {}
	var side: Dictionary = {}
	for candidate in pockets:
		if not candidate is Dictionary:
			continue
		if candidate.get("pocket_type", "") == "corner":
			corner = candidate
		elif candidate.get("pocket_type", "") == "side":
			side = candidate
	if corner.is_empty() or side.is_empty():
		return "TableProfile must expose both corner and side pocket descriptors"
	if absf(TABLE_PROFILE.CORNER_MOUTH_METERS - 0.12700) > EPSILON or absf(TABLE_PROFILE.CORNER_THROAT_METERS - 0.10160) > EPSILON:
		return "corner pocket is not the calibrated 5.00 in mouth / 4.00 in throat"
	if absf(TABLE_PROFILE.SIDE_MOUTH_METERS - 0.13970) > EPSILON or absf(TABLE_PROFILE.SIDE_THROAT_METERS - 0.11430) > EPSILON:
		return "side pocket is not the calibrated 5.50 in mouth / 4.50 in throat"
	for descriptor in [corner, side]:
		var mouth_width: float = descriptor["mouth_width"]
		var throat_width: float = descriptor["throat_width"]
		var capture_radius: float = descriptor["capture_radius"]
		if mouth_width <= throat_width:
			return "pocket mouth %.6f must remain wider than throat %.6f" % [mouth_width, throat_width]
		if absf(capture_radius - throat_width * 0.5) > EPSILON:
			return "pocket capture radius %.6f is not tied to throat %.6f" % [capture_radius, throat_width]
	# A near-edge, inward corner entry proves the widened throat is active in
	# the live capture descriptor rather than only in visual geometry.
	var approach: Vector3 = -corner["inward_normal"]
	approach.y = 0.0
	approach = approach.normalized()
	var lateral := Vector3(-approach.z, 0.0, approach.x)
	var edge_position: Vector3 = corner["center"] + lateral * (float(corner["capture_radius"]) - 0.002)
	edge_position.y = TABLE_PROFILE.BALL_RADIUS
	var config := _elastic_config()
	config["descriptors"] = [corner]
	var world_or_error: Variant = _make_world(config)
	if world_or_error is String:
		return world_or_error
	var world: Object = world_or_error
	world.call("add_ball", 0, edge_position, approach, TABLE_PROFILE.BALL_RADIUS, CUE_STICK.BALL_MASS)
	var error := _advance(world, FIXED_STEP, 2)
	if not error.is_empty():
		_free_world(world)
		return error
	var state_or_error: Variant = _ball_state(world, 0)
	_free_world(world)
	if state_or_error is String:
		return state_or_error
	if not bool(state_or_error.get("pocketed", false)):
		return "near-edge inward ball missed widened production corner capture"
	return ""


func _test_production_side_pocket_straight_entry() -> String:
	var side: Dictionary = {}
	for candidate in TABLE_PROFILE.get_pocket_capture_descriptors():
		if String(candidate.get("pocket_type", "")) == "side":
			side = candidate
			break
	if side.is_empty():
		return "TableProfile did not expose a side-pocket descriptor"
	var approach: Vector3 = -side["inward_normal"]
	approach.y = 0.0
	approach = approach.normalized()
	var start: Vector3 = side["center"] - approach * (
		TABLE_PROFILE.CUSHION_THICKNESS + float(side["shelf_depth"]) + TABLE_PROFILE.BALL_RADIUS
	)
	start.y = TABLE_PROFILE.BALL_RADIUS
	var config := _elastic_config()
	config["descriptors"] = TABLE_PROFILE.get_physics_descriptors()
	var world_or_error: Variant = _make_world(config)
	if world_or_error is String:
		return world_or_error
	var world: Object = world_or_error
	var add_result: Variant = world.call(
		"add_ball",
		0,
		start,
		approach * TABLE_PROFILE.meters_to_units(CUE_STICK.cue_ball_speed_mps_for_power(1.0)),
		TABLE_PROFILE.BALL_RADIUS,
		CUE_STICK.BALL_MASS
	)
	var error := "" if not add_result is String else String(add_result)
	if error.is_empty():
		error = _advance(world, FIXED_STEP, 360)
	if not error.is_empty():
		_free_world(world)
		return error
	var state_or_error: Variant = _ball_state(world, 0)
	_free_world(world)
	if state_or_error is String:
		return state_or_error
	if not bool(state_or_error.get("pocketed", false)):
		return "straight, centered entry into a production side pocket was not captured"
	return ""

## A maximum-power cue strike must traverse the actual visible side mouth,
## rather than reflecting from a stale nominal-cloth jaw before capture.
func _test_production_full_power_side_pocket_entry() -> String:
	return _test_production_full_power_centered_pocket_entry("side")

## Corner entry is diagonal, so it covers the transition between both moved
## cushion planes as well as the shared visible pocket/drop center.
func _test_production_full_power_corner_pocket_entry() -> String:
	return _test_production_full_power_centered_pocket_entry("corner")

func _test_production_full_power_centered_pocket_entry(pocket_type: String) -> String:
	var pocket: Dictionary = {}
	for candidate in TABLE_PROFILE.get_pocket_capture_descriptors():
		if String(candidate.get("pocket_type", "")) == pocket_type:
			pocket = candidate
			break
	if pocket.is_empty():
		return "TableProfile did not expose a %s-pocket descriptor" % pocket_type
	var approach: Vector3 = -pocket["inward_normal"]
	approach.y = 0.0
	approach = approach.normalized()
	var start: Vector3 = pocket["center"] - approach * (
		float(pocket["shelf_depth"]) + TABLE_PROFILE.BALL_RADIUS + 0.850
	)
	start.y = TABLE_PROFILE.BALL_RADIUS
	var config := _elastic_config()
	config["descriptors"] = TABLE_PROFILE.get_physics_descriptors()
	var world_or_error: Variant = _make_world(config)
	if world_or_error is String:
		return world_or_error
	var world: Object = world_or_error
	# 23.5 world units/s is the cue's calibrated full-power transfer speed.
	var error := _add_ball(world, 0, start, approach * 23.5)
	if error.is_empty():
		error = _advance(world, FIXED_STEP, 180)
	if not error.is_empty():
		_free_world(world)
		return error
	var state_or_error: Variant = _ball_state(world, 0)
	_free_world(world)
	if state_or_error is String:
		return state_or_error
	if not bool(state_or_error.get("pocketed", false)):
		return "full-power centered %s-pocket entry reflected before capture" % pocket_type
	return ""


func _test_profile_pocket_capture() -> String:
	var descriptor_or_error: Variant = _first_profile_pocket_descriptor()
	if descriptor_or_error is String:
		return descriptor_or_error
	var descriptor: Dictionary = descriptor_or_error
	var center: Variant = descriptor.get("center", null)
	if not center is Vector3:
		return "TableProfile pocket descriptor requires a Vector3 center"
	var approach: Vector3 = Vector3.ZERO
	var explicit_approach: Variant = descriptor.get("approach_direction", null)
	if explicit_approach is Vector3:
		approach = explicit_approach
	else:
		var inward_normal: Variant = descriptor.get("inward_normal", null)
		if not inward_normal is Vector3:
			return "TableProfile pocket descriptor requires approach_direction or inward_normal"
		approach = -inward_normal
	if approach.length_squared() <= EPSILON:
		return "TableProfile pocket descriptor has a zero approach_direction"
	var config: Dictionary = _elastic_config()
	config["descriptors"] = [descriptor]
	var world_or_error: Variant = _make_world(config)
	if world_or_error is String:
		return world_or_error
	var world: Object = world_or_error
	var ball_position: Vector3 = center
	ball_position.y = BALL_RADIUS
	var error: String = _add_ball(world, 0, ball_position, approach.normalized())
	if error == "":
		error = _advance(world, FIXED_STEP, 2) # solver runs at 1/180 s
	if error != "":
		_free_world(world)
		return error
	var state_or_error: Variant = _ball_state(world, 0)
	_free_world(world)
	if state_or_error is String:
		return state_or_error
	var state: Dictionary = state_or_error
	if not bool(state.get("pocketed", false)):
		return "TableProfile pocket did not capture an inward ball at its center"
	return ""


func _first_profile_pocket_descriptor() -> Variant:
	var profile_path := "res://scripts/table_profile.gd"
	if not ResourceLoader.exists(profile_path):
		return "res://scripts/table_profile.gd is not available"
	var profile_script: Variant = load(profile_path)
	if not profile_script is Script:
		return "table_profile.gd did not load as a Script"
	var descriptors: Variant = profile_script.call("get_pocket_capture_descriptors")
	if not descriptors is Array or descriptors.is_empty():
		return "TableProfile.get_pocket_capture_descriptors() returned no pockets"
	var descriptor: Variant = descriptors[0]
	if not descriptor is Dictionary:
		return "TableProfile pocket descriptor must be a Dictionary"
	return descriptor.duplicate(true)


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


func _seed_production_tangent_rack_at_rest(world: Object) -> String:
	var radius: float = TABLE_PROFILE.BALL_RADIUS
	var lateral_spacing: float = TABLE_PROFILE.get_rack_lateral_ball_spacing()
	var row_advance: float = TABLE_PROFILE.get_rack_row_advance()
	var expected_row_advance := sqrt((radius * 2.0) * (radius * 2.0) - (lateral_spacing * 0.5) * (lateral_spacing * 0.5))
	if absf(lateral_spacing - radius * 2.0) > EPSILON or absf(row_advance - expected_row_advance) > EPSILON:
		return "production rack geometry is not tangent triangular packing"
	world.call(
		"add_ball",
		0,
		TABLE_PROFILE.get_head_spot(),
		Vector3.ZERO,
		radius,
		CUE_STICK.BALL_MASS
	)
	var apex := TABLE_PROFILE.get_rack_apex()
	for row_index in PRODUCTION_RACK_LAYOUT.size():
		var row: Array = PRODUCTION_RACK_LAYOUT[row_index]
		var x := apex.x + float(row_index) * row_advance
		for index in row.size():
			var z := apex.z + (float(index) - float(row.size() - 1) * 0.5) * lateral_spacing
			world.call(
				"add_ball",
				int(row[index]),
				Vector3(x, apex.y, z),
				Vector3.ZERO,
				radius,
				CUE_STICK.BALL_MASS
			)
	return ""


func _seed_production_tangent_break(world: Object) -> String:
	var radius: float = TABLE_PROFILE.BALL_RADIUS
	var lateral_spacing: float = TABLE_PROFILE.get_rack_lateral_ball_spacing()
	var row_advance: float = TABLE_PROFILE.get_rack_row_advance()
	if absf(lateral_spacing - radius * 2.0) > EPSILON:
		return "production rack lateral spacing %.9f must equal ball diameter %.9f" % [lateral_spacing, radius * 2.0]
	var expected_row_advance := sqrt((radius * 2.0) * (radius * 2.0) - (lateral_spacing * 0.5) * (lateral_spacing * 0.5))
	if absf(row_advance - expected_row_advance) > EPSILON:
		return "production rack row advance %.9f is not tangent triangular packing %.9f" % [row_advance, expected_row_advance]
	var cue_speed := TABLE_PROFILE.meters_to_units(CUE_STICK.cue_ball_speed_mps_for_power(1.0))
	world.call(
		"add_ball",
		0,
		TABLE_PROFILE.get_head_spot(),
		Vector3(cue_speed, 0.0, 0.0),
		radius,
		CUE_STICK.BALL_MASS
	)
	var apex := TABLE_PROFILE.get_rack_apex()
	for row_index in PRODUCTION_RACK_LAYOUT.size():
		var row: Array = PRODUCTION_RACK_LAYOUT[row_index]
		var x := apex.x + float(row_index) * row_advance
		for index in row.size():
			var z := apex.z + (float(index) - float(row.size() - 1) * 0.5) * lateral_spacing
			world.call(
				"add_ball",
				int(row[index]),
				Vector3(x, apex.y, z),
				Vector3.ZERO,
				radius,
				CUE_STICK.BALL_MASS
			)
	return ""


func _base_config() -> Dictionary:
	return {
		"gravity": 9.8,
		"rolling_friction": 0.016,
		"sliding_friction": 0.2,
		"spin_friction": 0.045,
		"restitution": 1.0,
		"ball_radius": BALL_RADIUS,
		"ball_mass": BALL_MASS,
		"table_plane": "xz",
	}


func _elastic_config() -> Dictionary:
	var config := _base_config()
	config["gravity"] = 0.0
	config["rolling_friction"] = 0.0
	config["sliding_friction"] = 0.0
	config["spin_friction"] = 0.0
	config["restitution"] = 1.0
	return config


func _seed_determinism_shot(world: Object) -> String:
	var error: String = _add_ball(world, 0, Vector3(-0.5, 0.0, 0.0), Vector3(1.7, 0.0, 0.15))
	if error == "":
		error = _add_ball(world, 1, Vector3(0.35, 0.0, 0.08), Vector3.ZERO)
	return error


func _make_world(config: Dictionary) -> Variant:
	var physics_or_error: Variant = _new_physics_instance()
	if physics_or_error is String:
		return physics_or_error
	var physics: Object = physics_or_error
	if not physics.has_method("configure"):
		_free_world(physics)
		return "BilliardsPhysics is present but lacks configure(Dictionary) for headless deterministic tests"
	if not physics.has_method("add_ball"):
		_free_world(physics)
		return "BilliardsPhysics is present but lacks add_ball(id, position, velocity, radius, mass)"
	if not physics.has_method("step"):
		_free_world(physics)
		return "BilliardsPhysics is present but lacks step(delta)"
	if not physics.has_method("snapshot"):
		_free_world(physics)
		return "BilliardsPhysics is present but lacks snapshot()"
	var configure_result: Variant = physics.call("configure", config)
	if configure_result is String and not String(configure_result).is_empty():
		_free_world(physics)
		return "configure() reported: %s" % configure_result
	return physics


func _new_physics_instance() -> Variant:
	for entry in ProjectSettings.get_global_class_list():
		if entry is Dictionary and entry.get("class", "") == "BilliardsPhysics":
			var script_path := String(entry.get("path", ""))
			var script: Variant = load(script_path)
			if script is Script:
				var instance: Variant = script.new()
				if instance is Object:
					return instance
				return "BilliardsPhysics script could not be instantiated"
	if ClassDB.class_exists("BilliardsPhysics"):
		var instance: Variant = ClassDB.instantiate("BilliardsPhysics")
		if instance is Object:
			return instance
		return "BilliardsPhysics class could not be instantiated"
	return "BilliardsPhysics is not available (expected class_name BilliardsPhysics)"


func _add_ball(world: Object, ball_id: int, position: Vector3, velocity: Vector3) -> String:
	var result: Variant = world.call("add_ball", ball_id, position, velocity, BALL_RADIUS, BALL_MASS)
	if result is String and not String(result).is_empty():
		return "add_ball(%s) reported: %s" % [ball_id, result]
	if result == false:
		return "add_ball(%s) returned false" % ball_id
	return ""


func _advance(world: Object, delta: float, steps: int) -> String:
	for _step_index in steps:
		var result: Variant = world.call("step", delta)
		if result is String and not String(result).is_empty():
			return "step(%.9f) reported: %s" % [delta, result]
		if result == false:
			return "step(%.9f) returned false" % delta
	return ""


func _ball_state(world: Object, ball_id: int) -> Variant:
	var snapshot_or_error: Variant = _snapshot(world)
	if snapshot_or_error is String:
		return snapshot_or_error
	return _state_from_snapshot(snapshot_or_error, ball_id)


func _snapshot(world: Object) -> Variant:
	var result: Variant = world.call("snapshot")
	if not result is Dictionary:
		return "snapshot() must return Dictionary, got %s" % type_string(typeof(result))
	return result


func _state_from_snapshot(snapshot: Dictionary, ball_id: int) -> Variant:
	var balls: Variant = snapshot.get("balls", snapshot)
	var state: Variant = null
	if balls is Dictionary:
		state = balls.get(ball_id, balls.get(str(ball_id), null))
	elif balls is Array:
		for candidate in balls:
			if candidate is Dictionary and candidate.get("id", candidate.get("ball_id", -1)) == ball_id:
				state = candidate
				break
	if not state is Dictionary:
		return "snapshot() has no Dictionary state for ball %s" % ball_id
	if not (state.has("position") or state.has("global_position")):
		return "snapshot ball %s lacks position" % ball_id
	if not (state.has("velocity") or state.has("linear_velocity")):
		return "snapshot ball %s lacks velocity" % ball_id
	if not _position(state) is Vector3 or not _velocity(state) is Vector3:
		return "snapshot ball %s position and velocity must be Vector3" % ball_id
	return state


func _position(state: Dictionary) -> Vector3:
	var value: Variant = state.get("position", state.get("global_position"))
	return value


func _velocity(state: Dictionary) -> Vector3:
	var value: Variant = state.get("velocity", state.get("linear_velocity"))
	return value


func _states_match(left: Dictionary, right: Dictionary, tolerance: float) -> bool:
	return _vector_distance(_position(left), _position(right)) <= tolerance and _vector_distance(_velocity(left), _velocity(right)) <= tolerance


func _vector_distance(left: Vector3, right: Vector3) -> float:
	return left.distance_to(right)


func _free_world(world: Variant) -> void:
	if world is Node:
		world.free()
