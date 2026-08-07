class_name BilliardsPhysics
extends Node

## Deterministic, scene-independent billiards solver.  It stores its own ball
## state, then mirrors registered BilliardsBall nodes after every fixed step.
## Table descriptors are dictionaries: finite `cushion`/`static` boxes,
## simple cushion planes, pockets, or custom static collision hooks.

signal ball_pocketed(ball)
signal balls_settled
signal ball_contacted(a, b)
signal ball_hit_cushion(ball, cushion_id)
signal ball_entered_pocket(ball, pocket_id)

@export var fixed_step := 1.0 / 180.0
@export_range(1, 16, 1) var substeps := 2
@export var max_catch_up_steps := 8
@export var restitution := 0.92
@export var ball_friction := 0.0
@export var slide_friction := 0.20
@export var roll_friction := 0.075
@export var spin_friction := 0.045
@export var gravity := 49.0
@export var sleep_linear := 0.004
@export var sleep_angular := 0.04
@export var sleep_delay := 0.18
@export var cloth_height := 0.0

# Contact-point slip below this threshold is treated as pure rolling. Keeping
# this explicit matters because the slide impulse changes both linear and
# angular velocity.
const ROLLING_SLIP_THRESHOLD := 0.02
## Tolerate sub-micron float overlap in a deliberately tangent rack. Such a
## resting contact has no collision event and, crucially, must not keep reset
## timers awake forever.
const CONTACT_PENETRATION_EPSILON := 0.00001
const CONTACT_CLOSING_SPEED_EPSILON := 0.0001
## A ball this slow, with its center already past the throat capture circle
## but still within the pocket's visible mouth, has nothing left to hold it
## up over the hole and is captured outright instead of resting on air.
const CREEP_CAPTURE_SPEED := 0.05

var _accumulator := 0.0
var _states: Dictionary = {}
var _nodes: Dictionary = {}
var _descriptors: Array[Dictionary] = []
var _static_collision_hook := Callable()
var _was_settled := true


func _physics_process(delta: float) -> void:
	step(delta)


## Accepts either an Array of descriptors or `{ descriptors = Array, ...settings }`.
func configure(table: Variant) -> void:
	_descriptors.clear()
	if table is Array:
		for descriptor in table:
			if descriptor is Dictionary:
				_descriptors.append(descriptor.duplicate(true))
		return
	if not table is Dictionary:
		push_warning("BilliardsPhysics.configure expects an Array or Dictionary")
		return

	var config: Dictionary = table
	if config.has("cloth_height"):
		cloth_height = float(config["cloth_height"])
	if config.has("gravity"):
		gravity = float(config["gravity"])
	if config.has("restitution"):
		restitution = float(config["restitution"])
	if config.has("ball_restitution"):
		restitution = float(config["ball_restitution"])
	if config.has("rolling_friction"):
		roll_friction = float(config["rolling_friction"])
	if config.has("roll_friction"):
		roll_friction = float(config["roll_friction"])
	if config.has("sliding_friction"):
		slide_friction = float(config["sliding_friction"])
	if config.has("slide_friction"):
		slide_friction = float(config["slide_friction"])
	if config.has("spin_friction"):
		spin_friction = float(config["spin_friction"])
	if config.has("ball_friction"):
		ball_friction = float(config["ball_friction"])
	if config.has("collision_friction"):
		ball_friction = float(config["collision_friction"])
	if config.has("descriptors"):
		_append_descriptors(config["descriptors"])
	elif config.has("colliders"):
		_append_descriptors(config["colliders"])
	elif config.has("table"):
		_append_descriptors(config["table"])


func set_static_collision_hook(hook: Callable) -> void:
	_static_collision_hook = hook


func register_ball(ball: BilliardsBall) -> void:
	if ball == null:
		return
	var id: Variant = ball.ball_number
	if _states.has(id):
		_nodes[id] = ball
		ball.set_custom_solver_active(true)
		_write_node_state(id)
		return
	ball.set_custom_solver_active(true)
	add_ball(id, ball.global_position, ball.physics_velocity, BilliardsBall.RADIUS, BilliardsBall.MASS, ball.physics_angular_velocity)
	var state: Dictionary = _states[id]
	state["orientation"] = ball.global_transform.basis.get_rotation_quaternion()
	_states[id] = state
	_nodes[id] = ball
	_write_node_state(id)


