extends Node3D

## Togglable pre-shot prediction guide. Draws the cue ball's path - including
## up to MAX_RAIL_BOUNCES cushion bounces - to its first impact, then two
## post-impact vector lines: one for the cue ball, one for the ball it
## strikes, pointing in the predicted direction of motion with length
## proportional to predicted speed.
##
## The preview runs the real BilliardsPhysics solver on a disposable, off-tree
## clone of the current table state rather than a separate formula, so spin,
## friction and restitution all match live gameplay exactly. The clone and
## its table configuration are built once and reused every frame - only the
## ball positions are reset - to keep this affordable at interactive rates.
##
## The simulation itself runs on a WorkerThreadPool task rather than the main
## thread, so a slow (multi-bounce) trace never stalls rendering. BilliardsPhysics
## is plain state (Dictionaries/Vectors) with no scene-tree or RenderingServer
## access when driven through its pure-state API (add_ball/strike_ball/step), so
## it is safe to run off the main thread as long as only one thread touches the
## shadow instance at a time - enforced here by never starting a new task while
## one is still in flight.

const MAX_RAIL_BOUNCES := 4
# Generous safety net (~16 sim-seconds at the live solver's own 1/180s step) so
# a long, multi-bounce trace always reaches its target ball or natural stop
# instead of being cut off mid-table. Affordable because this now runs off the
# main thread - the shadow uses the same fixed_step/substeps as live gameplay,
# so the traced path always matches what would actually happen.
const MAX_PREVIEW_STEPS := 3000
# With Settings.extended_aim_preview on, the trace keeps going past the cue
# ball's first contact - following every ball it (or a ball it struck) goes on
# to hit, so a combo can be lined up visually. Capped so a wild break-like
# scatter can't produce an unbounded number of chain segments to draw.
const MAX_EXTENDED_CONTACTS := 4
const RECOMPUTE_INTERVAL := 0.12
const VECTOR_LINE_SCALE := 0.16 # world units of drawn line per m/s of predicted speed
const AIM_EPSILON := 0.0005
const IMPACT_COLOR := Color(1.0, 0.92, 0.4, 0.9)
const CUE_VECTOR_COLOR := Color(0.35, 0.85, 1.0, 0.95)
const OBJECT_VECTOR_COLOR := Color(1.0, 0.4, 0.3, 0.95)
const CHAIN_PATH_COLOR := Color(1.0, 0.55, 0.15, 0.85)

var game: Node = null
var enabled := false:
	set(value):
		enabled = value
		visible = value
		if not enabled:
			_clear()

var _recompute_elapsed := 0.0
var _shadow: BilliardsPhysics = null
var _shadow_ready := false

# Background prediction task. Only one may be in flight at a time - that is
# what makes it safe for the task thread to own `_shadow` and the fields
# below without a mutex: the main thread never touches them while
# `_task_in_flight` is true.
var _task_id := -1
var _task_in_flight := false
var _pending_result: Dictionary = {}

# Populated by the persistent shadow's signal callbacks while a prediction
# is running, from whichever thread is running _run_prediction(). Reset every
# physics step within that run so the caller can read exactly what happened
# during the step it just took.
var _contact_events_this_step: Array = []
var _cushion_hits_this_step: Array = []
var _cushion_bounce_count := 0

# Pooled line instances for extended-mode combo chain segments - one per ball
# beyond the first struck. Created lazily and reused across frames.
var _chain_lines: Array = []

# Cache of the last inputs a prediction was actually computed for, so an
# unchanged aim (the common case while the player is just holding still)
# skips the shadow simulation entirely instead of re-running it every frame.
var _last_direction := Vector3.ZERO
var _last_tip_offset := Vector3.ZERO
var _last_power := -1.0
var _last_cue_position := Vector3.ZERO
var _has_last_prediction := false

@onready var impact_line: MeshInstance3D = $ImpactLine
@onready var cue_vector_line: MeshInstance3D = $CueVectorLine
@onready var object_vector_line: MeshInstance3D = $ObjectVectorLine


func setup(game_node: Node) -> void:
	game = game_node


func toggle() -> bool:
	enabled = not enabled
	return enabled


