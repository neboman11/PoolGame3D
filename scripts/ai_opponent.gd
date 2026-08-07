class_name AIOpponent
extends RefCounted

## Shot planner for the computer-controlled player. Shot *selection* always
## reasons about the true ghost-ball geometry (cut angle, line-of-sight,
## distance); difficulty only controls how much random error gets layered on
## top of that perfect read, and how often the AI settles for a worse shot on
## the table instead of the best one. That mirrors how human skill actually
## shows up at the table: everyone can see the right shot, not everyone can
## deliver it.
##
## Two harder shot families are ranked alongside the plain pot: a "bank" (the
## cue ball bounces off one or two cushions before its first contact with any
## ball) and a "combo" (the cue ball's legal target ball is used to carom a
## second ball into the pocket). Both are scored with a flat penalty so they
## never outrank a comparable clean pot -- they only get chosen when they are
## genuinely the best (or only) shot on the table. Difficulty additionally
## gates whether such a candidate is even considered at all, which is what
## keeps Rookie from stumbling into a bank shot by luck of the draw.
##
## Skilled difficulties (Pro/Champion) go further, when the caller supplies a
## `shot_outcome` evaluator on the context (a callable(direction, power, hint)
## -> Dictionary that actually simulates the shot to a rest and reads back the
## table): they don't just pick the best pot, they weigh each candidate pot by
## the shape it leaves for their own next shot (`_apply_shape_scoring`), and
## when the best pot available is a low-percentage one they will gamble on
## less often, they instead hunt for a legal safety that buries the cue ball
## and leaves the opponent's next shot as bad as possible (`_defensive_plan`).
## Without a `shot_outcome` evaluator on the context (e.g. the pure-geometry
## unit tests), none of this activates and shot selection is exactly the
## plain best-pot read described above.

enum Difficulty { ROOKIE, AMATEUR, PRO, CHAMPION }

const BALL_RADIUS := 0.142875
const CONTACT_DISTANCE := BALL_RADIUS * 2.0
## Cut angles beyond ~83 degrees are not a makeable ghost-ball line.
const MAX_COS_CUT := 0.12
## Up to a corner-style double kick; higher counts blow up the search for
## geometry that is rarely makeable anyway.
const MAX_BANK_RAILS := 2
const BANK_SCORE_PENALTY := 16.0
const COMBO_SCORE_PENALTY := 20.0
## A rail-facing pocket mouth interrupts the cushion nose -- a ball aimed at
## that stretch sails through into the pocket instead of bouncing. Bounce
## points this close to a pocket's mouth radius (plus a hair of margin) are
## rejected rather than treated as a valid cushion contact.
const BANK_GAP_MARGIN := 0.05

## Below this raw pot score a shot is a genuine gamble (a steep cut, a long
## rail-to-rail table length, or a bank/combo's flat penalty) rather than a
## comfortable pot. It is the trigger `safety_skill` rolls against.
const RISKY_SCORE_THRESHOLD := 45.0
## How many of the best-ranked pots get a `shot_outcome` simulation to weigh
## in the shape they leave. Kept small: this is a real physics sim per entry.
const SHAPE_CANDIDATE_LIMIT := 5
const SHAPE_SCRATCH_LEAVE_SCORE := -60.0
## A scratch is a foul, not just a mediocre leave -- shape-scoring subtracts
## this flat, weight-independent penalty on top of the normal leave-score
## math so a scratching candidate essentially never outranks a clean one,
## even at a low shape_weight, unless every evaluated candidate scratches.
const SCRATCH_DISQUALIFY_PENALTY := 500.0
## Bank/combo candidates already carry a flat raw-score penalty
## (BANK_SCORE_PENALTY/COMBO_SCORE_PENALTY) so a clean pot normally outranks
## them. Position-play's leave bonus can be tens of points wide, though, and
## applying it at full strength let a much harder bank/combo leapfrog a
## comfortable clean pot just for a marginally better leave -- trading an
## easy shot for a low-percentage one instead of only reaching for it when
## it is genuinely the best (or only) option, as the class-level docs
## promise. Scaling the bonus down keeps that promise: a bank/combo can still
## win on shape when its raw score is close to the leader's, but not when a
## clean pot is comfortably better.
const ADVANCED_SHOT_SHAPE_WEIGHT_SCALE := 0.2
## Legal balls considered as a safety's contact ball, nearest first.
const DEFENSE_BALL_COUNT := 2
const DEFENSE_AIM_SPREAD_DEG := [-10.0, -5.0, 0.0, 5.0, 10.0]
const DEFENSE_POWER := 0.3