## Re-enters a scratched ball without changing registration order or id.
func restore_ball(ball: BilliardsBall, position: Vector3) -> void:
	if ball == null:
		return
	var id: Variant = ball.ball_number
	ball.reset_to(position)
	ball.set_custom_solver_active(true)
	_nodes[id] = ball
	if not _states.has(id):
		add_ball(id, position, Vector3.ZERO, BilliardsBall.RADIUS, BilliardsBall.MASS)
		return
	var state: Dictionary = _states[id]
	state["position"] = position
	state["velocity"] = Vector3.ZERO
	state["angular_velocity"] = Vector3.ZERO
	state["orientation"] = Quaternion.IDENTITY
	state["pocketed"] = false
	state["sleeping"] = false
	state["rest_time"] = 0.0
	_states[id] = state
	_was_settled = false
	_write_node_state(id)


## Drops a single ball out of solver tracking so it stops being written back
## every physics tick (used while the player is free-placing it by hand).
func unregister_ball(ball: Variant) -> void:
	var id: Variant = _id_for_ball(ball)
	_nodes.erase(id)
	_states.erase(id)


func unregister_all() -> void:
	for id in _nodes:
		var ball: BilliardsBall = _nodes[id]
		if is_instance_valid(ball):
			ball.set_custom_solver_active(false)
	_nodes.clear()
	_states.clear()
	_accumulator = 0.0
	_was_settled = true


## Pure-state API.  Angular velocity is optional so simple tests stay concise.
func add_ball(id: Variant, position: Vector3, velocity := Vector3.ZERO, radius := BilliardsBall.RADIUS, mass := BilliardsBall.MASS, angular_velocity := Vector3.ZERO) -> void:
	var safe_radius: float = maxf(float(radius), 0.0001)
	var safe_mass: float = maxf(float(mass), 0.0001)
	_states[id] = {
		"id": id,
		"position": position,
		"velocity": velocity,
		"transport_velocity": velocity,
		"angular_velocity": angular_velocity,
		"orientation": Quaternion.IDENTITY,
		"radius": safe_radius,
		"mass": safe_mass,
		"inertia": 0.4 * safe_mass * safe_radius * safe_radius,
		"sleeping": false,
		"rest_time": 0.0,
		"pocketed": false,
	}
	_was_settled = false


func reset() -> void:
	unregister_all()


## Uses a fixed accumulator, so results do not depend on render frame rate.
func step(delta: float) -> void:
	if fixed_step <= 0.0 or delta <= 0.0:
		return
	_accumulator += min(delta, fixed_step * float(max_catch_up_steps))
	var steps := 0
	while _accumulator + 0.000000001 >= fixed_step and steps < max_catch_up_steps:
		_solve_fixed_step(fixed_step)
		_accumulator -= fixed_step
		steps += 1
	_sync_nodes()
	_emit_settled_if_needed()


func strike_ball(ball: Variant, impulse: Vector3, contact_offset := Vector3.ZERO) -> void:
	var id: Variant = _id_for_ball(ball)
	if not _states.has(id):
		return
	var state: Dictionary = _states[id]
	if bool(state["pocketed"]):
		return
	var offset := contact_offset
	if offset.length_squared() <= 0.000000001:
		offset = Vector3.ZERO
	state["velocity"] += impulse / float(state["mass"])
	state["angular_velocity"] += offset.cross(impulse) / float(state["inertia"])
	state["transport_velocity"] = state["velocity"]
	state["sleeping"] = false
	state["rest_time"] = 0.0
	_states[id] = state
	_was_settled = false


func is_settled() -> bool:
	for id in _states:
		var state: Dictionary = _states[id]
		if not bool(state["pocketed"]) and not bool(state["sleeping"]):
			return false
	return true


## State is keyed by caller-provided id.  Values are copies, safe to inspect.
func snapshot() -> Dictionary:
	var result: Dictionary = {}
	for id in _ordered_ids():
		var state: Dictionary = _states[id]
		result[id] = {
			"id": state["id"],
			"position": state["position"],
			"velocity": state["velocity"],
			"angular_velocity": state["angular_velocity"],
			"orientation": state.get("orientation", Quaternion.IDENTITY),
			"radius": state["radius"],
			"mass": state["mass"],
			"sleeping": state["sleeping"],
			"pocketed": state["pocketed"],
		}
	return result


