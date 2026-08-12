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
# ball's first contact and records every ball that becomes involved in the
# collision sequence, all the way to its final resting position. This is a
# generous 40-second safety net; normal table friction settles much sooner.
const MAX_EXTENDED_PREVIEW_STEPS := 7200
const EXTENDED_PATH_SAMPLE_DISTANCE_SQUARED := 0.0001
# Kept for the legacy sequential helper below; extended preview now uses the
# full-table rollout instead.
const MAX_EXTENDED_CONTACTS := 4
# Aim must hold still this long before a trace is dispatched. Debounced
# rather than throttled: while the camera is being dragged fast the aim
# changes every frame, so no calc ever fires and no backlog can build up.
# The instant it stops, one fresh trace fires using the settled aim - no
# stale mid-drag result lingers because none was ever dispatched for it.
const AIM_SETTLE_DELAY := 0.06
const VECTOR_LINE_SCALE := 0.16 # world units of drawn line per m/s of predicted speed
const AIM_EPSILON := 0.0005
const CUE_PATH_COLOR := Color(0.94, 0.91, 0.83, 0.95)
const STRIPE_ACCENT_COLOR := Color(0.94, 0.91, 0.83, 0.95)
const STRIPE_DASH_LENGTH := 0.045

var game: Node = null
var enabled := false:
	set(value):
		enabled = value
		visible = value
		if not enabled:
			_clear()

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

# Debounce state: tracks the most recent frame's aim so we can tell whether
# it's still changing, independent of whether a dispatch has happened yet.
var _candidate_direction := Vector3.ZERO
var _candidate_tip_offset := Vector3.ZERO
var _candidate_power := -1.0
var _candidate_cue_position := Vector3.ZERO
var _candidate_strike: Dictionary = {}
var _has_candidate := false
var _settle_elapsed := 0.0

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
	_style_line(impact_line)
	_style_line(cue_vector_line)
	_style_line(object_vector_line)


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
		_has_candidate = false
		return
	if game.cue_ball == null or game.cue_ball.pocketed or not game.can_shoot():
		_clear()
		_has_last_prediction = false
		_has_candidate = false
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

	if _has_candidate \
			and direction.is_equal_approx(_candidate_direction) \
			and tip_offset.is_equal_approx(_candidate_tip_offset) \
			and is_equal_approx(power, _candidate_power) \
			and cue_position.distance_squared_to(_candidate_cue_position) < AIM_EPSILON * AIM_EPSILON:
		_settle_elapsed += delta
	else:
		_candidate_direction = direction
		_candidate_tip_offset = tip_offset
		_candidate_power = power
		_candidate_cue_position = cue_position
		_candidate_strike = strike
		_has_candidate = true
		_settle_elapsed = 0.0

	if _settle_elapsed < AIM_SETTLE_DELAY:
		return

	_try_dispatch()


## Starts a new prediction for the settled aim, unless one is already running
## or it matches the last dispatch. Called once the aim has held still for
## AIM_SETTLE_DELAY, and again right after a task finishes reaping in case
## the aim had already settled while that calculation was running. At most
## one task is ever in flight - Godot's WorkerThreadPool has no mid-run
## cancellation - but debouncing on stability means fast continuous camera
## movement never dispatches at all, so there's nothing to fall behind on;
## a fresh, accurate trace only ever appears shortly after the player stops.
func _try_dispatch() -> void:
	if _task_in_flight or not _has_candidate:
		return
	if game.cue_ball == null or game.cue_ball.pocketed or not game.can_shoot():
		return

	if _has_last_prediction \
			and _candidate_direction.is_equal_approx(_last_direction) \
			and _candidate_tip_offset.is_equal_approx(_last_tip_offset) \
			and is_equal_approx(_candidate_power, _last_power) \
			and _candidate_cue_position.distance_squared_to(_last_cue_position) < AIM_EPSILON * AIM_EPSILON:
		return

	_last_direction = _candidate_direction
	_last_tip_offset = _candidate_tip_offset
	_last_power = _candidate_power
	_last_cue_position = _candidate_cue_position
	_has_last_prediction = true

	_dispatch_prediction(_candidate_strike, _candidate_cue_position)


