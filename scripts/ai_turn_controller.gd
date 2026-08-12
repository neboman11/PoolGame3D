extends RefCounted

## AI opponent turn orchestration: shot planning, ball-in-hand placement, and
## the disposable shadow-physics simulations used to score and refine
## candidate shots. Composed by Game (see Game._ai) so Game's own script can
## stay focused on match orchestration and solver events; this uses the same
## public surface a human uses (aim_direction, power, place_cue_ball) so the
## solver and rules see an ordinary shot either way.

const PHYSICS_SCENE := preload("res://scripts/billiards_physics.gd")
const TABLE_PROFILE := preload("res://scripts/table_profile.gd")
const AI_OPPONENT := preload("res://scripts/ai_opponent.gd")
const CUE_STICK_SCRIPT := preload("res://scripts/cue_stick.gd")

const BALL_RADIUS := 0.142875
## Bank-shot aim correction: how many secant-search shadow simulations to run
## per bank shot, and the step used to bracket the first pair of guesses.
const AI_BANK_REFINE_ITERATIONS := 5
const AI_BANK_REFINE_ANGLE_STEP_DEG := 2.0
const AI_BANK_REFINE_MAX_STEPS := 900
const AI_BANK_REFINE_TOLERANCE := 0.01
## Real cushion throw can be large enough that the idealized aim whiffs the
## target ball outright, leaving the secant search with no local gradient to
## follow. This coarse sweep (tried once, only if the idealized angle itself
## misses) finds any angle that actually reaches the target ball to seed it.
const AI_BANK_BRACKET_RANGE_DEG := 30.0
const AI_BANK_BRACKET_STEP_DEG := 5.0
const AI_OBJECT_BANK_REFINE_ANGLE_DEG := [-3.0, -1.5, 0.0, 1.5, 3.0]
const AI_OBJECT_BANK_REFINE_POWER_DELTA := [-0.08, 0.0, 0.08]
## Position-play / defensive-play read-ahead: how long the shadow solver is
## allowed to run a struck shot forward before giving up on it settling. Most
## real shots settle in a fraction of this; it is only a safety cap.
const AI_OUTCOME_SIM_MAX_STEPS := 1500
## Target object-ball speed (m/s) on arrival at the pocket: enough to drop
## with confidence rather than die on the lip, not so much it rattles out.
const AI_POT_ARRIVAL_SPEED_MPS := 0.5

var game: Node = null
var _rng := RandomNumberGenerator.new()

# Disposable, off-tree physics clone used only to correct bank-shot aim
# against real cushion friction before a bank shot is actually struck, and to
# read ahead through position/defensive play. See _refine_bank_direction.
var _shadow: BilliardsPhysics = null
var _shadow_contact: Array = []
var _shadow_pocketed: Array = []
var _shadow_cushion_hits: Array = []
var _shadow_events: Array = []
# Shot planning and ball-in-hand placement both re-simulate several candidate
# shots on the shadow solver, which is slow enough to freeze a frame if run
# inline. Both instead run on a WorkerThreadPool task (same off-thread pattern
# as aim_guide.gd's _run_prediction) so the camera keeps responding while the
# AI "thinks". Only one of these may be in flight at a time - _run_turn always
# awaits one before starting the next.
var _pending_plan: Dictionary = {}
var _pending_cue_position: Vector3 = Vector3.ZERO
var _task_id := -1
var _task_in_flight := false


func setup(game_node: Node) -> void:
	game = game_node
	_rng.randomize()


func cleanup() -> void:
	if _task_in_flight:
		WorkerThreadPool.wait_for_task_completion(_task_id)
		_task_in_flight = false
	if _shadow != null:
		_shadow.free()
		_shadow = null


func maybe_start_turn() -> void:
	if not GameManager.vs_ai or game.ai_turn_active:
		return
	if GameManager.is_game_over():
		return
	if GameManager.rules.current_player != GameManager.AI_PLAYER_INDEX:
		return
	if game.shot_in_progress or game.physics_world == null or not game.physics_world.is_settled():
		return
	game.ai_turn_active = true
	game._sync_camera_input_with_cue_state()
	_run_turn()