func _append_descriptors(value: Variant) -> void:
	if not value is Array:
		return
	for descriptor in value:
		if descriptor is Dictionary:
			_descriptors.append(descriptor.duplicate(true))


func _solve_fixed_step(dt: float) -> void:
	if _states.is_empty():
		return
	var sub_dt := dt / float(substeps)
	for _substep in substeps:
		_integrate_cloth(sub_dt)
		_integrate_positions(sub_dt)
		_resolve_ball_pairs()
		_resolve_table(sub_dt)
		_update_sleep(sub_dt)


func _integrate_cloth(dt: float) -> void:
	for id in _ordered_ids():
		var state: Dictionary = _states[id]
		if bool(state["pocketed"]) or bool(state["sleeping"]):
			continue
		var velocity: Vector3 = state["velocity"]
		var angular_velocity: Vector3 = state["angular_velocity"]
		var radius: float = state["radius"]
		var contact_offset := Vector3(0.0, -radius, 0.0)
		var slip := velocity + angular_velocity.cross(contact_offset)
		slip.y = 0.0
		var horizontal := Vector3(velocity.x, 0.0, velocity.z)
		var horizontal_spin := Vector3(angular_velocity.x, 0.0, angular_velocity.z)
		# A near-stationary ball can retain horizontal spin whose contact slip is
		# below the normal rolling threshold but still above rest tolerance. It is
		# not rolling: there is no matching translation. Feed that slip through
		# the sliding impulse so it becomes a decaying rolling state instead of an
		# immortal angular velocity that blocks is_settled().
		var recovers_residual_spin := slip.length() > sleep_linear and horizontal_spin.length() > sleep_angular
		var is_sliding := (slip.length() > ROLLING_SLIP_THRESHOLD or recovers_residual_spin) and slide_friction > 0.0
		if is_sliding:
			var dv := -slip.normalized() * slide_friction * gravity * dt
			# A cloth impulse changes contact slip through both translation and
			# rotation. For a solid sphere the response is 1 + m*r^2/I = 3.5,
			# so clamping only to `slip` overshoots and can make a live ball
			# alternate forever between two slipping states.
			var slip_response := 1.0 + float(state["mass"]) * radius * radius / float(state["inertia"])
			var max_slide_dv := slip.length() / slip_response
			if dv.length() > max_slide_dv:
				dv = -slip.normalized() * max_slide_dv
			velocity += dv
			var force := dv * (float(state["mass"]) / dt)
			angular_velocity += contact_offset.cross(force) * (dt / float(state["inertia"]))
			state["transport_velocity"] = velocity
		else:
			if horizontal.length() > 0.0001:
				var roll_dv := -horizontal.normalized() * roll_friction * gravity * dt
				if roll_dv.length() > horizontal.length():
					roll_dv = -horizontal
				velocity += roll_dv
				# Once cloth slip has settled, rolling resistance must preserve the
				# rolling constraint. Otherwise reducing linear velocity alone
				# recreates slip on the next substep and can re-enter slide mode.
				if slip.length() <= ROLLING_SLIP_THRESHOLD:
					angular_velocity += roll_dv.cross(contact_offset) / (radius * radius)
				# Integrate position at the midpoint of this velocity update.  Assign
				# rather than accumulate: each substep has a new velocity interval.
				state["transport_velocity"] = velocity - roll_dv * 0.5
		if abs(angular_velocity.y) > 0.0:
			angular_velocity.y += -sign(angular_velocity.y) * min(abs(angular_velocity.y), spin_friction * gravity * dt / radius)
		velocity.y = 0.0
		state["velocity"] = velocity
		state["angular_velocity"] = angular_velocity
		_states[id] = state


func _integrate_positions(dt: float) -> void:
	for id in _ordered_ids():
		var state: Dictionary = _states[id]
		if bool(state["pocketed"]) or bool(state["sleeping"]):
			continue
		var position: Vector3 = state["position"]
		position += state.get("transport_velocity", state["velocity"]) * dt
		position.y = cloth_height + float(state["radius"])
		var angular_velocity: Vector3 = state["angular_velocity"]
		var angular_speed := angular_velocity.length()
		if angular_speed > 0.000000001:
			# Solver angular velocity is in world axes, so compose its incremental
			# rotation on the left. Normalizing prevents long rolls accumulating
			# scale/skew in the rendered sphere's transform.
			var orientation: Quaternion = state.get("orientation", Quaternion.IDENTITY)
			orientation = (Quaternion(angular_velocity / angular_speed, angular_speed * dt) * orientation).normalized()
			state["orientation"] = orientation
		state["position"] = position
		_states[id] = state