func _dispatch_prediction(strike: Dictionary, cue_position: Vector3) -> void:
	_ensure_shadow()
	var cue_number: int = game.cue_ball.ball_number
	var ball_snapshots: Array = []
	var ball_styles: Dictionary = {}
	for ball in game.balls:
		if not is_instance_valid(ball) or ball.pocketed:
			continue
		ball_snapshots.append({"number": ball.ball_number, "position": ball.global_position})
		ball_styles[ball.ball_number] = _ball_preview_style(ball.ball_number)

	var extended: bool = Settings.extended_aim_preview
	_task_id = WorkerThreadPool.add_task(_run_prediction.bind(strike, cue_position, ball_snapshots, cue_number, extended, ball_styles))
	_task_in_flight = true


func _ball_preview_style(ball_number: int) -> Dictionary:
	if ball_number == 0:
		return {"color": CUE_PATH_COLOR, "striped": false}
	return {
		"color": TextureGen.get_ball_color(ball_number),
		"striped": TextureGen.is_stripe(ball_number),
	}


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
	else:
		_draw(result)

	# The aim may have kept moving while that calculation ran. Re-check right
	# away instead of waiting for the next throttled _process tick, so a
	# continuously moving camera gets a continuously updated guide instead of
	# falling further behind with every move.
	_try_dispatch()


func _style_line(mesh_instance: MeshInstance3D) -> void:
	mesh_instance.mesh = ImmediateMesh.new()
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.vertex_color_use_as_albedo = true
	material.albedo_color = Color.WHITE
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
	_draw_path(impact_line, prediction["path"], CUE_PATH_COLOR, false)
	var impact_point: Vector3 = prediction["impact_point"]
	_draw_segment(cue_vector_line, impact_point, impact_point + prediction["cue_after_direction"] * prediction["cue_after_length"], CUE_PATH_COLOR, false)
	if prediction["has_target"]:
		_draw_segment(object_vector_line, prediction["object_start"], prediction["object_start"] + prediction["object_after_direction"] * prediction["object_after_length"], prediction["object_color"], prediction["object_striped"])
	else:
		var mesh: ImmediateMesh = object_vector_line.mesh
		mesh.clear_surfaces()

	var object_paths: Array = prediction.get("object_paths", [])
	for i in range(object_paths.size()):
		var path: Dictionary = object_paths[i]
		_draw_path(_ensure_chain_line(i), path["points"], path["color"], path["striped"])
	for i in range(object_paths.size(), _chain_lines.size()):
		var stale_mesh: ImmediateMesh = _chain_lines[i].mesh
		stale_mesh.clear_surfaces()


func _ensure_chain_line(index: int) -> MeshInstance3D:
	while _chain_lines.size() <= index:
		var chain_line := MeshInstance3D.new()
		add_child(chain_line)
		_style_line(chain_line)
		_chain_lines.append(chain_line)
	return _chain_lines[index]


func _draw_segment(mesh_instance: MeshInstance3D, from: Vector3, to: Vector3, color: Color, striped: bool) -> void:
	_draw_path(mesh_instance, [from, to], color, striped)


func _draw_path(mesh_instance: MeshInstance3D, points: Array, color: Color, striped: bool) -> void:
	var mesh: ImmediateMesh = mesh_instance.mesh
	mesh.clear_surfaces()
	if points.size() < 2:
		return
	mesh.surface_begin(Mesh.PRIMITIVE_LINES if striped else Mesh.PRIMITIVE_LINE_STRIP)
	if striped:
		_draw_striped_path(mesh, points, color)
	else:
		for point in points:
			_add_path_vertex(mesh, point, color)
	mesh.surface_end()


