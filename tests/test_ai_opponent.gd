class_name AIOpponentTests
extends RefCounted

## Deterministic checks for the AI opponent's shot geometry and its
## difficulty-scaled precision. No scene, physics, or autoloads required:
## AIOpponent.plan_shot() and rank_candidates() are pure functions of a
## context dictionary.

const AIOpponent := preload("res://scripts/ai_opponent.gd")

var _passed := 0
var _failed: Array[String] = []


func run() -> int:
	_run_case("higher difficulty uses spin more often", _test_difficulty_scales_spin_usage)
	_run_case("physics scoring rejects a missed intended pot", _test_missed_pot_is_disqualified)
	_run_case("physics-rejected bank is never selected as fallback", _test_rejected_bank_uses_safety)
	_run_case("Champion chooses a stronger multi-shot line", _test_champion_prefers_multi_shot_line)
	_run_case("Champion avoids a high-value opponent reply", _test_champion_penalizes_opponent_reply)
	_run_case("bank scoring uses the refined trajectory", _test_bank_scoring_uses_refined_direction)
	_run_case("empty object-bank refinement preserves original delivery", _test_empty_object_bank_refinement_is_safe)
	_run_case("scoring and execution reuse the same delivery noise", _test_scored_delivery_is_executed)
	_run_case("nine-ball combinations can finish with any remaining ball", _test_nine_ball_combo_assist_scope)
	_run_case("true bank candidate routes the object ball through a cushion", _test_object_bank_candidate)
	_run_case("open-table continuation keeps the newly assigned group", _test_open_table_continuation_uses_copied_rules)
	_run_case("pre-contact rail cannot legalize a dry safety", _test_pre_contact_rail_stays_foul)
	_run_case("a clear straight shot is found and aimed at the pocket", _test_straight_shot_found)
	_run_case("an obstructed path is rejected", _test_obstruction_blocks_shot)
	_run_case("an impossible cut angle is rejected", _test_impossible_cut_rejected)
	_run_case("higher difficulty aims and shoots more precisely", _test_difficulty_scales_precision)
	_run_case("legal_targets restricts to the shooter's group", _test_legal_targets)
	_run_case("safety plan aims at the nearest legal ball when nothing is makeable", _test_safety_plan_targets_nearest_legal_ball)
	_run_case("safety plan has a fixed fallback when no ball is legal at all", _test_safety_plan_no_legal_balls)
	_run_case("plan_shot prefers the defensive plan over a blind safety when an outcome evaluator is given", _test_plan_shot_defensive_fallback)

	if _failed.is_empty():
		print("PASS: %d AI opponent checks" % _passed)
		return 0
	printerr("FAIL: %d/%d AI opponent checks failed" % [_failed.size(), _passed + _failed.size()])
	for failure in _failed:
		printerr("  - %s" % failure)
	return 1


## AI spin is optional position play, but its use must scale up with skill.
## Seeded attempts make this a deterministic probability check rather than a
## flaky assertion about one random shot.
func _test_difficulty_scales_spin_usage() -> String:
	var base_context := _base_context(Vector3(-2.0, 0.0, 0.0))
	base_context["balls"] = [{"number": 1, "position": Vector3(0.0, 0.0, 0.0)}]
	base_context["pockets"] = [_pocket("corner", Vector3(2.0, 0.0, 0.0), Vector3(-1.0, 0.0, 0.0))]
	base_context["legal_numbers"] = [1]

	var spin_counts: Array[int] = []
	for difficulty in [AIOpponent.Difficulty.ROOKIE, AIOpponent.Difficulty.AMATEUR, AIOpponent.Difficulty.PRO, AIOpponent.Difficulty.CHAMPION]:
		spin_counts.append(_count_spinning_plans(base_context, difficulty))
	if spin_counts.back() == 0:
		return "Champion never selected spin across seeded attempts"
	for index in range(1, spin_counts.size()):
		if spin_counts[index] <= spin_counts[index - 1]:
			return "spin use should increase with each difficulty, got %s" % spin_counts
	return ""


func _count_spinning_plans(base_context: Dictionary, difficulty: int) -> int:
	var spinning_plans := 0
	for seed in range(200):
		var context: Dictionary = base_context.duplicate(true)
		var rng := RandomNumberGenerator.new()
		rng.seed = seed
		context["rng"] = rng
		context["difficulty"] = difficulty
		var plan: Dictionary = AIOpponent.plan_shot(context)
		var spin_offset: Vector2 = plan.get("spin_offset", Vector2.ZERO)
		if not spin_offset.is_zero_approx():
			spinning_plans += 1
	return spinning_plans