func _run_turn() -> void:
	game.cue_stick.set_hidden_for_thinking(true)
	if GameManager.ball_in_hand:
		game.hud.set_status("%s — placing ball in hand..." % GameManager.turn_label())
		await game.get_tree().create_timer(0.6).timeout
		await _place_cue_ball()
		# restore_ball() drops the placed cue ball's "sleeping" flag, and
		# is_settled() (which can_shoot() depends on) only flips back to true
		# after a few physics ticks re-settle it. Planning the shot in the
		# same frame as placement would see can_shoot() still false and give
		# up with an empty plan before the ball ever gets a chance to settle.
		var settle_wait := 0
		while game.physics_world != null and not game.physics_world.is_settled() and settle_wait < 120:
			await game.get_tree().process_frame
			settle_wait += 1
	game.hud.set_status("%s — thinking..." % GameManager.turn_label())
	var min_delay: SceneTreeTimer = game.get_tree().create_timer(randf_range(0.7, 1.3))
	var plan: Dictionary = await _plan_shot()
	if min_delay.time_left > 0.0:
		await min_delay.timeout
	if plan.is_empty() or game.cue_ball == null or not game._can_strike():
		game.cue_stick.set_hidden_for_thinking(false)
		game.ai_turn_active = false
		game._sync_camera_input_with_cue_state()
		return
	# AI rollouts are planar; never inherit a player's jump/massé elevation.
	game.cue_stick.set_elevation(0.0)
	game.cue_stick.aim_direction = plan["direction"]
	game.cue_stick.spin_offset = plan.get("spin_offset", Vector2.ZERO)
	# Call the pocket (and let the player see the highlighted marker plus a
	# status message) before the shot fires, rather than at the moment of
	# impact, so the call isn't a surprise after the ball's already dropping.
	if int(plan.get("target_ball", -1)) == 8 and GameManager.call_eight_pocket(str(plan.get("pocket_id", ""))):
		game.hud.set_status("%s calls %s" % [GameManager.turn_label(), game.hud.pocket_label(plan["pocket_id"])])
		await game.get_tree().create_timer(1.0).timeout
	# Shadow rollouts already include difficulty error. Suppress a second,
	# live-only cue wobble so a validated narrow bank reaches its planned line.
	await game.cue_stick.animate_ai_stroke(plan["power"], true)
	_apply_shot(plan)
	game.ai_turn_active = false
	game._sync_camera_input_with_cue_state()


## Polls a WorkerThreadPool task to completion a frame at a time instead of
## blocking, so callers can `await` it without stalling the main thread (and
## with it, camera input) for however long the task takes.
func _await_task(task_id: int) -> void:
	while not WorkerThreadPool.is_task_completed(task_id):
		await game.get_tree().process_frame
	WorkerThreadPool.wait_for_task_completion(task_id)
	_task_in_flight = false


## Every ball's number and position, captured right now while the balls are
## settled and nothing else is writing to them. Node3D transform getters like
## `global_position` are restricted to the main thread group in Godot 4 (a
## background WorkerThreadPool task calling them errors out) - this snapshot
## is what lets `_build_context`, `_shot_outcome`, and `_refine_bank_direction`
## do their (repeated, per-candidate) position reads off a plain Array instead
## of touching the live Ball nodes from the task.
func _snapshot_balls() -> Array:
	var entries: Array = []
	for ball in game.balls:
		if is_instance_valid(ball) and not ball.pocketed:
			entries.append({"number": ball.ball_number, "position": ball.global_position})
	return entries


func _plan_shot() -> Dictionary:
	if game.cue_ball == null or not game._can_strike():
		return {}
	_ensure_shadow()
	var cue_number: int = game.cue_ball.ball_number
	var ball_snapshot: Array = _snapshot_balls()
	var context: Dictionary = _build_context(game.cue_ball.global_position, ball_snapshot, cue_number, GameManager.rules)
	_pending_plan = {}
	_task_id = WorkerThreadPool.add_task(_run_plan_task.bind(context))
	_task_in_flight = true
	await _await_task(_task_id)
	return _pending_plan


func _run_plan_task(context: Dictionary) -> void:
	_pending_plan = AI_OPPONENT.plan_shot(context)


func _apply_shot(plan: Dictionary) -> void:
	if plan.is_empty() or game.cue_ball == null or not game.can_shoot():
		return
	game.attempt_shot(plan["power"])


func _place_cue_ball() -> void:
	if game.cue_ball == null:
		return
	var candidates: Array = []
	for _attempt in 28:
		var candidate: Variant = _random_valid_cue_position()
		if candidate != null:
			candidates.append(candidate)
	if candidates.is_empty():
		game.place_cue_ball(game._head_spot())
		return
	var cue_number: int = game.cue_ball.ball_number
	var ball_snapshot: Array = _snapshot_balls()
	_pending_cue_position = game._head_spot()
	_task_id = WorkerThreadPool.add_task(_run_cue_placement_task.bind(candidates, ball_snapshot, cue_number))
	_task_in_flight = true
	await _await_task(_task_id)
	game.place_cue_ball(_pending_cue_position)


