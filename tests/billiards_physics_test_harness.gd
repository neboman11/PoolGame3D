extends RefCounted

## Shared harness for the BilliardsPhysics deterministic test suites: config
## presets, a disposable BilliardsPhysics-adapter world, and pass/fail
## bookkeeping. Category suites (test_billiards_physics_*.gd) extend this by
## path rather than declaring their own class_name.
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


func _run_case(label: String, test: Callable) -> void:
	var result: Variant = test.call()
	if result == "":
		_passed += 1
		print("PASS: %s" % label)
	else:
		_failed.append("%s: %s" % [label, str(result)])


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


func results() -> Dictionary:
	return {"passed": _passed, "failed": _failed}