## A geometrically attractive route cannot remain a candidate when the
## rollout says its intended ball never reaches a pocket.
func _test_missed_pot_is_disqualified() -> String:
	var context := _two_option_context()
	context["difficulty"] = AIOpponent.Difficulty.CHAMPION
	context["shot_outcome"] = func(_direction: Vector3, _power: float, hint: Dictionary) -> Dictionary:
		var target: int = int(hint["target_ball"])
		if target == 1:
			return {"scratched": false, "first_contact": 1, "pocketed": [], "own_leave_score": 100.0}
		return {"scratched": false, "first_contact": 2, "pocketed": [2], "own_leave_score": 0.0}

	var plan := AIOpponent.plan_shot(context)
	if int(plan.get("target_ball", -1)) != 2:
		return "expected the made ball (2), got %s" % plan.get("target_ball", -1)
	return ""


func _test_rejected_bank_uses_safety() -> String:
	var context := _base_context(Vector3.ZERO)
	context["difficulty"] = AIOpponent.Difficulty.CHAMPION
	context["balls"] = [{"number": 1, "position": Vector3(2.0, 0.0, 0.0)}]
	context["legal_numbers"] = [1]
	context["shot_outcome"] = func(_direction: Vector3, _power: float, _hint: Dictionary) -> Dictionary:
		return {"scratched": false, "first_contact": 1, "pocketed": []}
	var rejected_bank := {
		"score": 85.0,
		"direction": Vector3.RIGHT,
		"power": 0.5,
		"target_ball": 1,
		"pocket_id": "corner",
		"cut_angle_deg": 0.0,
		"is_bank": true,
		"is_object_bank": false,
		"rails": 1,
		"is_combo": false,
		"assist_ball": -1,
	}
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var scored := AIOpponent._apply_sequence_scoring([rejected_bank], context, AIOpponent.PARAMS[AIOpponent.Difficulty.CHAMPION], rng)
	if not scored.is_empty():
		return "a bank rejected by physics must not be returned as a raw fallback"
	return ""


## Champion should trade a slightly easier immediate pot for a line that leaves
## a confidently makeable next ball. Rookie's one-shot search should retain
## the immediate option on the identical table.
func _test_champion_prefers_multi_shot_line() -> String:
	var rookie_context := _two_option_context()
	rookie_context["difficulty"] = AIOpponent.Difficulty.ROOKIE
	rookie_context["shot_outcome"] = Callable(self, "_two_option_outcome")
	rookie_context["continuation_context"] = Callable(self, "_two_option_continuation")

	var rookie_candidates := AIOpponent._apply_sequence_scoring(
		AIOpponent.rank_candidates(rookie_context),
		rookie_context,
		AIOpponent.PARAMS[AIOpponent.Difficulty.ROOKIE],
		rookie_context["rng"],
	)
	if rookie_candidates.is_empty() or int(rookie_candidates[0]["target_ball"]) != 2:
		return "Rookie should prefer the easier immediate ball 2"

	var champion_context := rookie_context.duplicate(true)
	champion_context["difficulty"] = AIOpponent.Difficulty.CHAMPION
	var champion_candidates := AIOpponent._apply_sequence_scoring(
		AIOpponent.rank_candidates(champion_context),
		champion_context,
		AIOpponent.PARAMS[AIOpponent.Difficulty.CHAMPION],
		champion_context["rng"],
	)
	if champion_candidates.is_empty() or int(champion_candidates[0]["target_ball"]) != 1:
		return "Champion should choose ball 1's stronger continuation"
	return ""