func _resolve_ball_pairs() -> void:
	var ids := _ordered_ids()
	for i in range(ids.size()):
		for j in range(i + 1, ids.size()):
			var first: Dictionary = _states[ids[i]]
			var second: Dictionary = _states[ids[j]]
			if bool(first["pocketed"]) or bool(second["pocketed"]):
				continue
			var delta: Vector3 = second["position"] - first["position"]
			delta.y = 0.0
			var contact_distance: float = float(first["radius"]) + float(second["radius"])
			if delta.length_squared() >= contact_distance * contact_distance:
				continue
			var normal := _stable_normal(delta, ids[i], ids[j])
			var penetration: float = maxf(contact_distance - delta.length(), 0.0)
			if _resolve_contact(ids[i], ids[j], normal, penetration, restitution, ball_friction):
				ball_contacted.emit(_event_subject(ids[i]), _event_subject(ids[j]))


func _resolve_table(dt: float) -> void:
	for id in _ordered_ids():
		if not _states.has(id):
			continue
		var state: Dictionary = _states[id]
		if bool(state["pocketed"]):
			continue
		# Resolve a valid pocket entry before its surrounding jaw or rail boxes.
		# The capture test already requires an inward shot, throat alignment and a
		# cleared shelf, so this does not make cushions absorb balls.  It does stop
		# a fast, centered side-pocket shot from being reflected by a jaw in the
		# same substep before it can fall through the mouth.
		for descriptor in _descriptors:
			if _try_pocket(id, descriptor):
				break
		if bool(_states[id]["pocketed"]):
			continue
		for descriptor in _descriptors:
			if not bool(descriptor.get("solver_enabled", true)):
				continue
			if _is_cushion(descriptor):
				_resolve_cushion(id, descriptor)
			if str(descriptor.get("type", "")) == "static":
				_resolve_static_descriptor(id, descriptor, dt)
		if _states.has(id):
			_resolve_global_static_hook(id, dt)


func _try_pocket(id: Variant, descriptor: Dictionary) -> bool:
	if str(descriptor.get("type", "")) != "pocket":
		return false
	var state: Dictionary = _states[id]
	var center: Vector3 = descriptor.get("center", descriptor.get("position", Vector3.ZERO))
	var delta: Vector3 = state["position"] - center
	delta.y = 0.0
	var throat_width := float(descriptor.get("throat_width", 0.0))
	var mouth_width := float(descriptor.get("mouth_width", 0.0))
	var capture_radius := float(descriptor.get("capture_radius", descriptor.get("radius", throat_width * 0.5)))
	var mouth_radius := mouth_width * 0.5
	var distance := delta.length()
	# A ball that has slowed almost to a stop while its center is still over
	# the visible mouth (beyond the narrower throat capture circle) has
	# nothing physically holding it up there - the shelf/lateral gates below
	# only make sense for a ball still moving along the rail. Without this it
	# can settle resting half over the open hole, clipping the pocket mesh.
	if mouth_radius > capture_radius and distance <= mouth_radius:
		var creep_speed: Vector3 = state["velocity"]
		if creep_speed.length() <= CREEP_CAPTURE_SPEED:
			_mark_pocketed(id, descriptor.get("id", id), true, descriptor)
			return true
	if capture_radius <= 0.0 or distance > capture_radius:
		return false
	var approach_direction := _pocket_approach_direction(descriptor)
	if approach_direction.length_squared() > 0.000000001:
		var lateral := Vector3(-approach_direction.z, 0.0, approach_direction.x)
		var lateral_limit := throat_width * 0.5 if throat_width > 0.0 else mouth_width * 0.5
		if lateral_limit > 0.0 and abs(delta.dot(lateral)) > lateral_limit:
			return false
		var shelf_depth := float(descriptor.get("shelf_depth", 0.0))
		# The approach vector points from the cloth toward the drop. Test the ball
		# center against the shelf plane itself: adding the radius puts this guard
		# beyond the capture circle (corner capture < shelf + ball radius), making
		# it unreachable and swallowing balls that are still on the shelf.
		if shelf_depth > 0.0 and delta.dot(approach_direction) < -shelf_depth:
			return false
		var velocity: Vector3 = state["velocity"]
		if velocity.length() > 0.02 and velocity.dot(approach_direction) <= 0.0:
			return false
	_mark_pocketed(id, descriptor.get("id", id), true, descriptor)
	return true