func _ready() -> void:
	visible = enabled
	_style_line(impact_line, IMPACT_COLOR)
	_style_line(cue_vector_line, CUE_VECTOR_COLOR)
	_style_line(object_vector_line, OBJECT_VECTOR_COLOR)


func _exit_tree() -> void:
	if _task_in_flight:
		WorkerThreadPool.wait_for_task_completion(_task_id)
		_task_in_flight = false
	if _shadow != null:
		_shadow.free()
		_shadow = null


func _process(delta: float) -> void:
	if game == null:
		return
	_reap_task_if_done()

	if not enabled:
		return
	if game.ai_turn_active:
		_clear()
		_has_last_prediction = false
		return
	_recompute_elapsed += delta
	if _recompute_elapsed < RECOMPUTE_INTERVAL:
		return
	_recompute_elapsed = 0.0

	if game.cue_ball == null or game.cue_ball.pocketed or not game.can_shoot():
		_clear()
		_has_last_prediction = false
		return

	# A prediction is already running - try again next tick rather than
	# starting a second task, since only one may touch _shadow at a time.
	if _task_in_flight:
		return

	var cue_stick: Node = game.cue_stick
	# While the player is actively charging, preview that exact power. Otherwise
	# assume full power - a mid-power guess frequently ran out of momentum after
	# a rail bounce or two, making the path stop well short of any ball even
	# though it wasn't actually capped. Full power always shows the farthest a
	# shot could reach, which is what the pre-impact path is meant to trace.
	var power: float = cue_stick.pull_amount if cue_stick.pull_amount > 0.03 else 1.0
	var strike: Dictionary = cue_stick.predicted_strike(power)
	var direction: Vector3 = strike["direction"]
	var tip_offset: Vector3 = strike["tip_offset"]
	var cue_position: Vector3 = game.cue_ball.global_position

	if _has_last_prediction \
			and direction.is_equal_approx(_last_direction) \
			and tip_offset.is_equal_approx(_last_tip_offset) \
			and is_equal_approx(power, _last_power) \
			and cue_position.distance_squared_to(_last_cue_position) < AIM_EPSILON * AIM_EPSILON:
		return

	_last_direction = direction
	_last_tip_offset = tip_offset
	_last_power = power
	_last_cue_position = cue_position
	_has_last_prediction = true

	_dispatch_prediction(strike, cue_position)


func _dispatch_prediction(strike: Dictionary, cue_position: Vector3) -> void:
	_ensure_shadow()
	var cue_number: int = game.cue_ball.ball_number
	var ball_snapshots: Array = []
	for ball in game.balls:
		if not is_instance_valid(ball) or ball.pocketed:
			continue
		ball_snapshots.append({"number": ball.ball_number, "position": ball.global_position})

	var extended: bool = Settings.extended_aim_preview
	_task_id = WorkerThreadPool.add_task(_run_prediction.bind(strike, cue_position, ball_snapshots, cue_number, extended))
	_task_in_flight = true


func _reap_task_if_done() -> void:
	if not _task_in_flight:
		return
	if not WorkerThreadPool.is_task_completed(_task_id):
		return
	WorkerThreadPool.wait_for_task_completion(_task_id)
	_task_in_flight = false
	var result: Dictionary = _pending_result
	_pending_result = {}

	# Re-check current state at apply-time, not just at dispatch-time - the
	# turn or guide toggle may have changed while the task was computing.
	if not enabled or game.ai_turn_active or game.cue_ball == null or game.cue_ball.pocketed:
		_clear()
		return
	if result.is_empty():
		_clear()
		return
	_draw(result)


func _style_line(mesh_instance: MeshInstance3D, color: Color) -> void:
	mesh_instance.mesh = ImmediateMesh.new()
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.vertex_color_use_as_albedo = true
	material.albedo_color = color
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.no_depth_test = true
	mesh_instance.material_override = material
	mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


func _clear() -> void:
	for mesh_instance in [impact_line, cue_vector_line, object_vector_line]:
		var mesh: ImmediateMesh = mesh_instance.mesh
		mesh.clear_surfaces()
	for chain_line in _chain_lines:
		var chain_mesh: ImmediateMesh = chain_line.mesh
		chain_mesh.clear_surfaces()