## Banks are mirror-unfolded for candidate generation but must be evaluated with
## the physics-refined direction that will actually be sent to the cue stick.
func _test_bank_scoring_uses_refined_direction() -> String:
	var choice := {
		"score": 80.0,
		"direction": Vector3.LEFT,
		"target_ball": 1,
		"is_bank": true,
		"is_combo": false,
		"travel_distance": 1.0,
		"spin_offset": Vector2(0.4, -0.2),
	}
	var context := _base_context(Vector3.ZERO)
	context["legal_numbers"] = [1]
	context["bank_refiner"] = func(_choice: Dictionary, _power: float) -> Vector3:
		return Vector3.RIGHT
	context["shot_outcome"] = func(direction: Vector3, _power: float, hint: Dictionary) -> Dictionary:
		if direction.dot(Vector3.RIGHT) > 0.999 and Vector2(hint.get("spin_offset", Vector2.ZERO)).is_equal_approx(Vector2(0.4, -0.2)):
			return {"scratched": false, "first_contact": 1, "pocketed": [1], "own_leave_score": 0.0}
		return {"scratched": false, "first_contact": 1, "pocketed": [], "own_leave_score": 0.0}

	var score := AIOpponent._score_sequence(choice, context, AIOpponent.PARAMS[AIOpponent.Difficulty.CHAMPION], 1, 1, true, context["rng"])
	if score <= 0.0:
		return "bank rollout did not receive the refined direction and spin"
	return ""


## Hypothetical continuations must carry a copied rule state. After a solid
## is made on an open eight-ball table, a stripe must not appear as the AI's
## next legal target merely because the live state has not resolved yet.
func _test_open_table_continuation_uses_copied_rules() -> String:
	var rules_script: GDScript = load("res://scripts/eight_ball_rules.gd")
	var rules = rules_script.new()
	rules.reset()
	rules.phase = 1 # EightBallRules.Phase.OPEN_TABLE
	var controller_script: GDScript = load("res://scripts/ai_turn_controller.gd")
	var controller = controller_script.new()
	var resolved: Dictionary = controller._resolve_simulated_shot(
		rules,
		[
			{"number": 0, "position": Vector3.ZERO},
			{"number": 1, "position": Vector3(0.0, 0.0, 1.0)},
			{"number": 8, "position": Vector3(1.0, 0.0, 0.0)},
			{"number": 9, "position": Vector3(0.0, 0.0, -1.0)},
		],
		0,
		{
			"first_contact": 1,
			"pocketed": [1],
			"cushion_hits": [],
			"balls": [
				{"number": 8, "position": Vector3(1.0, 0.0, 0.0)},
				{"number": 9, "position": Vector3(0.0, 0.0, -1.0)},
			],
		},
		{"target_ball": 1, "pocket_id": ""},
	)
	if not bool(resolved["continues"]):
		return "a legal open-table solid pot should retain the turn"
	var legal_numbers: Array = resolved["legal_numbers"]
	if 9 in legal_numbers or 8 not in legal_numbers:
		return "solid assignment should make 8—not stripe 9—the next target, got %s" % legal_numbers
	if rules.phase != 1:
		return "the live rules object was mutated during hypothetical planning"
	return ""



## A bank into the first object ball is not a legal dry safety merely
## because the cue ball touched a cushion before that first contact.
func _test_pre_contact_rail_stays_foul() -> String:
	var rules_script: GDScript = load("res://scripts/eight_ball_rules.gd")
	var rules = rules_script.new()
	rules.reset()
	rules.phase = 2 # EightBallRules.Phase.GROUPS_ASSIGNED
	rules.player_groups[0] = 1 # solids
	rules.player_groups[1] = 2 # stripes
	var controller_script: GDScript = load("res://scripts/ai_turn_controller.gd")
	var controller = controller_script.new()
	var resolved: Dictionary = controller._resolve_simulated_shot(
		rules,
		[
			{"number": 0, "position": Vector3.ZERO},
			{"number": 1, "position": Vector3(0.0, 0.0, 1.0)},
			{"number": 8, "position": Vector3(1.0, 0.0, 0.0)},
			{"number": 9, "position": Vector3(0.0, 0.0, -1.0)},
		],
		0,
		{
			"first_contact": 1,
			"events": [
				{"type": "rail", "ball": 0},
				{"type": "contact", "a": 0, "b": 1},
			],
			"pocketed": [],
			"balls": [
				{"number": 1, "position": Vector3(0.0, 0.0, 1.0)},
				{"number": 8, "position": Vector3(1.0, 0.0, 0.0)},
				{"number": 9, "position": Vector3(0.0, 0.0, -1.0)},
			],
		},
		{"target_ball": 1, "pocket_id": ""},
	)
	if not bool(resolved["foul"]):
		return "a rail before first contact incorrectly legalized the safety"
	return ""



