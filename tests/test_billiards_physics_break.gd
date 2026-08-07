class_name BilliardsPhysicsBreakTests
extends "res://tests/billiards_physics_test_harness.gd"

## Full 15-ball tangent-rack break: impulse propagation, settle timing, and
## the dead-center cue stun.


func run() -> void:
	_run_case("production tangent-rack break propagation", _test_production_tangent_rack_break_propagation)
	_run_case("production tangent-rack break settles once", _test_production_tangent_rack_break_settles_once)
	_run_case("tangent resting rack sleeps without contacts", _test_tangent_resting_rack_sleeps_without_contacts)
	_run_case("dead-center break cue stuns and settles", _test_dead_center_break_cue_stuns_and_settles)


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