const PARAMS := {
	Difficulty.ROOKIE: {"label": "Rookie", "aim_error_deg": 7.5, "power_error": 0.22, "pool_size": 4, "bank_chance": 0.04, "plans_shape": false, "shape_weight": 0.0, "safety_skill": 0.0},
	Difficulty.AMATEUR: {"label": "Amateur", "aim_error_deg": 3.5, "power_error": 0.12, "pool_size": 3, "bank_chance": 0.22, "plans_shape": false, "shape_weight": 0.0, "safety_skill": 0.12},
	Difficulty.PRO: {"label": "Pro", "aim_error_deg": 1.2, "power_error": 0.06, "pool_size": 2, "bank_chance": 0.55, "plans_shape": true, "shape_weight": 0.5, "safety_skill": 0.4},
	Difficulty.CHAMPION: {"label": "Champion", "aim_error_deg": 0.25, "power_error": 0.02, "pool_size": 1, "bank_chance": 0.9, "plans_shape": true, "shape_weight": 0.85, "safety_skill": 0.75},
}


static func label_for(difficulty: int) -> String:
	return PARAMS[difficulty]["label"]


## Chooses a shot for the given table state and returns everything the
## caller needs to fire the cue: aim direction, power ratio, and the target
## the AI was going for (useful for status text / debugging).
static func plan_shot(context: Dictionary) -> Dictionary:
	var difficulty: int = context.get("difficulty", Difficulty.AMATEUR)
	var rng: RandomNumberGenerator = context["rng"]
	var params: Dictionary = PARAMS[difficulty]
	var candidates := rank_candidates(context)
	var has_outcome_evaluator: bool = context.has("shot_outcome")

	if candidates.is_empty():
		if has_outcome_evaluator:
			var fallback: Variant = _defensive_plan(context)
			if fallback != null:
				return _finalize_plan(fallback, params, rng, context)
		return _safety_plan(context)

	# A skilled player who reads the table and sees only a low-percentage pot
	# will often play safe instead of gambling on it, rather than firing at
	# the best of a bad set of options.
	if has_outcome_evaluator and candidates[0]["score"] < RISKY_SCORE_THRESHOLD:
		if rng.randf() < float(params.get("safety_skill", 0.0)):
			var defensive: Variant = _defensive_plan(context)
			if defensive != null:
				return _finalize_plan(defensive, params, rng, context)

	if has_outcome_evaluator and bool(params.get("plans_shape", false)):
		candidates = _apply_shape_scoring(candidates, context, float(params.get("shape_weight", 0.0)))

	var pool_size: int = mini(int(params["pool_size"]), candidates.size())
	var choice: Dictionary = candidates[rng.randi_range(0, pool_size - 1)]
	return _finalize_plan(choice, params, rng, context)


## How hard to hit a candidate shot. A caller with real speed/friction numbers
## on hand (the live game) can supply a "power_for_shot" callable(choice) ->
## float that works backward from the physics -- enough pace to survive the
## approach and still carry the object ball (and, for a bank/combo, its extra
## energy loss) to the pocket without dying short -- instead of the flat
## distance-only guess below, which callers without one (e.g. tests) still get.
static func _estimate_base_power(choice: Dictionary, context: Dictionary) -> float:
	if context.has("power_for_shot"):
		var provider: Callable = context["power_for_shot"]
		var provided: Variant = provider.call(choice)
		if provided is float or provided is int:
			return clampf(float(provided), 0.05, 1.0)
	return clampf(0.35 + choice["travel_distance"] * 0.16, 0.3, 0.92)