## Candidate rollouts must use the same aim/power perturbation that is sent
## to the cue stick after selection; otherwise narrow banks are false positives.
func _test_champion_penalizes_opponent_reply() -> String:
	var context := _base_context(Vector3(-2.0, 0.0, 0.0))
	context["balls"] = [
		{"number": 1, "position": Vector3(0.0, 0.0, 0.0)},
		{"number": 2, "position": Vector3(0.0, 0.0, 1.0)},
	]
	context["legal_numbers"] = [1, 2]
	context["shot_outcome"] = func(_direction: Vector3, _power: float, hint: Dictionary) -> Dictionary:
		var target_ball := int(hint.get("target_ball", -1))
		return {
			"scratched": false,
			"foul": false,
			"first_contact": target_ball,
			"pocketed": [target_ball],
			"continues": false,
			"opponent_score": 160.0 if target_ball == 1 else 0.0,
		}
	var candidates: Array[Dictionary] = [
		{"score": 100.0, "direction": Vector3.FORWARD, "power": 0.5, "target_ball": 1, "pocket_id": "corner", "cut_angle_deg": 0.0, "is_bank": false, "is_object_bank": false, "rails": 0, "is_combo": false, "assist_ball": -1},
		{"score": 70.0, "direction": Vector3.RIGHT, "power": 0.5, "target_ball": 2, "pocket_id": "corner", "cut_angle_deg": 0.0, "is_bank": false, "is_object_bank": false, "rails": 0, "is_combo": false, "assist_ball": -1},
	]
	var rng := RandomNumberGenerator.new()
	rng.seed = 19
	var scored := AIOpponent._apply_sequence_scoring(candidates, context, AIOpponent.PARAMS[AIOpponent.Difficulty.CHAMPION], rng)
	if scored.is_empty() or int(scored[0].get("target_ball", -1)) != 2:
		return "Champion should reject the line with the opponent's easy reply"
	return ""


func _test_empty_object_bank_refinement_is_safe() -> String:
	var choice := {
		"direction": Vector3.RIGHT,
		"power": 0.5,
		"is_object_bank": true,
		"aim_jitter_deg": 0.0,
	}
	var context := _base_context(Vector3.ZERO)
	context["object_bank_refiner"] = func(_choice: Dictionary, _power: float) -> Dictionary:
		return {}
	var delivery := AIOpponent._delivered_shot(choice, context)
	if not Vector3(delivery.get("direction", Vector3.ZERO)).is_equal_approx(Vector3.RIGHT):
		return "empty object-bank refinement should retain the geometric delivery"
	return ""


func _test_scored_delivery_is_executed() -> String:
	var context := _base_context(Vector3(-2.0, 0.0, 0.0))
	context["difficulty"] = AIOpponent.Difficulty.CHAMPION
	context["balls"] = [{"number": 1, "position": Vector3.ZERO}]
	context["pockets"] = [_pocket("corner", Vector3(2.0, 0.0, 0.0), Vector3(-1.0, 0.0, 0.0))]
	context["legal_numbers"] = [1]
	var rollout_directions: Array[Vector3] = []
	var rollout_powers: Array[float] = []
	context["shot_outcome"] = func(direction: Vector3, power: float, _hint: Dictionary) -> Dictionary:
		rollout_directions.append(direction)
		rollout_powers.append(power)
		return {"scratched": false, "first_contact": 1, "pocketed": [1], "own_leave_score": 0.0}

	var plan := AIOpponent.plan_shot(context)
	if rollout_directions.is_empty():
		return "expected the candidate rollout to run"
	if plan["direction"].dot(rollout_directions[0]) < 0.999999:
		return "final direction differs from the scored delivery"
	if not is_equal_approx(float(plan["power"]), rollout_powers[0]):
		return "final power differs from the scored delivery"
	return ""