func _mark_pocketed(id: Variant, pocket_id: Variant, invoke_ball: bool, descriptor: Dictionary = {}) -> void:
	if not _states.has(id) or bool(_states[id]["pocketed"]):
		return
	var state: Dictionary = _states[id]
	state["pocketed"] = true
	state["velocity"] = Vector3.ZERO
	state["angular_velocity"] = Vector3.ZERO
	state["orientation"] = Quaternion.IDENTITY
	state["sleeping"] = true
	_states[id] = state
	var subject: Variant = _event_subject(id)
	ball_entered_pocket.emit(subject, pocket_id)
	if invoke_ball and subject is BilliardsBall:
		var pocket_center: Vector3 = descriptor.get(
			"drop_center",
			descriptor.get("center", descriptor.get("position", subject.global_position))
		)
		var drop_depth := float(descriptor.get("drop_depth", descriptor.get("trigger_height", 0.64)))
		subject.pocket(pocket_center, drop_depth)
	ball_pocketed.emit(subject)


func _is_cushion(descriptor: Dictionary) -> bool:
	var kind := str(descriptor.get("type", ""))
	return kind == "cushion" or kind == "plane"


## A descriptor with center/size is a finite oriented box.  Otherwise this
## preserves the simple inward-normal plane contract used by pure-state tests.
func _resolve_cushion(id: Variant, descriptor: Dictionary) -> void:
	if descriptor.has("center") and descriptor.has("size"):
		_resolve_oriented_box(id, descriptor)
		return
	var state: Dictionary = _states[id]
	var normal: Vector3 = descriptor.get("normal", Vector3.ZERO)
	normal.y = 0.0
	if normal.length_squared() <= 0.000000001:
		return
	normal = normal.normalized()
	var point: Vector3 = descriptor.get("point", Vector3.ZERO)
	var offset := float(descriptor.get("offset", normal.dot(point)))
	var position: Vector3 = state["position"]
	var distance := normal.dot(position) - offset
	var penetration := float(state["radius"]) - distance
	if penetration <= 0.0:
		return
	position += normal * penetration
	state["position"] = position
	_states[id] = state
	_resolve_static_contact(id, normal, descriptor.get("point", position - normal * float(state["radius"])), float(descriptor.get("restitution", restitution)), float(descriptor.get("friction", ball_friction)))
	ball_hit_cushion.emit(_event_subject(id), descriptor.get("id", "cushion"))


func _resolve_oriented_box(id: Variant, descriptor: Dictionary) -> void:
	var state: Dictionary = _states[id]
	var center: Vector3 = descriptor["center"]
	var size: Vector3 = descriptor["size"]
	var half_size := Vector3(maxf(size.x * 0.5, 0.0), maxf(size.y * 0.5, 0.0), maxf(size.z * 0.5, 0.0))
	if half_size.length_squared() <= 0.000000001:
		return
	var rotation_y := float(descriptor.get("rotation_y", 0.0))
	var axis_x := Vector3(cos(rotation_y), 0.0, -sin(rotation_y))
	var axis_z := Vector3(sin(rotation_y), 0.0, cos(rotation_y))
	var position: Vector3 = state["position"]
	var from_center := position - center
	var local := Vector3(from_center.dot(axis_x), from_center.y, from_center.dot(axis_z))
	var closest_local := Vector3(
		clampf(local.x, -half_size.x, half_size.x),
		clampf(local.y, -half_size.y, half_size.y),
		clampf(local.z, -half_size.z, half_size.z)
	)
	var closest_point := center + axis_x * closest_local.x + Vector3.UP * closest_local.y + axis_z * closest_local.z
	var separation := position - closest_point
	var distance_squared := separation.length_squared()
	var radius: float = state["radius"]
	if distance_squared >= radius * radius:
		return
	var normal: Vector3
	var distance := sqrt(distance_squared)
	if distance > 0.000001:
		normal = separation / distance
	else:
		normal = _inside_box_normal(local, half_size, axis_x, axis_z, descriptor)
		distance = 0.0
	var penetration := radius - distance
	position += normal * penetration
	state["position"] = position
	_states[id] = state
	_resolve_static_contact(id, normal, closest_point, float(descriptor.get("restitution", restitution)), float(descriptor.get("friction", ball_friction)))
	ball_hit_cushion.emit(_event_subject(id), descriptor.get("id", "cushion"))