## Difficulty's aim/power jitter and bank-refiner correction, shared by every
## plan_shot return path (plain pot, bank, combo, or a defensive safety).
static func _finalize_plan(choice: Dictionary, params: Dictionary, rng: RandomNumberGenerator, context: Dictionary) -> Dictionary:
	var base_power: float = float(choice["power"]) if choice.has("power") else _estimate_base_power(choice, context)

	# Bank geometry here is an idealized mirror reflection; real cushion
	# friction throws the rebound off that ideal angle. A caller with a real
	# physics solver on hand (the live game) can supply a "bank_refiner"
	# callable(choice, power) -> Vector3 that corrects the pre-jitter aim
	# against that solver before difficulty noise is layered on top. Callers
	# without one (e.g. tests) get the pure geometric read unchanged.
	var ideal_direction: Vector3 = choice["direction"]
	if choice.get("is_bank", false) and context.has("bank_refiner"):
		var refiner: Callable = context["bank_refiner"]
		var refined: Variant = refiner.call(choice, base_power)
		if refined is Vector3 and refined != Vector3.ZERO:
			ideal_direction = refined

	var aim_error_deg: float = params["aim_error_deg"]
	var jitter_deg := clampf(rng.randfn(0.0, aim_error_deg * 0.5), -aim_error_deg * 2.0, aim_error_deg * 2.0)
	var noisy_direction: Vector3 = ideal_direction.rotated(Vector3.UP, deg_to_rad(jitter_deg))

	var power_error: float = params["power_error"]
	var noisy_power := clampf(base_power + rng.randfn(0.0, power_error), 0.18, 1.0)

	return {
		"direction": noisy_direction,
		"power": noisy_power,
		"target_ball": choice["target_ball"],
		"pocket_id": choice.get("pocket_id", ""),
		"cut_angle_deg": choice.get("cut_angle_deg", 0.0),
		"is_safety": choice.get("is_safety", false),
		"is_bank": choice.get("is_bank", false),
		"rails": choice.get("rails", 0),
		"is_combo": choice.get("is_combo", false),
		"assist_ball": choice.get("assist_ball", -1),
	}


## Re-scores the best few pots by the shape they leave for the AI's own next
## shot: simulates each one for real via the caller's `shot_outcome`
## evaluator, then reads back `best_score()` from where the cue ball actually
## comes to rest. A candidate that scratches is treated as the worst possible
## leave rather than dropped outright -- it still might be the only shot on
## the table, and `_finalize_plan` still applies to whatever wins.
static func _apply_shape_scoring(candidates: Array[Dictionary], context: Dictionary, shape_weight: float) -> Array[Dictionary]:
	if shape_weight <= 0.0 or candidates.is_empty():
		return candidates
	var evaluator: Callable = context["shot_outcome"]
	var limit: int = mini(SHAPE_CANDIDATE_LIMIT, candidates.size())
	for i in range(limit):
		var choice: Dictionary = candidates[i]
		var power: float = _estimate_base_power(choice, context)
		var outcome: Variant = evaluator.call(choice["direction"], power, {"is_bank": choice.get("is_bank", false)})
		if outcome is Dictionary and bool(outcome.get("scratched", false)):
			choice["shape_score"] = float(choice["score"]) - SCRATCH_DISQUALIFY_PENALTY
		else:
			var leave_score := SHAPE_SCRATCH_LEAVE_SCORE
			if outcome is Dictionary:
				leave_score = float(outcome.get("own_leave_score", SHAPE_SCRATCH_LEAVE_SCORE))
			var effective_weight := shape_weight
			if choice.get("is_bank", false) or choice.get("is_combo", false):
				effective_weight *= ADVANCED_SHOT_SHAPE_WEIGHT_SCALE
			choice["shape_score"] = float(choice["score"]) + effective_weight * leave_score
		candidates[i] = choice
	candidates.sort_custom(func(a, b): return float(a.get("shape_score", a["score"])) > float(b.get("shape_score", b["score"])))
	return candidates