## A bank must mean the object ball reaches a cushion after the legal
## cue-ball contact, rather than the older cue-ball-only kick route.
## The lowest ball remains the only legal first contact in nine-ball, but a
## combination may legally send it into any remaining ball, including the 9.
func _test_nine_ball_combo_assist_scope() -> String:
	var context := _base_context(Vector3(-2.0, 0.0, 0.0))
	context["balls"] = [
		{"number": 1, "position": Vector3(0.0, 0.0, 0.0)},
		{"number": 9, "position": Vector3(1.0, 0.0, 0.0)},
	]
	context["pockets"] = [_pocket("corner", Vector3(4.5, 0.0, 0.0), Vector3(-1.0, 0.0, 0.0))]
	context["legal_numbers"] = [1]
	context["combo_assist_numbers"] = [1, 9]
	context["difficulty"] = AIOpponent.Difficulty.CHAMPION
	var combo_found := false
	for candidate in AIOpponent.rank_candidates(context):
		if bool(candidate.get("is_combo", false)) and int(candidate.get("target_ball", -1)) == 1 and int(candidate.get("assist_ball", -1)) == 9:
			combo_found = true
			break
	return "" if combo_found else "expected legal 1-to-9 combination candidate"


func _test_object_bank_candidate() -> String:
	var cue_position := Vector3(-2.0, 0.0, 0.0)
	var object_position := Vector3(0.0, 0.0, 0.0)
	var pocket := _pocket("upper_corner", Vector3(4.5, 0.0, 2.0), Vector3(-1.0, 0.0, -1.0))
	var candidate: Variant = AIOpponent._evaluate_object_bank_pot(
		cue_position,
		object_position,
		1,
		pocket,
		[{"number": 1, "position": object_position}],
		{"half_length": 5.0, "half_width": 2.5},
		[pocket],
	)
	if candidate == null:
		return "expected a one-rail object-ball bank candidate"
	if not bool(candidate.get("is_object_bank", false)) or bool(candidate.get("is_bank", true)):
		return "candidate should be marked as an object-ball bank"
	if int(candidate.get("rails", 0)) != 1:
		return "object-ball banks should use exactly one rail"
	return ""



func _two_option_context() -> Dictionary:
	var context := _base_context(Vector3(-2.0, 0.0, 0.0))
	context["balls"] = [
		{"number": 1, "position": Vector3(0.0, 0.0, 1.0)},
		{"number": 2, "position": Vector3(0.0, 0.0, -0.15)},
	]
	context["pockets"] = [
		_pocket("upper", Vector3(2.0, 0.0, 1.0), Vector3(-1.0, 0.0, 0.0)),
		_pocket("lower", Vector3(2.0, 0.0, -0.15), Vector3(-1.0, 0.0, 0.0)),
	]
	context["legal_numbers"] = [1, 2]
	return context


func _two_option_outcome(_direction: Vector3, _power: float, hint: Dictionary) -> Dictionary:
	var target: int = int(hint["target_ball"])
	return {
		"scratched": false,
		"first_contact": target,
		"pocketed": [target],
		"own_leave_score": 0.0,
		"branch": target,
	}


func _two_option_continuation(outcome: Dictionary) -> Dictionary:
	if int(outcome.get("branch", -1)) != 1:
		return {
			"cue_position": Vector3.ZERO,
			"balls": [],
			"pockets": [],
			"legal_numbers": [],
		}
	return {
		"cue_position": Vector3(-2.0, 0.0, 0.0),
		"balls": [{"number": 3, "position": Vector3.ZERO}],
		"pockets": [_pocket("future", Vector3(2.0, 0.0, 0.0), Vector3(-1.0, 0.0, 0.0))],
		"legal_numbers": [3],
		"shot_outcome": func(_direction: Vector3, _power: float, _hint: Dictionary) -> Dictionary:
			return {"scratched": false, "first_contact": 3, "pocketed": [3], "own_leave_score": 0.0},
	}



func _run_case(label: String, test: Callable) -> void:
	var result: String = test.call()
	if result == "":
		_passed += 1
		print("PASS: %s" % label)
	else:
		_failed.append("%s: %s" % [label, result])


## A cue ball, an object ball, and a pocket all on one line: the only
## makeable candidate should point straight down that line with ~0 cut angle.
func _test_straight_shot_found() -> String:
	var context := _base_context(Vector3(-2.0, 0.0, 0.0))
	context["balls"] = [{"number": 1, "position": Vector3(0.0, 0.0, 0.0)}]
	context["pockets"] = [_pocket("corner", Vector3(2.0, 0.0, 0.0), Vector3(-1.0, 0.0, 0.0))]
	context["legal_numbers"] = [1]

	var candidates := AIOpponent.rank_candidates(context)
	if candidates.is_empty():
		return "expected a makeable straight shot, found none"
	var best: Dictionary = candidates[0]
	if best["cut_angle_deg"] > 1.0:
		return "straight shot should read as a near-0 cut angle, got %.2f" % best["cut_angle_deg"]
	var direction: Vector3 = best["direction"]
	if direction.dot(Vector3(1.0, 0.0, 0.0)) < 0.999:
		return "straight shot direction should point down +X, got %s" % direction
	return ""