func _draw(prediction: Dictionary) -> void:
	_draw_path(impact_line, prediction["path"])
	var impact_point: Vector3 = prediction["impact_point"]
	_draw_segment(cue_vector_line, impact_point, impact_point + prediction["cue_after_direction"] * prediction["cue_after_length"])
	if prediction["has_target"]:
		_draw_segment(object_vector_line, prediction["object_start"], prediction["object_start"] + prediction["object_after_direction"] * prediction["object_after_length"])
	else:
		var mesh: ImmediateMesh = object_vector_line.mesh
		mesh.clear_surfaces()

	var object_paths: Array = prediction.get("object_paths", [])
	for i in range(object_paths.size()):
		_draw_path(_ensure_chain_line(i), object_paths[i])
	for i in range(object_paths.size(), _chain_lines.size()):
		var stale_mesh: ImmediateMesh = _chain_lines[i].mesh
		stale_mesh.clear_surfaces()


func _ensure_chain_line(index: int) -> MeshInstance3D:
	while _chain_lines.size() <= index:
		var chain_line := MeshInstance3D.new()
		add_child(chain_line)
		_style_line(chain_line, CHAIN_PATH_COLOR)
		_chain_lines.append(chain_line)
	return _chain_lines[index]


func _draw_segment(mesh_instance: MeshInstance3D, from: Vector3, to: Vector3) -> void:
	var mesh: ImmediateMesh = mesh_instance.mesh
	mesh.clear_surfaces()
	if from.distance_squared_to(to) < 0.0000001:
		return
	mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	mesh.surface_add_vertex(to_local(from) + Vector3.UP * 0.002)
	mesh.surface_add_vertex(to_local(to) + Vector3.UP * 0.002)
	mesh.surface_end()


func _draw_path(mesh_instance: MeshInstance3D, points: Array) -> void:
	var mesh: ImmediateMesh = mesh_instance.mesh
	mesh.clear_surfaces()
	if points.size() < 2:
		return
	mesh.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
	for point in points:
		mesh.surface_add_vertex(to_local(point) + Vector3.UP * 0.002)
	mesh.surface_end()


func _ensure_shadow() -> void:
	if _shadow_ready:
		return
	_shadow = BilliardsPhysics.new()
	var descriptors: Variant = []
	if game.table.has_method("get_physics_descriptors"):
		descriptors = game.table.get_physics_descriptors()
	var config: Dictionary = {"descriptors": descriptors}
	if game.table.has_method("get_table_calibration"):
		config = game.table.get_table_calibration().duplicate()
		config["descriptors"] = descriptors
	_shadow.configure(config)
	# fixed_step/substeps are left at the class defaults, which match live
	# gameplay (1/180s, 2 substeps) - now that prediction runs off the main
	# thread there is no need to trade accuracy for frame time, and matching
	# live resolution exactly avoids the coarse step missing fast cushion
	# contacts or cutting a trace short before it reaches its target.
	_shadow.ball_contacted.connect(_on_shadow_contact)
	_shadow.ball_hit_cushion.connect(_on_shadow_cushion)
	_shadow_ready = true


func _on_shadow_contact(a: Variant, b: Variant) -> void:
	_contact_events_this_step.append([int(a), int(b)])


func _on_shadow_cushion(ball: Variant, _cushion_id: Variant) -> void:
	_cushion_hits_this_step.append(int(ball))