func _inside_box_normal(local: Vector3, half_size: Vector3, axis_x: Vector3, axis_z: Vector3, descriptor: Dictionary) -> Vector3:
	var distances := [half_size.x - abs(local.x), half_size.y - abs(local.y), half_size.z - abs(local.z)]
	var nearest_axis := 0
	if distances[1] < distances[nearest_axis]:
		nearest_axis = 1
	if distances[2] < distances[nearest_axis]:
		nearest_axis = 2
	var descriptor_normal: Vector3 = descriptor.get("normal", Vector3.ZERO)
	if nearest_axis == 0:
		var x_sign: float = signf(local.x)
		if x_sign == 0.0:
			x_sign = signf(descriptor_normal.dot(axis_x))
		return axis_x * (x_sign if x_sign != 0.0 else 1.0)
	if nearest_axis == 1:
		var y_sign: float = signf(local.y)
		if y_sign == 0.0:
			y_sign = signf(descriptor_normal.y)
		return Vector3.UP * (y_sign if y_sign != 0.0 else 1.0)
	var z_sign: float = signf(local.z)
	if z_sign == 0.0:
		z_sign = signf(descriptor_normal.dot(axis_z))
	return axis_z * (z_sign if z_sign != 0.0 else 1.0)


func _pocket_approach_direction(descriptor: Dictionary) -> Vector3:
	var approach: Vector3 = descriptor.get("approach_direction", Vector3.ZERO)
	if approach.length_squared() <= 0.000000001:
		var inward: Vector3 = descriptor.get("inward_normal", Vector3.ZERO)
		approach = -inward
	approach.y = 0.0
	return approach.normalized() if approach.length_squared() > 0.000000001 else Vector3.ZERO


## A static descriptor's `hook` receives a state snapshot and substep duration.
## It may return one contact Dictionary or an Array of contact Dictionaries.
func _resolve_static_descriptor(id: Variant, descriptor: Dictionary, dt: float) -> void:
	var hook: Callable = descriptor.get("hook", Callable())
	if hook.is_valid():
		_apply_hook_contacts(id, hook.call(_state_copy(id), dt))
	elif descriptor.has("normal") or (descriptor.has("center") and descriptor.has("size")):
		_resolve_cushion(id, descriptor)


func _resolve_global_static_hook(id: Variant, dt: float) -> void:
	if _static_collision_hook.is_valid() and not bool(_states[id]["pocketed"]):
		_apply_hook_contacts(id, _static_collision_hook.call(_state_copy(id), dt))


func _apply_hook_contacts(id: Variant, result: Variant) -> void:
	if result is Dictionary:
		_apply_static_contact(id, result)
	elif result is Array:
		for contact in result:
			if contact is Dictionary:
				_apply_static_contact(id, contact)


func _apply_static_contact(id: Variant, contact: Dictionary) -> void:
	var normal: Vector3 = contact.get("normal", Vector3.ZERO)
	if normal.length_squared() <= 0.000000001:
		return
	normal = normal.normalized()
	var penetration := float(contact.get("penetration", 0.0))
	if penetration > 0.0:
		var state: Dictionary = _states[id]
		state["position"] += normal * penetration
		_states[id] = state
	_resolve_static_contact(id, normal, contact.get("point", _states[id]["position"]), float(contact.get("restitution", restitution)), float(contact.get("friction", ball_friction)))
	ball_hit_cushion.emit(_event_subject(id), contact.get("id", "static"))