## Hunts for the legal contact ball / cut angle that leaves the *opponent*
## with the worst follow-up shot, using the same `shot_outcome` evaluator as
## `_apply_shape_scoring`. Unlike `_safety_plan`'s dead-on tap (used only when
## no evaluator is available), this actually reads where the cue ball ends up
## and picks the option that buries it best. Returns null -- letting the
## caller fall back to `_safety_plan` -- when nothing legal was found (e.g.
## every legal ball would scratch or foul).
static func _defensive_plan(context: Dictionary) -> Variant:
	var cue_position: Vector3 = context["cue_position"]
	var legal_numbers: Array = context["legal_numbers"]
	var evaluator: Callable = context["shot_outcome"]

	var legal_balls: Array = []
	for ball_info in context["balls"]:
		if ball_info["number"] in legal_numbers:
			legal_balls.append(ball_info)
	if legal_balls.is_empty():
		return null
	legal_balls.sort_custom(func(a, b): return cue_position.distance_squared_to(a["position"]) < cue_position.distance_squared_to(b["position"]))
	legal_balls = legal_balls.slice(0, mini(DEFENSE_BALL_COUNT, legal_balls.size()))

	var best: Variant = null
	var best_opponent_score := INF
	for ball_info in legal_balls:
		var to_ball: Vector3 = Vector3(ball_info["position"]) - cue_position
		to_ball.y = 0.0
		if to_ball.length_squared() < 0.000001:
			continue
		var base_direction := to_ball.normalized()
		for angle_deg in DEFENSE_AIM_SPREAD_DEG:
			var direction: Vector3 = base_direction.rotated(Vector3.UP, deg_to_rad(angle_deg))
			var outcome: Variant = evaluator.call(direction, DEFENSE_POWER, {"is_defense": true})
			if not (outcome is Dictionary) or bool(outcome.get("scratched", false)):
				continue
			if int(outcome.get("first_contact", -1)) not in legal_numbers:
				continue
			var opponent_score: float = float(outcome.get("opponent_score", INF))
			if opponent_score < best_opponent_score:
				best_opponent_score = opponent_score
				best = {
					"direction": direction,
					"power": DEFENSE_POWER,
					"target_ball": int(ball_info["number"]),
					"pocket_id": "",
					"cut_angle_deg": 0.0,
					"is_bank": false,
					"is_combo": false,
					"is_safety": true,
					"assist_ball": -1,
				}
	return best


## Best achievable shot quality from a hypothetical cue-ball position,
## ignoring difficulty entirely. Ball-in-hand placement uses this to compare
## candidate spots without also asking "how well would a Rookie play it".
static func best_score(context: Dictionary) -> float:
	var candidates := rank_candidates(context)
	return candidates[0]["score"] if not candidates.is_empty() else -INF


## Ranks every legal shot that has a clear, geometrically makeable line, best
## first: a straight pot on every (target ball, pocket) pairing, plus bank
## and combo variants when the difficulty's random gate allows considering
## them at all.
static func rank_candidates(context: Dictionary) -> Array[Dictionary]:
	var cue_position: Vector3 = context["cue_position"]
	var balls: Array = context["balls"]
	var pockets: Array = context["pockets"]
	var legal_numbers: Array = context["legal_numbers"]
	var bounds: Variant = context.get("table_bounds")
	var rng: Variant = context.get("rng")
	var difficulty: int = context.get("difficulty", Difficulty.AMATEUR)
	var bank_chance: float = PARAMS[difficulty]["bank_chance"]
	# Position-play and defensive-play read-ahead call back into rank_candidates
	# many times per decision just to score a resulting layout; they set this
	# false to skip the O(balls^2) bank/combo search, which they have no use for.
	var allow_advanced: bool = context.get("allow_advanced_shots", true)

	var candidates: Array[Dictionary] = []
	for ball_info in balls:
		var number: int = ball_info["number"]
		if number not in legal_numbers:
			continue
		var ball_position: Vector3 = ball_info["position"]
		for pocket in pockets:
			var direct: Variant = _evaluate_pot(cue_position, ball_position, number, pocket, balls)
			if direct != null:
				candidates.append(direct)

			if allow_advanced and _advanced_shot_allowed(rng, bank_chance):
				var bank: Variant = _evaluate_bank_pot(cue_position, ball_position, number, pocket, balls, bounds, pockets)
				if bank != null:
					candidates.append(bank)

			for assist_info in balls:
				var assist_number: int = assist_info["number"]
				if assist_number == number or assist_number not in legal_numbers:
					continue
				if allow_advanced and _advanced_shot_allowed(rng, bank_chance):
					var combo: Variant = _evaluate_combo_pot(cue_position, ball_info, assist_info, pocket, balls)
					if combo != null:
						candidates.append(combo)

	candidates.sort_custom(func(a, b): return a["score"] > b["score"])
	return candidates


## The difficulty-scaled coin flip that decides whether a bank/combo
## candidate is even entered into the ranking. Missing rng (e.g. a caller
## that only wants deterministic geometry) always allows it through.
static func _advanced_shot_allowed(rng: Variant, chance: float) -> bool:
	if rng == null:
		return true
	return rng.randf() < chance