func _run_cue_placement_task(candidates: Array, ball_snapshot: Array, cue_number: int) -> void:
	var best_position: Vector3 = game._head_spot()
	var best_score := -INF
	for candidate in candidates:
		var score: float = AI_OPPONENT.best_score(_build_context(candidate, ball_snapshot, cue_number, GameManager.rules))
		if score > best_score:
			best_score = score
			best_position = candidate
	_pending_cue_position = best_position


func _random_valid_cue_position() -> Variant:
	var half_length: float = TABLE_PROFILE.PLAYING_SURFACE_LENGTH * 0.5 - BALL_RADIUS * 1.3
	var half_width: float = TABLE_PROFILE.PLAYING_SURFACE_WIDTH * 0.5 - BALL_RADIUS * 1.3
	var point := Vector3(randf_range(-half_length, half_length), BALL_RADIUS + 0.0025, randf_range(-half_width, half_width))
	return point if game._valid_cue_position(point) else null


## `ball_snapshot` is a pre-captured [{"number", "position"}, ...] for every
## ball still on the table (see `_snapshot_balls`) - this must not read
## `balls`/live Node positions itself, since it also runs inside the
## WorkerThreadPool task that plans the shot.
func _build_context(cue_position: Vector3, ball_snapshot: Array, cue_number: int, rules_state: Variant) -> Dictionary:
	var ball_infos: Array = []
	var remaining_numbers: Array[int] = []
	for entry in ball_snapshot:
		if int(entry["number"]) != cue_number:
			ball_infos.append(entry)
			remaining_numbers.append(int(entry["number"]))
	var legal_numbers: Array = rules_state.legal_targets(remaining_numbers)
	# In nine-ball the lowest ball must be contacted first, but any remaining
	# ball can be the second ball of a legal combination (for example 1 -> 9).
	var combo_assist_numbers: Array = legal_numbers
	if GameManager.game_type == GameManager.GameType.NINE_BALL:
		combo_assist_numbers = remaining_numbers.duplicate()
	return {
		"cue_position": cue_position,
		"balls": ball_infos,
		"pockets": TABLE_PROFILE.get_pocket_capture_descriptors(),
		"legal_numbers": legal_numbers,
		"combo_assist_numbers": combo_assist_numbers,
		"difficulty": GameManager.ai_difficulty,
		"rng": _rng,
		# Ball centers reflect at cushion noses beyond the cloth rectangle.
		"table_bounds": {
			"half_length": TABLE_PROFILE.PLAYING_SURFACE_LENGTH * 0.5 + TABLE_PROFILE.RENDERED_CUSHION_NOSE_OUTSET_X,
			"half_width": TABLE_PROFILE.PLAYING_SURFACE_WIDTH * 0.5 + TABLE_PROFILE.RENDERED_CUSHION_NOSE_OUTSET_Z,
		},
		"bank_refiner": _refine_bank_direction.bind(ball_snapshot, cue_number),
		"object_bank_refiner": _refine_object_bank_shot.bind(ball_snapshot, cue_number),
		"shot_outcome": _shot_outcome.bind(ball_snapshot, cue_number, rules_state),
		"continuation_context": _continuation_context.bind(cue_number, rules_state),
		"power_for_shot": _power_for_shot,
	}


## Rebuilds the worker-safe planning context from a settled hypothetical shot.
## Its copied rule state is the result of that shot, never the mutable live
## GameManager rule object.
func _continuation_context(outcome: Dictionary, cue_number: int, fallback_rules: Variant) -> Dictionary:
	if not outcome.has("cue_position") or not outcome.has("balls"):
		return {}
	var cue_position: Vector3 = outcome["cue_position"]
	var next_snapshot: Array = outcome["balls"].duplicate(true)
	next_snapshot.append({"number": cue_number, "position": cue_position})
	var next_rules: Variant = outcome.get("rules_state", fallback_rules)
	return _build_context(cue_position, next_snapshot, cue_number, next_rules)


func _copy_rules_state(source_rules: Variant) -> Variant:
	var script: Script = source_rules.get_script()
	var copied: Variant = script.new()
	for property_name in ["phase", "current_player", "player_groups", "winner"]:
		if not _rules_has_property(source_rules, property_name):
			continue
		var value: Variant = source_rules.get(property_name)
		if property_name == "player_groups":
			var copied_groups: Array = copied.get(property_name)
			for index in range(copied_groups.size()):
				copied_groups[index] = value[index]
			continue
		if value is Array or value is Dictionary:
			value = value.duplicate(true)
		copied.set(property_name, value)
	return copied