func _resolve_static_contact(id: Variant, normal: Vector3, point: Vector3, contact_restitution: float, contact_friction: float) -> void:
	var state: Dictionary = _states[id]
	var radius: float = state["radius"]
	var center: Vector3 = state["position"]
	var radius_vector := point - center
	if radius_vector.length_squared() <= 0.000000001:
		radius_vector = -normal * radius
	var velocity_at_contact: Vector3 = state["velocity"] + state["angular_velocity"].cross(radius_vector)
	var normal_speed := velocity_at_contact.dot(normal)
	if normal_speed >= 0.0:
		return
	var inverse_mass := 1.0 / float(state["mass"])
	var normal_mass := inverse_mass + _rotational_inverse_mass(state, radius_vector, normal)
	var normal_impulse: float = -(1.0 + contact_restitution) * normal_speed / maxf(normal_mass, 0.000001)
	_apply_static_impulse(state, radius_vector, normal * normal_impulse)

	velocity_at_contact = state["velocity"] + state["angular_velocity"].cross(radius_vector)
	var tangent := velocity_at_contact - normal * velocity_at_contact.dot(normal)
	if tangent.length_squared() > 0.000000001:
		tangent = tangent.normalized()
		var tangent_mass := inverse_mass + _rotational_inverse_mass(state, radius_vector, tangent)
		var tangent_impulse: float = -velocity_at_contact.dot(tangent) / maxf(tangent_mass, 0.000001)
		tangent_impulse = clamp(tangent_impulse, -contact_friction * normal_impulse, contact_friction * normal_impulse)
		_apply_static_impulse(state, radius_vector, tangent * tangent_impulse)
	state["sleeping"] = false
	state["rest_time"] = 0.0
	state["transport_velocity"] = state["velocity"]
	_states[id] = state


func _resolve_contact(first_id: Variant, second_id: Variant, normal: Vector3, penetration: float, contact_restitution: float, contact_friction: float) -> bool:
	var first: Dictionary = _states[first_id]
	var second: Dictionary = _states[second_id]
	var first_radius_vector := normal * float(first["radius"])
	var second_radius_vector := -normal * float(second["radius"])
	var first_contact_velocity: Vector3 = first["velocity"] + first["angular_velocity"].cross(first_radius_vector)
	var second_contact_velocity: Vector3 = second["velocity"] + second["angular_velocity"].cross(second_radius_vector)
	var relative := second_contact_velocity - first_contact_velocity
	var normal_speed := relative.dot(normal)
	var has_penetration := penetration > CONTACT_PENETRATION_EPSILON
	var has_closing_impact := normal_speed < -CONTACT_CLOSING_SPEED_EPSILON
	if not has_penetration and not has_closing_impact:
		return false
	# Positional correction follows the same inverse-mass weighting as the
	# impulse. A heavier ball must not be displaced as far as a lighter one
	# merely because the pair was found overlapping in a fixed substep.
	var first_inverse_mass := 1.0 / float(first["mass"])
	var second_inverse_mass := 1.0 / float(second["mass"])
	var total_inverse_mass := first_inverse_mass + second_inverse_mass
	var correction := normal * (penetration + 0.000002) / maxf(total_inverse_mass, 0.000001)
	first["position"] -= correction * first_inverse_mass
	second["position"] += correction * second_inverse_mass
	if has_closing_impact:
		var normal_mass := _inverse_pair_mass(first, first_radius_vector, second, second_radius_vector, normal)
		var impulse_amount: float = -(1.0 + contact_restitution) * normal_speed / maxf(normal_mass, 0.000001)
		var impulse: Vector3 = normal * impulse_amount
		_apply_pair_impulse(first, first_radius_vector, second, second_radius_vector, impulse)
		first_contact_velocity = first["velocity"] + first["angular_velocity"].cross(first_radius_vector)
		second_contact_velocity = second["velocity"] + second["angular_velocity"].cross(second_radius_vector)
		relative = second_contact_velocity - first_contact_velocity
		var tangent := relative - normal * relative.dot(normal)
		if tangent.length_squared() > 0.000000001:
			tangent = tangent.normalized()
			var tangent_mass := _inverse_pair_mass(first, first_radius_vector, second, second_radius_vector, tangent)
			var tangent_amount: float = -relative.dot(tangent) / maxf(tangent_mass, 0.000001)
			tangent_amount = clamp(tangent_amount, -contact_friction * impulse_amount, contact_friction * impulse_amount)
			_apply_pair_impulse(first, first_radius_vector, second, second_radius_vector, tangent * tangent_amount)
	first["sleeping"] = false
	second["sleeping"] = false
	first["rest_time"] = 0.0
	second["rest_time"] = 0.0
	first["transport_velocity"] = first["velocity"]
	second["transport_velocity"] = second["velocity"]
	_states[first_id] = first
	_states[second_id] = second
	return true