## No legal pot exists on the table (usually everything is blocked). Play the
## nearest legal ball dead-on rather than concede an intentional foul.
static func _safety_plan(context: Dictionary) -> Dictionary:
	var cue_position: Vector3 = context["cue_position"]
	var rng: RandomNumberGenerator = context["rng"]
	var nearest: Variant = null
	var nearest_distance := INF
	for ball_info in context["balls"]:
		if ball_info["number"] not in context["legal_numbers"]:
			continue
		var distance: float = cue_position.distance_to(ball_info["position"])
		if distance < nearest_distance:
			nearest_distance = distance
			nearest = ball_info

	if nearest == null:
		return {"direction": Vector3.FORWARD, "power": 0.25, "target_ball": -1, "pocket_id": "", "cut_angle_deg": 0.0, "is_safety": true, "is_bank": false, "rails": 0, "is_combo": false, "assist_ball": -1}

	var direction: Vector3 = nearest["position"] - cue_position
	direction.y = 0.0
	direction = direction.normalized() if direction.length_squared() > 0.000001 else Vector3.FORWARD
	direction = direction.rotated(Vector3.UP, deg_to_rad(rng.randfn(0.0, 4.0)))

	return {
		"direction": direction,
		"power": clampf(0.3 + rng.randf() * 0.15, 0.2, 0.5),
		"target_ball": nearest["number"],
		"pocket_id": "",
		"cut_angle_deg": 0.0,
		"is_safety": true,
		"is_bank": false,
		"rails": 0,
		"is_combo": false,
		"assist_ball": -1,
	}


## A ball travelling from `object_position` toward `target_point` in a
## straight line: the pot direction and the ghost-ball spot an incoming ball
## must occupy at contact. Independent of where that incoming ball is coming
## from, so it is shared by the direct pot, the bank's pot leg, and both legs
## of a combo.
static func _ghost_for_target(object_position: Vector3, target_point: Vector3) -> Variant:
	var to_target: Vector3 = target_point - object_position
	to_target.y = 0.0
	if to_target.length_squared() < 0.000001:
		return null
	var pot_direction := to_target.normalized()
	return {
		"pot_direction": pot_direction,
		"ghost_position": object_position - pot_direction * CONTACT_DISTANCE,
		"pot_distance": to_target.length(),
	}


## The straight-line approach from `from_position` into a ghost-ball spot,
## rejecting cut angles no cue could physically deliver.
static func _approach(from_position: Vector3, ghost_position: Vector3, pot_direction: Vector3) -> Variant:
	var to_ghost: Vector3 = ghost_position - from_position
	to_ghost.y = 0.0
	if to_ghost.length_squared() < 0.000001:
		return null
	var approach_direction := to_ghost.normalized()
	var cos_cut := approach_direction.dot(pot_direction)
	if cos_cut <= MAX_COS_CUT:
		return null
	return {
		"approach_direction": approach_direction,
		"cos_cut": cos_cut,
		"cut_angle_deg": rad_to_deg(acos(clampf(cos_cut, -1.0, 1.0))),
		"approach_distance": to_ghost.length(),
	}


static func _obstacle_positions(all_balls: Array, excluded_numbers: Array) -> Array:
	var obstacles: Array = []
	for ball_info in all_balls:
		if ball_info["number"] not in excluded_numbers:
			obstacles.append(ball_info["position"])
	return obstacles


static func _evaluate_pot(cue_position: Vector3, ball_position: Vector3, ball_number: int, pocket: Dictionary, all_balls: Array) -> Variant:
	# Aim a little inside the mouth rather than at the rail-edge trigger point
	# so the ghost-ball line matches where a pot actually drops.
	var pocket_target: Vector3 = pocket["position"] + Vector3(pocket["inward_normal"]).normalized() * (float(pocket["mouth_width"]) * 0.22)

	var target: Variant = _ghost_for_target(ball_position, pocket_target)
	if target == null:
		return null
	var approach: Variant = _approach(cue_position, target["ghost_position"], target["pot_direction"])
	if approach == null:
		return null # the cue ball would have to pass through the object ball

	var obstacles: Array = _obstacle_positions(all_balls, [ball_number])
	if _path_blocked(cue_position, target["ghost_position"], obstacles):
		return null
	if _path_blocked(ball_position, pocket_target, obstacles):
		return null

	var travel_distance: float = approach["approach_distance"] + target["pot_distance"]
	var score: float = 100.0 - approach["cut_angle_deg"] * 0.85 - travel_distance * 2.6

	return {
		"target_ball": ball_number,
		"pocket_id": pocket["id"],
		"direction": approach["approach_direction"],
		"cut_angle_deg": approach["cut_angle_deg"],
		"travel_distance": travel_distance,
		"approach_distance": approach["approach_distance"],
		"pot_distance": target["pot_distance"],
		"score": score,
		"is_bank": false,
		"rails": 0,
		"is_combo": false,
	}