func _rules_has_property(rules_state: Variant, property_name: String) -> bool:
	for descriptor in rules_state.get_property_list():
		if String(descriptor["name"]) == property_name:
			return true
	return false


func _power_for_shot(shot: Dictionary) -> float:
	var calibration: Dictionary = TABLE_PROFILE.get_calibration()
	var slide_friction: float = float(calibration["sliding_friction"])
	var roll_friction: float = float(calibration["rolling_friction"])
	var gravity: float = float(calibration["gravity"])
	var arrival_speed: float = AI_POT_ARRIVAL_SPEED_MPS * CUE_STICK_SCRIPT.WORLD_SCALE
	var approach_distance: float = maxf(float(shot.get("approach_distance", 0.0)), 0.0)
	# A ball-ball hit only ever hands off cos(cut angle) * (1+e)/2 of the
	# striker's contact speed along the line of centers (equal masses,
	# restitution e < 1 keeps some of the normal component with the
	# striker) - the cut_factor terms below divide by this too, not just
	# cos(cut angle), or every potted shot arrives a little short of the
	# speed this function is aiming for.
	var ball_restitution: float = float(calibration.get("ball_restitution", 0.92))
	var transfer_factor: float = maxf((1.0 + ball_restitution) * 0.5, 0.5)

	var launch_speed_needed: float
	if bool(shot.get("is_combo", false)):
		# Two chained transfers, worked out back to front: the assist ball
		# needs arrival_speed at the pocket after its own leg's friction, the
		# primary ball needs enough contact speed to hand it that at
		# cos(transfer angle), and the cue ball needs enough contact speed
		# with the primary ball to hand *that* on at cos(the cue's own cut
		# angle onto the primary) -- a cut cue-to-primary shot loses speed
		# here even before the primary/assist transfer does.
		var assist_leg: float = maxf(float(shot.get("assist_leg_distance", 0.0)), 0.0)
		var primary_leg: float = maxf(float(shot.get("primary_leg_distance", 0.0)), 0.0)
		var transfer_cut_factor: float = maxf(cos(deg_to_rad(float(shot.get("cut_angle_deg", 0.0)))), 0.2)
		var primary_cut_factor: float = maxf(cos(deg_to_rad(float(shot.get("primary_cut_angle_deg", 0.0)))), 0.2)

		var assist_launch_needed: float = _launch_speed_for_leg(arrival_speed, assist_leg, slide_friction, roll_friction, gravity)
		var primary_contact_needed: float = assist_launch_needed / (transfer_cut_factor * transfer_factor)
		var primary_launch_needed: float = _launch_speed_for_leg(primary_contact_needed, primary_leg, slide_friction, roll_friction, gravity)
		var cue_contact_needed: float = primary_launch_needed / (primary_cut_factor * transfer_factor)
		launch_speed_needed = _launch_speed_for_leg(cue_contact_needed, approach_distance, slide_friction, roll_friction, gravity)
	else:
		var cut_factor: float = maxf(cos(deg_to_rad(float(shot.get("cut_angle_deg", 0.0)))), 0.2)
		var pot_distance: float = maxf(float(shot.get("pot_distance", shot.get("travel_distance", 0.0))), 0.0)
		var contact_speed_needed: float = _launch_speed_for_leg(arrival_speed, pot_distance, slide_friction, roll_friction, gravity) / (cut_factor * transfer_factor)
		launch_speed_needed = _launch_speed_for_leg(contact_speed_needed, approach_distance, slide_friction, roll_friction, gravity)

	if bool(shot.get("is_bank", false)) or bool(shot.get("is_object_bank", false)):
			# The friction-distance model above has no notion of the cushion
			# itself eating speed. Each bounce reflects the incoming
			# velocity's component along the cushion normal at only
			# cushion_restitution, while the tangential (along-the-rail)
			# component survives close to intact -- so a near-head-on bounce
			# costs far more pace than a grazing one. Divide the launch speed
			# up by each bounce's actual retention instead of a flat
			# per-rail guess.
			var restitution: float = float(calibration["cushion_restitution"])
			var retention := 1.0
			for incidence_degrees in shot.get("bank_incidence_degrees", []):
				var theta := deg_to_rad(float(incidence_degrees))
				retention *= sqrt(pow(sin(theta), 2.0) + pow(restitution * cos(theta), 2.0))
			launch_speed_needed /= maxf(retention, 0.15)

	var cue_ball_speed_mps: float = launch_speed_needed / CUE_STICK_SCRIPT.WORLD_SCALE
	return CUE_STICK_SCRIPT.power_for_cue_ball_speed_mps(cue_ball_speed_mps)