func _draw_striped_path(mesh: ImmediateMesh, points: Array, color: Color) -> void:
	var color_segment := true
	var distance_to_switch := STRIPE_DASH_LENGTH
	for index in range(points.size() - 1):
		var cursor: Vector3 = points[index]
		var segment_end: Vector3 = points[index + 1]
		var segment_direction := cursor.direction_to(segment_end)
		var segment_remaining := cursor.distance_to(segment_end)
		if segment_remaining <= 0.000001:
			continue
		while segment_remaining > 0.000001:
			var length := minf(segment_remaining, distance_to_switch)
			var dash_end := cursor + segment_direction * length
			var dash_color := color if color_segment else STRIPE_ACCENT_COLOR
			_add_path_vertex(mesh, cursor, dash_color)
			_add_path_vertex(mesh, dash_end, dash_color)
			cursor = dash_end
			segment_remaining -= length
			distance_to_switch -= length
			if distance_to_switch <= 0.000001:
				color_segment = not color_segment
				distance_to_switch = STRIPE_DASH_LENGTH


func _add_path_vertex(mesh: ImmediateMesh, point: Vector3, color: Color) -> void:
	mesh.surface_set_color(color)
	mesh.surface_add_vertex(to_local(point) + Vector3.UP * 0.002)


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
	# gameplay (1/180s, 2 substeps) - this now runs off the main thread, and
	# matching live resolution exactly avoids a coarser step missing fast
	# cushion contacts or cutting a trace short before it reaches its target.
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
func _run_prediction(strike: Dictionary, cue_start: Vector3, ball_snapshots: Array, cue_number: int, extended: bool, ball_styles: Dictionary) -> void:
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
	var object_style: Dictionary = ball_styles[other_id]
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
		"object_color": object_style["color"],
		"object_striped": object_style["striped"],
		"object_paths": [],
	}
	if extended:
		result["object_paths"] = _trace_extended_paths(snapshot, ball_styles)
	_pending_result = result


## Continues the exact shadow simulation after the first contact and records a
## path for every ball touched by the shot. Unlike the old single-chain trace,
## this follows branches, cue-ball recontacts, and secondary collisions until
## the whole table has settled.
func _trace_extended_paths(initial_snapshot: Dictionary, ball_styles: Dictionary) -> Array:
	var paths_by_ball: Dictionary = {}
	var snapshot := initial_snapshot

	for ball_id in snapshot:
		var state: Dictionary = snapshot[ball_id]
		if not bool(state.get("pocketed", false)) and state["velocity"].length_squared() > 0.0:
			paths_by_ball[ball_id] = [state["position"]]

	var steps := 0
	while not _shadow.is_settled() and steps < MAX_EXTENDED_PREVIEW_STEPS:
		_contact_events_this_step.clear()
		_cushion_hits_this_step.clear()
		_shadow.step(_shadow.fixed_step)
		steps += 1
		snapshot = _shadow.snapshot()

		for event in _contact_events_this_step:
			_track_extended_ball_path(int(event[0]), snapshot, paths_by_ball)
			_track_extended_ball_path(int(event[1]), snapshot, paths_by_ball)

		for ball_id in paths_by_ball:
			if not snapshot.has(ball_id):
				continue
			var state: Dictionary = snapshot[ball_id]
			_append_extended_path_point(paths_by_ball[ball_id], state["position"], false)

	for ball_id in paths_by_ball:
		if snapshot.has(ball_id):
			_append_extended_path_point(paths_by_ball[ball_id], snapshot[ball_id]["position"], true)

	var styled_paths: Array = []
	for ball_id in paths_by_ball:
		var style: Dictionary = ball_styles.get(ball_id, {"color": Color.WHITE, "striped": false})
		styled_paths.append({
			"points": paths_by_ball[ball_id],
			"color": style["color"],
			"striped": style["striped"],
		})
	return styled_paths


func _track_extended_ball_path(ball_id: int, snapshot: Dictionary, paths_by_ball: Dictionary) -> void:
	if paths_by_ball.has(ball_id) or not snapshot.has(ball_id):
		return
	var state: Dictionary = snapshot[ball_id]
	if not bool(state.get("pocketed", false)):
		paths_by_ball[ball_id] = [state["position"]]


func _append_extended_path_point(path: Array, position: Vector3, force: bool) -> void:
	if path.is_empty() or force or path[path.size() - 1].distance_squared_to(position) >= EXTENDED_PATH_SAMPLE_DISTANCE_SQUARED:
		path.append(position)


## Legacy sequential trace retained for callers that need a single collision
## branch. The extended aim preview uses _trace_extended_paths() instead.
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