func _apply_pair_impulse(first: Dictionary, first_radius_vector: Vector3, second: Dictionary, second_radius_vector: Vector3, impulse: Vector3) -> void:
	first["velocity"] -= impulse / float(first["mass"])
	second["velocity"] += impulse / float(second["mass"])
	first["angular_velocity"] -= first_radius_vector.cross(impulse) / float(first["inertia"])
	second["angular_velocity"] += second_radius_vector.cross(impulse) / float(second["inertia"])


func _apply_static_impulse(state: Dictionary, radius_vector: Vector3, impulse: Vector3) -> void:
	state["velocity"] += impulse / float(state["mass"])
	state["angular_velocity"] += radius_vector.cross(impulse) / float(state["inertia"])


func _inverse_pair_mass(first: Dictionary, first_radius_vector: Vector3, second: Dictionary, second_radius_vector: Vector3, direction: Vector3) -> float:
	return 1.0 / float(first["mass"]) + 1.0 / float(second["mass"]) + _rotational_inverse_mass(first, first_radius_vector, direction) + _rotational_inverse_mass(second, second_radius_vector, direction)


func _rotational_inverse_mass(state: Dictionary, radius_vector: Vector3, direction: Vector3) -> float:
	var angular_delta := radius_vector.cross(direction) / float(state["inertia"])
	return direction.dot(angular_delta.cross(radius_vector))


func _update_sleep(dt: float) -> void:
	for id in _ordered_ids():
		var state: Dictionary = _states[id]
		if bool(state["pocketed"]):
			continue
		if state["velocity"].length() <= sleep_linear and state["angular_velocity"].length() <= sleep_angular:
			state["rest_time"] += dt
			if float(state["rest_time"]) >= sleep_delay:
				state["velocity"] = Vector3.ZERO
				state["transport_velocity"] = Vector3.ZERO
				state["angular_velocity"] = Vector3.ZERO
				state["sleeping"] = true
		else:
			state["rest_time"] = 0.0
			state["sleeping"] = false
		_states[id] = state


func _sync_nodes() -> void:
	for id in _ordered_ids():
		if _nodes.has(id) and is_instance_valid(_nodes[id]) and _nodes[id].pocketed and not bool(_states[id]["pocketed"]):
			_mark_pocketed(id, id, false)
		_write_node_state(id)


func _write_node_state(id: Variant) -> void:
	if not _nodes.has(id) or not _states.has(id):
		return
	var ball: BilliardsBall = _nodes[id]
	if not is_instance_valid(ball):
		_nodes.erase(id)
		return
	var state: Dictionary = _states[id]
	if bool(state["pocketed"]):
		return
	ball.set_custom_state(state["position"], state["velocity"], state["angular_velocity"], state["sleeping"])
	var orientation: Variant = state.get("orientation", null)
	if orientation is Quaternion:
		var visual_transform := ball.global_transform
		visual_transform.basis = Basis(orientation)
		ball.global_transform = visual_transform


func _emit_settled_if_needed() -> void:
	var settled := is_settled()
	if settled and not _was_settled:
		balls_settled.emit()
	_was_settled = settled


func _id_for_ball(ball: Variant) -> Variant:
	if ball is BilliardsBall:
		return ball.ball_number
	return ball


func _event_subject(id: Variant) -> Variant:
	if _nodes.has(id) and is_instance_valid(_nodes[id]):
		return _nodes[id]
	return id


func _state_copy(id: Variant) -> Dictionary:
	var state: Dictionary = _states[id]
	return {
		"id": state["id"],
		"position": state["position"],
		"velocity": state["velocity"],
		"angular_velocity": state["angular_velocity"],
		"radius": state["radius"],
		"mass": state["mass"],
		"sleeping": state["sleeping"],
		"pocketed": state["pocketed"],
	}


func _stable_normal(delta: Vector3, first_id: Variant, second_id: Variant) -> Vector3:
	if delta.length_squared() > 0.000000001:
		return delta.normalized()
	# Coincident centres need a reproducible separating axis.
	return Vector3.RIGHT if _id_before(first_id, second_id) else Vector3.FORWARD


func _ordered_ids() -> Array:
	var ordered: Array = []
	for id in _states:
		var insert_at := ordered.size()
		for index in range(ordered.size()):
			if _id_before(id, ordered[index]):
				insert_at = index
				break
		ordered.insert(insert_at, id)
	return ordered


func _id_before(left: Variant, right: Variant) -> bool:
	if left is int and right is int:
		return left < right
	if left is float and right is float:
		return left < right
	return str(left) < str(right)