## Every leg of a shot -- the cue ball's own run to contact, and each object
## ball's run after being struck -- starts with zero spin: a stun transfer
## along the line of centers, same as a plain center-ball cue strike, carries
## no rotation with it. A freshly launched ball like that skids under the
## much higher slide_friction until its rotation catches up to its
## translation (natural roll), then decelerates at the far gentler
## roll_friction for whatever distance remains. Solving with roll_friction
## alone -- as if the whole leg were already rolling -- understates the
## launch speed a leg needs by a wide margin whenever the skid phase covers
## a meaningful fraction of it, which is most real shot distances on this
## table. Returns the launch speed this leg needs to still be moving at
## end_speed after covering distance, accounting for both phases.
func _launch_speed_for_leg(end_speed: float, distance: float, slide_friction: float, roll_friction: float, gravity: float) -> float:
	if distance <= 0.0:
		return end_speed
	var slide_decel: float = maxf(slide_friction * gravity, 0.000001)
	var roll_decel: float = roll_friction * gravity

	# If the ball is still skidding when it reaches the end of this leg, the
	# whole distance decelerates at slide_friction alone.
	var skid_only_launch: float = sqrt(end_speed * end_speed + 2.0 * slide_decel * distance)
	# Classic billiards skid-to-roll result for a solid sphere struck with no
	# spin: it reaches natural roll (5/7 of launch speed) after covering
	# (12/49) * v0^2 / (slide_friction * gravity).
	var skid_distance_for_launch: float = (12.0 / 49.0) * skid_only_launch * skid_only_launch / slide_decel
	if skid_distance_for_launch >= distance:
		return skid_only_launch

	# Otherwise it transitions to natural roll partway through the leg, then
	# only decelerates at roll_friction for the rest.
	var transition_factor: float = (25.0 * slide_friction + 24.0 * roll_friction) / (49.0 * maxf(slide_friction, 0.000001))
	return sqrt((end_speed * end_speed + 2.0 * roll_decel * distance) / maxf(transition_factor, 0.000001))


## AIOpponent's bank candidates are read off an idealized mirror reflection
## off the cushion. Real cushions add friction (see BilliardsPhysics's
## _resolve_static_contact) that throws a rolling ball's rebound away from
## that ideal angle, so a bank aimed purely at the geometry misses. This
## nudges the pre-jitter launch angle with a secant search against a
## disposable physics clone until the simulated first contact with the
## target ball actually lands on the intended ghost-ball spot; difficulty's
## own aim jitter is layered on top afterwards, same as any other shot.
## `ball_snapshots`/`cue_number` are bound by `_build_context` from a snapshot
## captured before this ran - see the note there on why (this runs inside the
## WorkerThreadPool shot-planning task, where live Node position reads are
## not allowed).
func _refine_bank_direction(choice: Dictionary, power: float, ball_snapshots: Array, cue_number: int) -> Vector3:
	var initial_direction: Vector3 = choice["direction"]
	var pot_direction: Vector3 = choice.get("pot_direction", Vector3.ZERO)
	var ghost_position: Vector3 = choice.get("ghost_position", Vector3.ZERO)
	if pot_direction.length_squared() < 0.000001:
		return initial_direction
	var target_number: int = int(choice["target_ball"])
	var spin_offset: Vector2 = choice.get("spin_offset", Vector2.ZERO)

	_ensure_shadow()
	var lateral_axis: Vector3 = Vector3.UP.cross(pot_direction).normalized()

	var best_direction := initial_direction
	var best_error := INF
	var angle_offset := 0.0
	var previous_offset := 0.0
	var previous_error := 0.0
	var have_previous := false
	var bracketed := false

	for _attempt in AI_BANK_REFINE_ITERATIONS:
		var candidate_direction: Vector3 = initial_direction.rotated(Vector3.UP, deg_to_rad(angle_offset))
		var contact: Variant = _simulate_strike(ball_snapshots, cue_number, candidate_direction, power, spin_offset)
		if contact == null or int(contact["ball"]) != target_number:
			if bracketed:
				break
			bracketed = true
			var bracket_offset: Variant = _bracket_bank_direction(ball_snapshots, cue_number, initial_direction, power, target_number, spin_offset)
			if bracket_offset == null:
				break
			angle_offset = bracket_offset
			continue

		var error: float = (Vector3(contact["position"]) - ghost_position).dot(lateral_axis)
		if absf(error) < absf(best_error):
			best_error = error
			best_direction = candidate_direction
		if absf(error) <= AI_BANK_REFINE_TOLERANCE:
			break
		if not have_previous:
			have_previous = true
			previous_offset = angle_offset
			previous_error = error
			angle_offset += AI_BANK_REFINE_ANGLE_STEP_DEG if error > 0.0 else -AI_BANK_REFINE_ANGLE_STEP_DEG
			continue

		var denom: float = error - previous_error
		if absf(denom) < 0.000001:
			break
		var next_offset: float = angle_offset - error * (angle_offset - previous_offset) / denom
		previous_offset = angle_offset
		previous_error = error
		angle_offset = clampf(next_offset, -35.0, 35.0)

	return best_direction


