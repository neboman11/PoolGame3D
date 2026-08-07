class_name BilliardsPhysicsPocketsTests
extends "res://tests/billiards_physics_test_harness.gd"

## Pocket capture geometry: approach gating, corner-jaw deflection, mouth
## annulus creep, and full-power entry across pocket types.


func run() -> void:
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