## Same pot as _evaluate_pot, but the cue ball reaches the ghost-ball spot by
## bouncing off one or two cushions first instead of a clear straight line.
## `bounds` is null when the caller has no table geometry to bank off (e.g. a
## synthetic test context); banks are simply unavailable in that case.
static func _evaluate_bank_pot(cue_position: Vector3, ball_position: Vector3, ball_number: int, pocket: Dictionary, all_balls: Array, bounds: Variant, all_pockets: Array) -> Variant:
	if bounds == null:
		return null
	var pocket_target: Vector3 = pocket["position"] + Vector3(pocket["inward_normal"]).normalized() * (float(pocket["mouth_width"]) * 0.22)
	var target: Variant = _ghost_for_target(ball_position, pocket_target)
	if target == null:
		return null

	var obstacles: Array = _obstacle_positions(all_balls, [ball_number])
	if _path_blocked(ball_position, pocket_target, obstacles):
		return null

	var best: Variant = null
	for wall_set in _bank_wall_sets(bounds):
		var bounce_points: Variant = _unfold_bank_path(cue_position, target["ghost_position"], wall_set, bounds, all_pockets)
		if bounce_points == null:
			continue
		var first_bounce: Vector3 = bounce_points[0]
		var launch_direction: Vector3 = first_bounce - cue_position
		launch_direction.y = 0.0
		if launch_direction.length_squared() < 0.000001:
			continue
		launch_direction = launch_direction.normalized()

		var last_bounce: Vector3 = bounce_points[bounce_points.size() - 1]
		var final_approach: Variant = _approach(last_bounce, target["ghost_position"], target["pot_direction"])
		if final_approach == null:
			continue
		if _bank_path_blocked(cue_position, bounce_points, target["ghost_position"], obstacles):
			continue

		var approach_distance: float = _bank_path_length(cue_position, bounce_points, target["ghost_position"])
		var travel_distance: float = approach_distance + target["pot_distance"]
		var score: float = 100.0 - final_approach["cut_angle_deg"] * 0.85 - travel_distance * 2.6 - BANK_SCORE_PENALTY * wall_set.size()
		if best == null or score > best["score"]:
			best = {
				"target_ball": ball_number,
				"pocket_id": pocket["id"],
				"direction": launch_direction,
				"cut_angle_deg": final_approach["cut_angle_deg"],
				"travel_distance": travel_distance,
				"approach_distance": approach_distance,
				"pot_distance": target["pot_distance"],
				"score": score,
				"is_bank": true,
				"rails": wall_set.size(),
				"is_combo": false,
				"ghost_position": target["ghost_position"],
				"pot_direction": target["pot_direction"],
				"bank_incidence_degrees": _bank_incidence_degrees(cue_position, bounce_points, wall_set),
			}
	return best


## Angle of incidence (from the cushion's own normal) at each bounce along a
## bank path -- 0 deg is a dead-on hit into the rail (heaviest cushion
## restitution loss), 90 deg is a graze (almost no loss). A caller with the
## table's cushion restitution on hand (the live game) uses this per-bounce
## to work out how much launch speed a bank shot loses to the rail(s) that a
## rolling-friction-only distance model can't see.
static func _bank_incidence_degrees(cue_position: Vector3, bounce_points: Array, wall_set: Array) -> Array[float]:
	var incidences: Array[float] = []
	var previous_point := cue_position
	for i in range(bounce_points.size()):
		var wall: Dictionary = wall_set[i]
		var incoming: Vector3 = Vector3(bounce_points[i]) - previous_point
		incoming.y = 0.0
		if incoming.length_squared() > 0.000001:
			incoming = incoming.normalized()
			var wall_normal: Vector3 = Vector3(signf(float(wall["plane"])), 0.0, 0.0) if wall["axis"] == "x" else Vector3(0.0, 0.0, signf(float(wall["plane"])))
			var cos_incidence := clampf(absf(incoming.dot(wall_normal)), 0.0, 1.0)
			incidences.append(rad_to_deg(acos(cos_incidence)))
		previous_point = bounce_points[i]
	return incidences