## A ball sitting on the cue-to-ghost line must remove that pocket option.
func _test_obstruction_blocks_shot() -> String:
	var context := _base_context(Vector3(-2.0, 0.0, 0.0))
	context["balls"] = [
		{"number": 1, "position": Vector3(0.0, 0.0, 0.0)},
		{"number": 2, "position": Vector3(-1.0, 0.0, 0.0)},
	]
	context["pockets"] = [_pocket("corner", Vector3(2.0, 0.0, 0.0), Vector3(-1.0, 0.0, 0.0))]
	context["legal_numbers"] = [1]

	var candidates := AIOpponent.rank_candidates(context)
	if not candidates.is_empty():
		return "an obstructed line should not produce a candidate, got %d" % candidates.size()
	return ""


## Sending the object ball to a pocket behind the cue ball's approach line is
## not a legal ghost-ball cut; it must be rejected rather than aimed anyway.
func _test_impossible_cut_rejected() -> String:
	var context := _base_context(Vector3(-2.0, 0.0, 0.0))
	context["balls"] = [{"number": 1, "position": Vector3(0.0, 0.0, 0.0)}]
	# The pocket sits back toward the cue ball's own side: potting it would
	# require the cue ball to pass through the object ball.
	context["pockets"] = [_pocket("corner", Vector3(-2.0, 0.0, 0.3), Vector3(1.0, 0.0, 0.0))]
	context["legal_numbers"] = [1]

	var candidates := AIOpponent.rank_candidates(context)
	if not candidates.is_empty():
		return "geometrically impossible cut should not be a candidate"
	return ""


## The whole premise of the feature: difficulty is the precision of the shot.
## Champion should land much closer to the true aim line than Rookie across a
## seeded batch of attempts at the same clean shot.
func _test_difficulty_scales_precision() -> String:
	var base_context := _base_context(Vector3(-2.0, 0.0, 0.0))
	base_context["balls"] = [{"number": 1, "position": Vector3(0.0, 0.0, 0.0)}]
	base_context["pockets"] = [_pocket("corner", Vector3(2.0, 0.0, 0.0), Vector3(-1.0, 0.0, 0.0))]
	base_context["legal_numbers"] = [1]

	var true_direction := Vector3(1.0, 0.0, 0.0)
	var samples := 60
	var rookie_error := _average_angle_error(base_context, AIOpponent.Difficulty.ROOKIE, true_direction, samples, 1)
	var champion_error := _average_angle_error(base_context, AIOpponent.Difficulty.CHAMPION, true_direction, samples, 2)

	if champion_error >= rookie_error:
		return "champion (%.3f deg avg error) should aim tighter than rookie (%.3f deg avg error)" % [champion_error, rookie_error]
	if champion_error > 1.0:
		return "champion's average aim error should stay under 1 degree, got %.3f" % champion_error
	if rookie_error < 2.0:
		return "rookie's average aim error should be clearly visible (>= 2 degrees), got %.3f" % rookie_error
	return ""


func _average_angle_error(base_context: Dictionary, difficulty: int, true_direction: Vector3, samples: int, seed_value: int) -> float:
	var context := base_context.duplicate()
	context["difficulty"] = difficulty
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	context["rng"] = rng
	var total_error := 0.0
	for _sample in samples:
		var plan: Dictionary = AIOpponent.plan_shot(context)
		var direction: Vector3 = plan["direction"]
		var cos_angle := clampf(direction.dot(true_direction), -1.0, 1.0)
		total_error += rad_to_deg(acos(cos_angle))
	return total_error / float(samples)


func _test_legal_targets() -> String:
	var script: Script = load("res://scripts/eight_ball_rules.gd")
	var rules: Object = script.new()
	rules.call("reset")

	var full_rack := _ball_range(1, 15)
	var open_targets: Array = rules.call("legal_targets", full_rack)
	if 8 in open_targets:
		return "open table should never list the 8-ball as a legal target while others remain"
	if open_targets.size() != full_rack.size() - 1:
		return "open table should offer every non-8 ball as a legal target"

	var only_eight_left: Array = rules.call("legal_targets", _ball_range(8, 8))
	if only_eight_left != [8]:
		return "with only the 8-ball left, it must become the legal target"
	return ""