## Object-ball banks need a different correction from cue-ball kicks: vary
## the cue delivery itself, then retain only a direction/power pair that the
## shadow solver proves pockets the intended object ball after its cushion.
func _refine_object_bank_shot(choice: Dictionary, power: float, ball_snapshots: Array, cue_number: int) -> Dictionary:
	var initial_direction: Vector3 = choice["direction"]
	var target_number: int = int(choice["target_ball"])
	var spin_offset: Vector2 = choice.get("spin_offset", Vector2.ZERO)
	var best: Dictionary = {}
	var best_cost := INF

	for power_delta in AI_OBJECT_BANK_REFINE_POWER_DELTA:
		var candidate_power := clampf(power + float(power_delta), 0.18, 1.0)
		for angle_deg in AI_OBJECT_BANK_REFINE_ANGLE_DEG:
			var candidate_direction: Vector3 = initial_direction.rotated(Vector3.UP, deg_to_rad(float(angle_deg)))
			var outcome := _simulate_outcome(ball_snapshots, cue_number, candidate_direction, candidate_power, spin_offset)
			if bool(outcome.get("scratched", false)):
				continue
			if int(outcome.get("first_contact", -1)) != target_number:
				continue
			if target_number not in outcome.get("pocketed", []):
				continue
			# Prefer the smallest correction among proven pocketing trajectories.
			var cost: float = absf(float(angle_deg)) + absf(float(power_delta)) * 8.0
			if cost < best_cost:
				best_cost = cost
				best = {
					"direction": candidate_direction,
					"power": candidate_power,
				}
	return best


func _bracket_bank_direction(ball_snapshots: Array, cue_number: int, initial_direction: Vector3, power: float, target_number: int, spin_offset: Vector2) -> Variant:
	var offset := AI_BANK_BRACKET_STEP_DEG
	while offset <= AI_BANK_BRACKET_RANGE_DEG:
		for direction_sign in [1.0, -1.0]:
			var candidate_offset: float = offset * direction_sign
			var candidate_direction: Vector3 = initial_direction.rotated(Vector3.UP, deg_to_rad(candidate_offset))
			var contact: Variant = _simulate_strike(ball_snapshots, cue_number, candidate_direction, power, spin_offset)
			if contact != null and int(contact["ball"]) == target_number:
				return candidate_offset
		offset += AI_BANK_BRACKET_STEP_DEG
	return null


func _ensure_shadow() -> void:
	if _shadow != null:
		return
	_shadow = PHYSICS_SCENE.new()
	var config: Dictionary = TABLE_PROFILE.get_calibration().duplicate(true)
	config["descriptors"] = TABLE_PROFILE.get_physics_descriptors()
	_shadow.configure(config)
	_shadow.ball_contacted.connect(_on_shadow_contact)
	_shadow.ball_pocketed.connect(_on_shadow_pocketed)
	_shadow.ball_hit_cushion.connect(_on_shadow_cushion)


func _on_shadow_contact(a: Variant, b: Variant) -> void:
	if _shadow_contact.is_empty():
		_shadow_contact.append(int(a))
		_shadow_contact.append(int(b))
		_shadow_events.append({"type": "contact", "a": int(a), "b": int(b)})


func _on_shadow_pocketed(ball: Variant) -> void:
	_shadow_pocketed.append(int(ball))


func _on_shadow_cushion(ball: Variant, _cushion_id: Variant) -> void:
	_shadow_cushion_hits.append(int(ball))
	_shadow_events.append({"type": "rail", "ball": int(ball)})


## Strikes a fresh copy of the current table on the shadow solver and steps
## it until the cue ball's first contact with any ball (or it runs out of
## steps/settles without one). Synchronous and only invoked a handful of
## times per bank shot at AI decision time, not per frame.
func _tip_offset(direction: Vector3, spin_offset: Vector2) -> Vector3:
	var horizontal := Vector3(direction.x, 0.0, direction.z)
	if horizontal.length_squared() < 0.000001:
		horizontal = Vector3.FORWARD
	var right := horizontal.normalized().cross(Vector3.UP).normalized()
	var offset := spin_offset.limit_length(1.0) * (BALL_RADIUS * CUE_STICK_SCRIPT.MAX_TIP_OFFSET)
	return right * offset.x + Vector3.UP * offset.y


