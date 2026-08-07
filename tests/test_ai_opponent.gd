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
	_run_case("a clear straight shot is found and aimed at the pocket", _test_straight_shot_found)
	_run_case("an obstructed path is rejected", _test_obstruction_blocks_shot)
	_run_case("an impossible cut angle is rejected", _test_impossible_cut_rejected)
	_run_case("higher difficulty aims and shoots more precisely", _test_difficulty_scales_precision)
	_run_case("legal_targets restricts to the shooter's group", _test_legal_targets)

	if _failed.is_empty():
		print("PASS: %d AI opponent checks" % _passed)
		return 0
	printerr("FAIL: %d/%d AI opponent checks failed" % [_failed.size(), _passed + _failed.size()])
	for failure in _failed:
		printerr("  - %s" % failure)
	return 1


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