## With no pockets at all, rank_candidates() can never produce a makeable pot,
## so plan_shot() must fall back to _safety_plan() and simply aim at the
## nearest legal ball instead of doing nothing.
func _test_safety_plan_targets_nearest_legal_ball() -> String:
	var context := _base_context(Vector3.ZERO)
	context["balls"] = [
		{"number": 5, "position": Vector3(0.0, 0.0, 3.0)},
		{"number": 6, "position": Vector3(1.0, 0.0, 0.0)},
	]
	context["legal_numbers"] = [5, 6]

	var plan: Dictionary = AIOpponent.plan_shot(context)
	if not bool(plan.get("is_safety", false)):
		return "a shot with no makeable pot must be flagged as a safety"
	if int(plan["target_ball"]) != 6:
		return "safety plan should target the nearest legal ball (6), got %s" % plan["target_ball"]
	var direction: Vector3 = plan["direction"]
	if direction.dot(Vector3(1.0, 0.0, 0.0)) < 0.9:
		return "safety plan direction should point roughly at the targeted ball, got %s" % direction
	return ""


## _safety_plan() is the last-resort fallback of plan_shot(); when literally no
## ball on the table is a legal target it must still return a well-formed
## shot instead of erroring or returning an empty dictionary.
func _test_safety_plan_no_legal_balls() -> String:
	var context := _base_context(Vector3.ZERO)
	context["balls"] = [{"number": 5, "position": Vector3(0.0, 0.0, 3.0)}]
	context["legal_numbers"] = []

	var plan: Dictionary = AIOpponent._safety_plan(context)
	var error := ""
	if int(plan["target_ball"]) != -1:
		error = "with no legal ball at all, target_ball should be -1, got %s" % plan["target_ball"]
	if error.is_empty() and not bool(plan["is_safety"]):
		error = "the no-legal-ball fallback must still be flagged as a safety"
	if error.is_empty() and not Vector3(plan["direction"]).is_equal_approx(Vector3.FORWARD):
		error = "the no-legal-ball fallback should aim FORWARD, got %s" % plan["direction"]
	return error


## When a shot_outcome evaluator is supplied, plan_shot() should read where
## the cue ball actually ends up and pick the legal ball with the best
## (lowest) opponent leave-score instead of _safety_plan()'s blind nearest-
## ball tap.
func _test_plan_shot_defensive_fallback() -> String:
	var context := _base_context(Vector3.ZERO)
	var near_ball := Vector3(0.0, 0.0, 3.0)
	var far_ball := Vector3(5.0, 0.0, 0.0)
	context["balls"] = [
		{"number": 5, "position": near_ball},
		{"number": 6, "position": far_ball},
	]
	context["legal_numbers"] = [5, 6]
	context["shot_outcome"] = func(direction: Vector3, _power: float, _opts: Dictionary) -> Dictionary:
		if direction.dot(near_ball.normalized()) > 0.99:
			return {"scratched": false, "first_contact": 5, "opponent_score": 1.0}
		if direction.dot(far_ball.normalized()) > 0.99:
			return {"scratched": false, "first_contact": 6, "opponent_score": 5.0}
		return {"scratched": true}

	var plan: Dictionary = AIOpponent.plan_shot(context)
	var error := ""
	if not bool(plan.get("is_safety", false)):
		error = "a defensive fallback plan should still be flagged as a safety"
	if error.is_empty() and int(plan["target_ball"]) != 5:
		error = "defensive fallback should pick ball 5's lower opponent leave-score, got %s" % plan["target_ball"]
	return error


func _ball_range(low: int, high: int) -> Array[int]:
	var balls: Array[int] = []
	for n in range(low, high + 1):
		balls.append(n)
	return balls


func _base_context(cue_position: Vector3) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = 1
	return {
		"cue_position": cue_position,
		"balls": [],
		"pockets": [],
		"legal_numbers": [],
		"difficulty": AIOpponent.Difficulty.AMATEUR,
		"rng": rng,
	}


func _pocket(id: String, position: Vector3, inward_normal: Vector3) -> Dictionary:
	return {
		"id": id,
		"position": position,
		"inward_normal": inward_normal,
		"mouth_width": 0.6,
	}