func _simulate_strike(ball_snapshots: Array, cue_number: int, direction: Vector3, power: float, spin_offset := Vector2.ZERO) -> Variant:
	_shadow.unregister_all()
	for entry in ball_snapshots:
		_shadow.add_ball(entry["number"], entry["position"], Vector3.ZERO, BALL_RADIUS, BilliardsBall.MASS, Vector3.ZERO)
	var transfer_speed: float = CUE_STICK_SCRIPT.cue_ball_speed_mps_for_power(power) * CUE_STICK_SCRIPT.WORLD_SCALE
	var impulse: Vector3 = direction.normalized() * transfer_speed * BilliardsBall.MASS

	_shadow_contact.clear()
	_shadow.strike_ball(cue_number, impulse, _tip_offset(direction, spin_offset))
	var steps := 0
	while _shadow_contact.is_empty() and steps < AI_BANK_REFINE_MAX_STEPS:
		_shadow.step(_shadow.fixed_step)
		steps += 1
		if _shadow.is_settled():
			break
	if _shadow_contact.is_empty():
		return null
	var snapshot: Dictionary = _shadow.snapshot()
	var contact_ball: int = _shadow_contact[1] if _shadow_contact[0] == cue_number else _shadow_contact[0]
	return {"ball": contact_ball, "position": snapshot[cue_number]["position"]}


## Strikes a fresh copy of the current table on the shadow solver and steps it
## all the way to rest (not just first contact, unlike _simulate_strike). Used
## by AIOpponent's position-play and defensive-play read-ahead to see where a
## candidate shot actually leaves every ball, not just whether it makes the pot.
func _simulate_outcome(ball_snapshots: Array, cue_number: int, direction: Vector3, power: float, spin_offset := Vector2.ZERO) -> Dictionary:
	_ensure_shadow()
	_shadow.unregister_all()
	for entry in ball_snapshots:
		_shadow.add_ball(entry["number"], entry["position"], Vector3.ZERO, BALL_RADIUS, BilliardsBall.MASS, Vector3.ZERO)
	var transfer_speed: float = CUE_STICK_SCRIPT.cue_ball_speed_mps_for_power(power) * CUE_STICK_SCRIPT.WORLD_SCALE
	var impulse: Vector3 = direction.normalized() * transfer_speed * BilliardsBall.MASS

	_shadow_contact.clear()
	_shadow_pocketed.clear()
	_shadow_cushion_hits.clear()
	_shadow_events.clear()
	_shadow.strike_ball(cue_number, impulse, _tip_offset(direction, spin_offset))
	var steps := 0
	while not _shadow.is_settled() and steps < AI_OUTCOME_SIM_MAX_STEPS:
		_shadow.step(_shadow.fixed_step)
		steps += 1

	var first_contact := -1
	if not _shadow_contact.is_empty():
		first_contact = _shadow_contact[1] if _shadow_contact[0] == cue_number else _shadow_contact[0]
	var scratched: bool = cue_number in _shadow_pocketed
	var result := {
		"scratched": scratched,
		"first_contact": first_contact,
		"pocketed": _shadow_pocketed.duplicate(),
		"cushion_hits": _shadow_cushion_hits.duplicate(),
		"events": _shadow_events.duplicate(true),
	}
	if scratched:
		return result

	var snapshot: Dictionary = _shadow.snapshot()
	var cue_state: Variant = snapshot.get(cue_number, null)
	result["cue_position"] = cue_state["position"] if cue_state != null else Vector3.ZERO
	var ball_entries: Array = []
	for id in snapshot:
		if id == cue_number or id in _shadow_pocketed:
			continue
		ball_entries.append({"number": id, "position": snapshot[id]["position"]})
	result["balls"] = ball_entries
	return result


