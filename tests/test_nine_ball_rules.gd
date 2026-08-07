class_name NineBallRulesTests
extends RefCounted

## Event-level rules checks. This avoids scene and physics setup: production code
## only has to report contact, rail, and pocket events to NineBallRules.

const PHASE_GAME_OVER := 2 # NineBallRules.Phase.GAME_OVER
const GAME_TYPE_NINE_BALL := 1 # GameManager.GameType.NINE_BALL


class PocketedBall extends RefCounted:
	var ball_number: int = 0


var _passed := 0
var _failed: Array[String] = []


func run() -> int:
	var prototype_or_error: Variant = _new_rules()
	if prototype_or_error is String:
		printerr("NineBallRules test harness cannot run: %s" % prototype_or_error)
		return 2
	_free_rules(prototype_or_error)

	_run_case("wrong first contact is a foul", _test_wrong_first_contact)
	_run_case("break foul: fewer than four rails and nothing pocketed", _test_break_foul_insufficient_rails)
	_run_case("legal break with four rails passes the turn", _test_legal_break_passes_turn)
	_run_case("scratch is always a foul", _test_scratch_is_foul)
	_run_case("dry legal shot in normal play passes the turn", _test_dry_legal_shot_passes_turn)
	_run_case("legally pocketing the 9-ball wins the rack", _test_nine_ball_legal_win)
	_run_case("pocketing the 9-ball on a foul respots it instead of ending the rack", _test_nine_ball_foul_is_respotted)
	_run_case("GameManager builds NineBallRules and resolves a 9-ball win", _test_game_manager_nine_ball_win)

	if _failed.is_empty():
		print("PASS: %d nine-ball rules checks" % _passed)
		return 0
	printerr("FAIL: %d/%d nine-ball rules checks failed" % [_failed.size(), _passed + _failed.size()])
	for failure in _failed:
		printerr("  - %s" % failure)
	return 1


func _run_case(label: String, test: Callable) -> void:
	var result: Variant = test.call()
	if result == "":
		_passed += 1
		print("PASS: %s" % label)
	else:
		_failed.append("%s: %s" % [label, str(result)])


func _test_wrong_first_contact() -> String:
	var rules_or_error: Variant = _new_rules()
	if rules_or_error is String:
		return rules_or_error
	var rules: Object = rules_or_error
	rules.call("reset")
	rules.call("begin_shot", "", _remaining(1, 9))
	rules.call("record_ball_contact", 0, 5) # lowest remaining is 1, not 5
	rules.call("record_rail_contact", 5)
	var result_or_error: Variant = _resolve(rules)
	var current_player: Variant = rules.get("current_player")
	_free_rules(rules)
	if result_or_error is String:
		return result_or_error
	var result: Dictionary = result_or_error
	if not result.get("foul", false):
		return "contacting a ball other than the lowest on the table was not a foul"
	if not result.get("ball_in_hand", false):
		return "wrong-first-contact foul did not grant ball in hand"
	if current_player != 1:
		return "wrong-first-contact foul did not pass the turn to the opponent"
	return ""


func _test_break_foul_insufficient_rails() -> String:
	var rules_or_error: Variant = _new_rules()
	if rules_or_error is String:
		return rules_or_error
	var rules: Object = rules_or_error
	rules.call("reset")
	rules.call("begin_shot", "", _remaining(1, 9))
	rules.call("record_ball_contact", 0, 1)
	rules.call("record_rail_contact", 2)
	rules.call("record_rail_contact", 3) # only two distinct balls reached a rail
	var result_or_error: Variant = _resolve(rules)
	_free_rules(rules)
	if result_or_error is String:
		return result_or_error
	var result: Dictionary = result_or_error
	if not result.get("foul", false) or not result.get("ball_in_hand", false):
		return "an opening break with fewer than four balls to a rail and nothing pocketed must be a foul"
	return ""


func _test_legal_break_passes_turn() -> String:
	var rules_or_error: Variant = _new_rules()
	if rules_or_error is String:
		return rules_or_error
	var rules: Object = rules_or_error
	rules.call("reset")
	rules.call("begin_shot", "", _remaining(1, 9))
	rules.call("record_ball_contact", 0, 1)
	for ball_number in [2, 3, 4, 5]:
		rules.call("record_rail_contact", ball_number)
	var result_or_error: Variant = _resolve(rules)
	var current_player: Variant = rules.get("current_player")
	var phase: Variant = rules.get("phase")
	_free_rules(rules)
	if result_or_error is String:
		return result_or_error
	var result: Dictionary = result_or_error
	if result.get("foul", true):
		return "a break sending four balls to a rail should not be a foul"
	if current_player != 1:
		return "a dry break (nothing pocketed) should pass the turn"
	if phase == PHASE_GAME_OVER:
		return "a dry legal break must not end the rack"
	return ""