## Runs a shadow simulation of the current table with the currently aimed
## strike, tracing cushion bounces (up to MAX_RAIL_BOUNCES) until the cue
## ball first contacts another ball. Runs on a WorkerThreadPool thread - must
## not touch `game`, scene nodes, or anything outside its arguments and
## `_shadow` (which the caller guarantees no other thread is using).
func _run_prediction(strike: Dictionary, cue_start: Vector3, ball_snapshots: Array, cue_number: int, extended: bool) -> void:
	_shadow.unregister_all()

	for entry in ball_snapshots:
		_shadow.add_ball(entry["number"], entry["position"], Vector3.ZERO, BilliardsBall.RADIUS, BilliardsBall.MASS, Vector3.ZERO)

	var direction: Vector3 = strike["direction"]
	var impulse: Vector3 = direction * float(strike["transfer_speed"]) * BilliardsBall.MASS
	_shadow.strike_ball(cue_number, impulse, strike["tip_offset"])

	_cushion_bounce_count = 0
	var path: Array = [cue_start]
	var gave_up_on_bounces := false
	var first_contact: Array = []

	var steps := 0
	while first_contact.is_empty() and steps < MAX_PREVIEW_STEPS:
		_contact_events_this_step.clear()
		_cushion_hits_this_step.clear()
		_shadow.step(_shadow.fixed_step)
		steps += 1
		if not _contact_events_this_step.is_empty():
			first_contact = _contact_events_this_step[0]
			break
		if cue_number in _cushion_hits_this_step:
			_cushion_bounce_count += 1
			path.append(_shadow.snapshot()[cue_number]["position"])
			if _cushion_bounce_count > MAX_RAIL_BOUNCES:
				gave_up_on_bounces = true
				break
		if _shadow.is_settled():
			break

	var result := {}
	var snapshot: Dictionary = _shadow.snapshot()
	if first_contact.is_empty():
		if not gave_up_on_bounces:
			path.append(snapshot[cue_number]["position"])
		result = {
			"path": path,
			"impact_point": path[path.size() - 1],
			"cue_after_direction": Vector3.ZERO,
			"cue_after_length": 0.0,
			"has_target": false,
			"object_paths": [],
		}
		_pending_result = result
		return

	var other_id: int = first_contact[1] if first_contact[0] == cue_number else first_contact[0]
	var cue_state: Dictionary = snapshot[cue_number]
	var object_state: Dictionary = snapshot[other_id]
	var cue_velocity: Vector3 = cue_state["velocity"]
	var object_velocity: Vector3 = object_state["velocity"]
	path.append(cue_state["position"])
	result = {
		"path": path,
		"impact_point": cue_state["position"],
		"cue_after_direction": cue_velocity.normalized() if cue_velocity.length() > 0.001 else Vector3.ZERO,
		"cue_after_length": cue_velocity.length() * VECTOR_LINE_SCALE,
		"has_target": true,
		"object_start": object_state["position"],
		"object_after_direction": object_velocity.normalized() if object_velocity.length() > 0.001 else Vector3.ZERO,
		"object_after_length": object_velocity.length() * VECTOR_LINE_SCALE,
		"object_paths": [],
	}
	if extended:
		result["object_paths"] = _trace_extended_chain(other_id, object_state["position"], cue_number)
	_pending_result = result


## Continues the shadow simulation past the cue ball's first contact, following
## the struck ball (and whatever it goes on to hit) through up to
## MAX_EXTENDED_CONTACTS further collisions, so a combo can be lined up
## visually. Returns an array of polylines, one per ball segment in the chain.
## Re-contact with the cue ball itself ends that segment's tracking rather than
## folding the cue ball back into the combo chain.
func _trace_extended_chain(first_ball: int, first_pos: Vector3, cue_number: int) -> Array:
	var chains: Array = []
	var current_ball := first_ball
	var current_path: Array = [first_pos]
	var contacts_traced := 0
	var bounce_count := 0
	var steps := 0

	while contacts_traced < MAX_EXTENDED_CONTACTS and steps < MAX_PREVIEW_STEPS:
		_contact_events_this_step.clear()
		_cushion_hits_this_step.clear()
		_shadow.step(_shadow.fixed_step)
		steps += 1

		var snapshot: Dictionary = _shadow.snapshot()
		var advanced := false
		for event in _contact_events_this_step:
			if current_ball in event:
				var next_ball: int = event[1] if event[0] == current_ball else event[0]
				if next_ball == cue_number:
					continue
				current_path.append(snapshot[current_ball]["position"])
				chains.append(current_path)
				current_ball = next_ball
				current_path = [snapshot[next_ball]["position"]]
				contacts_traced += 1
				bounce_count = 0
				advanced = true
				break
		if advanced:
			continue

		if current_ball in _cushion_hits_this_step:
			bounce_count += 1
			current_path.append(snapshot[current_ball]["position"])
			if bounce_count > MAX_RAIL_BOUNCES:
				break

		if _shadow.is_settled():
			break

	current_path.append(_shadow.snapshot()[current_ball]["position"])
	chains.append(current_path)
	return chains