## A two-ball carom: the cue ball strikes `primary_ball` (must be a legal
## first contact), which in turn strikes `assist_ball` into the pocket. Both
## contacts are read with the same ghost-ball geometry as a plain pot, just
## chained: the primary ball's "pocket" is the ghost spot it must reach to
## send the assist ball on toward the real pocket.
static func _evaluate_combo_pot(cue_position: Vector3, primary_ball: Dictionary, assist_ball: Dictionary, pocket: Dictionary, all_balls: Array) -> Variant:
	var primary_number: int = primary_ball["number"]
	var assist_number: int = assist_ball["number"]
	var pocket_target: Vector3 = pocket["position"] + Vector3(pocket["inward_normal"]).normalized() * (float(pocket["mouth_width"]) * 0.22)

	var assist_target: Variant = _ghost_for_target(assist_ball["position"], pocket_target)
	if assist_target == null:
		return null
	var primary_target: Variant = _ghost_for_target(primary_ball["position"], assist_target["ghost_position"])
	if primary_target == null:
		return null

	var transfer: Variant = _approach(primary_ball["position"], assist_target["ghost_position"], assist_target["pot_direction"])
	if transfer == null:
		return null # the primary ball would have to pass through the assist ball
	var approach: Variant = _approach(cue_position, primary_target["ghost_position"], primary_target["pot_direction"])
	if approach == null:
		return null # the cue ball would have to pass through the primary ball

	var obstacles: Array = _obstacle_positions(all_balls, [primary_number, assist_number])
	if _path_blocked(cue_position, primary_target["ghost_position"], obstacles):
		return null
	if _path_blocked(primary_ball["position"], assist_target["ghost_position"], obstacles):
		return null
	if _path_blocked(assist_ball["position"], pocket_target, obstacles):
		return null

	var pot_distance: float = primary_target["pot_distance"] + assist_target["pot_distance"]
	var travel_distance: float = approach["approach_distance"] + pot_distance
	var score: float = 100.0 - transfer["cut_angle_deg"] * 0.85 - travel_distance * 2.6 - COMBO_SCORE_PENALTY

	return {
		"target_ball": primary_number,
		"pocket_id": pocket["id"],
		"direction": approach["approach_direction"],
		# Displayed/scored cut angle is the primary->assist transfer, since
		# that is the angle a player reads as "the shot's difficulty". The
		# cue's own cut onto the primary ball is a second, separate speed
		# transfer loss further back in the chain -- kept as its own field
		# rather than folded in here, since only the power model needs it.
		"cut_angle_deg": transfer["cut_angle_deg"],
		"primary_cut_angle_deg": approach["cut_angle_deg"],
		"travel_distance": travel_distance,
		"approach_distance": approach["approach_distance"],
		"pot_distance": pot_distance,
		"primary_leg_distance": primary_target["pot_distance"],
		"assist_leg_distance": assist_target["pot_distance"],
		"score": score,
		"is_bank": false,
		"rails": 0,
		"is_combo": true,
		"assist_ball": assist_number,
	}


## Every cushion (or cushion pair, for a corner-style double kick) the cue
## ball could bounce off before its first contact. `bounds` gives the half
## extents a ball's *center* reaches at the cushion nose (already accounting
## for the nose overhanging the cloth edge) -- this only pulls that in by the
## ball's own radius.
static func _bank_wall_sets(bounds: Dictionary) -> Array:
	var eff_half_length: float = bounds["half_length"] - BALL_RADIUS
	var eff_half_width: float = bounds["half_width"] - BALL_RADIUS
	var x_walls := [{"axis": "x", "plane": eff_half_length}, {"axis": "x", "plane": -eff_half_length}]
	var z_walls := [{"axis": "z", "plane": eff_half_width}, {"axis": "z", "plane": -eff_half_width}]

	var sets: Array = []
	for wall in x_walls:
		sets.append([wall])
	for wall in z_walls:
		sets.append([wall])
	if MAX_BANK_RAILS >= 2:
		for x_wall in x_walls:
			for z_wall in z_walls:
				sets.append([x_wall, z_wall])
				sets.append([z_wall, x_wall])
	return sets