func _test_scratch_is_foul() -> String:
	var rules_or_error: Variant = _new_rules()
	if rules_or_error is String:
		return rules_or_error
	var rules: Object = rules_or_error
	rules.call("reset")
	rules.call("begin_shot", "", _remaining(1, 9))
	rules.call("record_ball_contact", 0, 1)
	rules.call("record_pocket", 0)
	var result_or_error: Variant = _resolve(rules)
	var current_player: Variant = rules.get("current_player")
	_free_rules(rules)
	if result_or_error is String:
		return result_or_error
	var result: Dictionary = result_or_error
	if not result.get("foul", false) or not result.get("ball_in_hand", false):
		return "a cue-ball scratch must be a ball-in-hand foul"
	if current_player != 1:
		return "scratch did not pass the turn to the opponent"
	return ""


func _test_dry_legal_shot_passes_turn() -> String:
	var rules_or_error: Variant = _new_rules()
	if rules_or_error is String:
		return rules_or_error
	var rules: Object = rules_or_error
	rules.call("reset")
	# A legal, dry break moves play out of the four-rail break rule.
	rules.call("begin_shot", "", _remaining(1, 9))
	rules.call("record_ball_contact", 0, 1)
	for ball_number in [2, 3, 4, 5]:
		rules.call("record_rail_contact", ball_number)
	var break_result_or_error: Variant = _resolve(rules)
	if break_result_or_error is String:
		_free_rules(rules)
		return break_result_or_error

	rules.call("begin_shot", "", _remaining(1, 9))
	rules.call("record_ball_contact", 0, 1)
	rules.call("record_rail_contact", 1)
	var result_or_error: Variant = _resolve(rules)
	var current_player: Variant = rules.get("current_player")
	_free_rules(rules)
	if result_or_error is String:
		return result_or_error
	var result: Dictionary = result_or_error
	if result.get("foul", true):
		return "a legal shot that sends a ball to a rail should not be a foul"
	if result.get("continue", true):
		return "a dry shot (nothing pocketed) must pass the turn"
	if current_player != 0:
		return "a dry shot after the break did not return the turn to player one"
	return ""


func _test_nine_ball_legal_win() -> String:
	var rules_or_error: Variant = _new_rules()
	if rules_or_error is String:
		return rules_or_error
	var rules: Object = rules_or_error
	rules.call("reset")
	var only_nine: Array[int] = [9]
	rules.call("begin_shot", "", only_nine) # every other ball already cleared
	rules.call("record_ball_contact", 0, 9)
	rules.call("record_pocket", 9)
	var result_or_error: Variant = _resolve(rules)
	var winner: Variant = rules.get("winner")
	var phase: Variant = rules.get("phase")
	_free_rules(rules)
	if result_or_error is String:
		return result_or_error
	var result: Dictionary = result_or_error
	if result.get("foul", true) or winner != 0 or phase != PHASE_GAME_OVER:
		return "legally pocketing the 9-ball did not win the rack for the shooter"
	return ""


func _test_nine_ball_foul_is_respotted() -> String:
	var rules_or_error: Variant = _new_rules()
	if rules_or_error is String:
		return rules_or_error
	var rules: Object = rules_or_error
	rules.call("reset")
	rules.call("begin_shot", "", _remaining(1, 9))
	rules.call("record_ball_contact", 0, 5) # lowest remaining is 1: this is a foul
	rules.call("record_pocket", 9) # combos the 9 in anyway
	var result_or_error: Variant = _resolve(rules)
	var winner: Variant = rules.get("winner")
	var phase: Variant = rules.get("phase")
	var current_player: Variant = rules.get("current_player")
	_free_rules(rules)
	if result_or_error is String:
		return result_or_error
	var result: Dictionary = result_or_error
	if not result.get("foul", false) or not result.get("ball_in_hand", false):
		return "pocketing the 9-ball on a foul must still be a foul with ball in hand"
	if winner != -1 or phase == PHASE_GAME_OVER:
		return "pocketing the 9-ball on a foul must not end the rack"
	if current_player != 1:
		return "the foul did not pass the turn to the opponent"
	var respot: Variant = result.get("respot", [])
	if not respot is Array or 9 not in respot:
		return "pocketing the 9-ball on a foul must report it for respotting"
	return ""