## AIOpponent's `shot_outcome` context callable. Simulates a candidate shot to
## rest and reads back how good the resulting layout is both for the AI's own
## next shot (`own_leave_score`, position play) and for the opponent's
## (`opponent_score`, defensive play) -- pure geometric reads via
## AIOpponent.best_score(), same as any other shot-quality check, just against
## the post-shot table instead of the current one.
## `ball_snapshots`/`cue_number` are bound by `_build_context` from a snapshot
## captured before this ran - see the note there on why (this runs inside the
## WorkerThreadPool shot-planning task, where live Node position reads are
## not allowed).
func _shot_outcome(direction: Vector3, power: float, hint: Dictionary, ball_snapshots: Array, cue_number: int, rules_state: Variant) -> Dictionary:
	if ball_snapshots.is_empty():
		return {"scratched": true}
	var spin_offset: Vector2 = hint.get("spin_offset", Vector2.ZERO)
	var settled := _simulate_outcome(ball_snapshots, cue_number, direction, power, spin_offset)
	if bool(settled.get("scratched", false)):
		return {
			"scratched": true,
			"first_contact": settled.get("first_contact", -1),
			"pocketed": settled.get("pocketed", []),
		}

	var rule_result := _resolve_simulated_shot(rules_state, ball_snapshots, cue_number, settled, hint)
	var remaining_numbers: Array[int] = []
	for entry in settled["balls"]:
		remaining_numbers.append(int(entry["number"]))
	var continues: bool = bool(rule_result["continues"])
	var own_leave_score := 0.0
	if continues:
		own_leave_score = AI_OPPONENT.best_score(_shape_context(
			settled["cue_position"],
			settled["balls"],
			rule_result["legal_numbers"],
		))
	var opponent_legal_numbers: Array = rule_result["opponent_legal_numbers"]
	return {
		"scratched": false,
		"first_contact": settled.get("first_contact", -1),
		"pocketed": settled.get("pocketed", []),
		"cue_position": settled["cue_position"],
		"balls": settled["balls"],
		"continues": continues,
		"foul": bool(rule_result["foul"]),
		"rules_state": rule_result["rules_state"],
		"own_leave_score": own_leave_score,
		"opponent_score": AI_OPPONENT.best_score(_shape_context(settled["cue_position"], settled["balls"], opponent_legal_numbers)),
	}


func _resolve_simulated_shot(rules_state: Variant, ball_snapshots: Array, cue_number: int, settled: Dictionary, hint: Dictionary) -> Dictionary:
	var simulated_rules: Variant = _copy_rules_state(rules_state)
	var remaining_at_start: Array[int] = []
	for entry in ball_snapshots:
		if int(entry["number"]) != cue_number:
			remaining_at_start.append(int(entry["number"]))
	var called_eight_pocket := str(hint.get("pocket_id", "")) if int(hint.get("target_ball", -1)) == 8 else ""
	simulated_rules.begin_shot(called_eight_pocket, remaining_at_start)

	var recorded_contact := false
	for event in settled.get("events", []):
		if event.get("type", "") == "contact":
			simulated_rules.record_ball_contact(int(event["a"]), int(event["b"]))
			recorded_contact = true
		elif event.get("type", "") == "rail":
			simulated_rules.record_rail_contact(int(event["ball"]))
	if not recorded_contact:
		# Lightweight unit-test outcomes may only expose first_contact.
		var first_contact: int = int(settled.get("first_contact", -1))
		if first_contact >= 0:
			simulated_rules.record_ball_contact(cue_number, first_contact)
	for pocketed_ball in settled.get("pocketed", []):
		simulated_rules.record_pocket(int(pocketed_ball), str(hint.get("pocket_id", "")))

	var remaining_numbers: Array[int] = []
	for entry in settled["balls"]:
		remaining_numbers.append(int(entry["number"]))
	var resolution: Dictionary = simulated_rules.resolve_shot(remaining_numbers)
	var continues: bool = bool(resolution.get("continue", false))
	var opponent_legal: Array = simulated_rules.legal_targets(remaining_numbers)
	if continues:
		opponent_legal = _opponent_legal_numbers(remaining_numbers, simulated_rules)
	return {
		"continues": continues,
		"foul": bool(resolution.get("foul", false)),
		"legal_numbers": simulated_rules.legal_targets(remaining_numbers),
		"opponent_legal_numbers": opponent_legal,
		"rules_state": simulated_rules,
	}


func _shape_context(cue_position: Vector3, ball_entries: Array, legal_numbers: Array) -> Dictionary:
	return {
		"cue_position": cue_position,
		"balls": ball_entries,
		"pockets": TABLE_PROFILE.get_pocket_capture_descriptors(),
		"legal_numbers": legal_numbers,
		"difficulty": GameManager.ai_difficulty,
		"allow_advanced_shots": false,
	}


## The rules object only exposes legal_targets() for whoever's turn it
## currently is; briefly flipping current_player is a synchronous, read-only
## way to ask the same question for the other player, without duplicating the
## eight-ball/nine-ball group logic here.
func _opponent_legal_numbers(remaining: Array[int], rules_state: Variant) -> Array[int]:
	var opponent_rules: Variant = _copy_rules_state(rules_state)
	opponent_rules.current_player = 1 - opponent_rules.current_player
	var result: Array[int] = []
	result.assign(opponent_rules.legal_targets(remaining))
	return result