## Mirror-image unfolding: reflects `end` back through each wall in reverse
## order to get the "as the crow flies" virtual target, then walks the walls
## forward finding where the straight line to that virtual target actually
## crosses each cushion. Returns the ordered real-space bounce points, or
## null if any crossing falls outside the table or off the segment.
static func _unfold_bank_path(start: Vector3, end: Vector3, walls: Array, bounds: Dictionary, pockets: Array) -> Variant:
	var target := end
	for i in range(walls.size() - 1, -1, -1):
		target = _reflect_point(target, walls[i])

	var bounce_points: Array[Vector3] = []
	var current := start
	for wall in walls:
		var numer: float
		var denom: float
		if wall["axis"] == "x":
			numer = wall["plane"] - current.x
			denom = target.x - current.x
		else:
			numer = wall["plane"] - current.z
			denom = target.z - current.z
		if absf(denom) < 0.000001:
			return null
		var t := numer / denom
		if t <= 0.02 or t >= 0.98:
			return null
		var bounce: Vector3 = current.lerp(target, t)
		if wall["axis"] == "x":
			if absf(bounce.z) > bounds["half_width"] - BALL_RADIUS:
				return null
		else:
			if absf(bounce.x) > bounds["half_length"] - BALL_RADIUS:
				return null
		if _bounce_blocked_by_pocket(bounce, wall, pockets):
			return null
		bounce_points.append(bounce)
		target = _reflect_point(target, wall)
		current = bounce
	return bounce_points


## True when `bounce` falls inside a pocket's mouth opening on this wall --
## the cushion nose is cut away there, so a ball aimed into it sails through
## toward the pocket instead of rebounding.
static func _bounce_blocked_by_pocket(bounce: Vector3, wall: Dictionary, pockets: Array) -> bool:
	for pocket in pockets:
		var pocket_position: Vector3 = pocket["position"]
		var mouth_radius: float = float(pocket["mouth_width"]) * 0.5 + BALL_RADIUS + BANK_GAP_MARGIN
		if wall["axis"] == "x":
			if absf(pocket_position.x - wall["plane"]) > mouth_radius:
				continue
			if absf(bounce.z - pocket_position.z) < mouth_radius:
				return true
		else:
			if absf(pocket_position.z - wall["plane"]) > mouth_radius:
				continue
			if absf(bounce.x - pocket_position.x) < mouth_radius:
				return true
	return false


static func _reflect_point(point: Vector3, wall: Dictionary) -> Vector3:
	if wall["axis"] == "x":
		return Vector3(2.0 * wall["plane"] - point.x, point.y, point.z)
	return Vector3(point.x, point.y, 2.0 * wall["plane"] - point.z)


static func _bank_path_blocked(start: Vector3, bounce_points: Array, end: Vector3, obstacles: Array) -> bool:
	var current := start
	for bounce in bounce_points:
		if _path_blocked(current, bounce, obstacles):
			return true
		current = bounce
	return _path_blocked(current, end, obstacles)


static func _bank_path_length(start: Vector3, bounce_points: Array, end: Vector3) -> float:
	var total := 0.0
	var current := start
	for bounce in bounce_points:
		total += current.distance_to(bounce)
		current = bounce
	total += current.distance_to(end)
	return total


static func _path_blocked(from: Vector3, to: Vector3, obstacles: Array) -> bool:
	var flat_from := Vector3(from.x, 0.0, from.z)
	var flat_to := Vector3(to.x, 0.0, to.z)
	var segment := flat_to - flat_from
	var segment_length_sq := segment.length_squared()
	for obstacle in obstacles:
		var point := Vector3(obstacle.x, 0.0, obstacle.z)
		var t := 0.0
		if segment_length_sq > 0.000001:
			t = clampf((point - flat_from).dot(segment) / segment_length_sq, 0.0, 1.0)
		var closest: Vector3 = flat_from + segment * t
		if closest.distance_to(point) < CONTACT_DISTANCE - 0.01:
			return true
	return false