func _test_game_manager_nine_ball_win() -> String:
	var manager_or_error: Variant = _new_game_manager()
	if manager_or_error is String:
		return manager_or_error
	var manager: Object = manager_or_error
	manager.set("game_type", GAME_TYPE_NINE_BALL)
	manager.call("reset_state")
	var rules: Variant = manager.get("rules")
	if rules == null or not rules.has_method("legal_targets"):
		_free_rules(manager)
		return "GameManager did not build a NineBallRules instance for GameType.NINE_BALL"
	if int(manager.call("rack_ball_count")) != 9:
		_free_rules(manager)
		return "GameManager.rack_ball_count() must be 9 for nine-ball"

	var pocketed: Array[int] = []
	for ball_number in range(1, 9):
		manager.call("begin_shot")
		manager.call("on_ball_contacted", 0, ball_number)
		_manager_record_pocket(manager, ball_number)
		pocketed.append(ball_number)
		var step_result: Variant = manager.call("settle_shot", _remaining_except(pocketed))
		if not step_result is Dictionary or bool(step_result.get("foul", true)):
			_free_rules(manager)
			return "could not legally clear ball %d through GameManager" % ball_number

	manager.call("begin_shot")
	manager.call("on_ball_contacted", 0, 9)
	_manager_record_pocket(manager, 9)
	pocketed.append(9)
	var result_or_error: Variant = manager.call("settle_shot", _remaining_except(pocketed))
	if not result_or_error is Dictionary:
		_free_rules(manager)
		return "GameManager.settle_shot() must return a Dictionary"
	var result: Dictionary = result_or_error

	var failure := ""
	if result.get("winner", -1) != 0:
		failure = "clearing 1 through 9 in order did not award the rack to the shooter"
	elif not manager.has_method("is_game_over") or not bool(manager.call("is_game_over")):
		failure = "the 9-ball win did not expose a finished-rack state"

	_free_rules(manager)
	return failure


func _manager_record_pocket(manager: Object, ball_number: int) -> void:
	var ball := PocketedBall.new()
	ball.ball_number = ball_number
	manager.call("on_ball_pocketed", ball)


func _resolve(rules: Object) -> Variant:
	var empty_remaining: Array[int] = []
	var result: Variant = rules.call("resolve_shot", empty_remaining)
	if not result is Dictionary:
		return "resolve_shot() must return Dictionary, got %s" % type_string(typeof(result))
	return result


func _remaining(low: int, high: int) -> Array[int]:
	var balls: Array[int] = []
	for ball_number in range(low, high + 1):
		balls.append(ball_number)
	return balls


func _remaining_except(excluded: Array[int]) -> Array[int]:
	var balls: Array[int] = []
	for ball_number in range(1, 10):
		if ball_number not in excluded:
			balls.append(ball_number)
	return balls


func _new_rules() -> Variant:
	var script_path := "res://scripts/nine_ball_rules.gd"
	if not ResourceLoader.exists(script_path):
		return "res://scripts/nine_ball_rules.gd is not available"
	var script: Variant = load(script_path)
	if not script is Script:
		return "nine_ball_rules.gd did not load as a Script"
	var rules: Variant = script.new()
	if not rules is Object:
		return "NineBallRules could not be instantiated"
	for method_name in ["reset", "begin_shot", "record_ball_contact", "record_rail_contact", "record_pocket", "resolve_shot", "legal_targets", "is_game_over"]:
		if not rules.has_method(method_name):
			_free_rules(rules)
			return "NineBallRules lacks %s()" % method_name
	return rules


func _new_game_manager() -> Variant:
	var script_path := "res://scripts/game_manager.gd"
	if not ResourceLoader.exists(script_path):
		return "%s is not available" % script_path
	var script: Variant = load(script_path)
	if not script is Script:
		return "game_manager.gd did not load as a Script"
	var manager: Variant = script.new()
	if not manager is Object:
		return "GameManager could not be instantiated"
	for method_name in ["reset_state", "rack_ball_count", "begin_shot", "on_ball_contacted", "on_ball_pocketed", "settle_shot", "is_game_over"]:
		if not manager.has_method(method_name):
			_free_rules(manager)
			return "GameManager lacks %s()" % method_name
	return manager


func _free_rules(rules: Variant) -> void:
	if rules is Node:
		rules.free()
