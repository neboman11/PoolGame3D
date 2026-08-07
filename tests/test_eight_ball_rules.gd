class_name EightBallRulesTests
extends RefCounted

## Event-level rules checks. This avoids scene and physics setup: production code
## only has to report contact, rail, and pocket events to EightBallRules.

const GROUP_UNASSIGNED := 0
const GROUP_SOLIDS := 1
const GROUP_STRIPES := 2
const PHASE_GAME_OVER := 3


class PocketedBall extends RefCounted:
	var ball_number: int = 0

var _passed := 0
var _failed: Array[String] = []


func run() -> int:
	var prototype_or_error: Variant = _new_rules()
	if prototype_or_error is String:
		printerr("EightBallRules test harness cannot run: %s" % prototype_or_error)
		return 2
	_free_rules(prototype_or_error)

	_run_case("group assignment after open-table pocket", _test_group_assignment)
	_run_case("wrong first contact is a foul", _test_wrong_first_contact)
	_run_case("scratch awards ball in hand", _test_scratch_ball_in_hand)
	_run_case("8-ball eligibility and called-pocket outcomes", _test_eight_ball_outcomes)
	_run_case("other player 8-ball ends the rack", _test_other_player_eight_ball_ends_game)

	if _failed.is_empty():
		print("PASS: %d eight-ball rules checks" % _passed)
		return 0
	printerr("FAIL: %d/%d eight-ball rules checks failed" % [_failed.size(), _passed + _failed.size()])
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


func _test_group_assignment() -> String:
	var rules_or_error: Variant = _assigned_solids_rules()
	if rules_or_error is String:
		return rules_or_error
	var rules: Object = rules_or_error
	var groups: Variant = rules.get("player_groups")
	var phase: Variant = rules.get("phase")
	_free_rules(rules)
	if not groups is Array or groups.size() != 2:
		return "player_groups must contain both player assignments"
	if groups[0] != GROUP_SOLIDS or groups[1] != GROUP_STRIPES:
		return "expected player 1 SOLIDS and player 2 STRIPES, got %s" % [groups]
	if phase != 2: # EightBallRules.Phase.GROUPS_ASSIGNED
		return "groups were assigned but phase is not GROUPS_ASSIGNED"
	return ""


func _test_wrong_first_contact() -> String:
	var rules_or_error: Variant = _assigned_solids_rules()
	if rules_or_error is String:
		return rules_or_error
	var rules: Object = rules_or_error
	rules.call("begin_shot")
	rules.call("record_ball_contact", 0, 9)
	rules.call("record_rail_contact", 9)
	var result_or_error: Variant = _resolve(rules, _remaining_except([1]))
	var current_player: Variant = rules.get("current_player")
	_free_rules(rules)
	if result_or_error is String:
		return result_or_error
	var result: Dictionary = result_or_error
	if not result.get("foul", false):
		return "stripes were contacted first while shooter owned solids"
	if not result.get("ball_in_hand", false):
		return "wrong-first-contact foul did not grant ball in hand"
	if current_player != 1:
		return "wrong-first-contact foul did not pass turn to opponent"
	return ""


func _test_scratch_ball_in_hand() -> String:
	var rules_or_error: Variant = _new_rules()
	if rules_or_error is String:
		return rules_or_error
	var rules: Object = rules_or_error
	rules.call("reset")
	rules.call("begin_shot")
	rules.call("record_ball_contact", 0, 1)
	rules.call("record_pocket", 0)
	var result_or_error: Variant = _resolve(rules, _remaining_except([]))
	var current_player: Variant = rules.get("current_player")
	_free_rules(rules)
	if result_or_error is String:
		return result_or_error
	var result: Dictionary = result_or_error
	if not result.get("foul", false) or not result.get("ball_in_hand", false):
		return "cue-ball scratch must be a ball-in-hand foul"
	if current_player != 1:
		return "scratch did not pass turn to opponent"
	return ""


func _test_eight_ball_outcomes() -> String:
	var legal_or_error: Variant = _assigned_solids_rules()
	if legal_or_error is String:
		return legal_or_error
	var legal_rules: Object = legal_or_error
	var legal_remaining := _remaining_except([1, 2, 3, 4, 5, 6, 7])
	legal_rules.call("begin_shot", "corner_right_top", legal_remaining)
	legal_rules.call("record_ball_contact", 0, 8)
	legal_rules.call("record_pocket", 8, "corner_right_top")
	var legal_result_or_error: Variant = _resolve(legal_rules, legal_remaining)
	var legal_winner: Variant = legal_rules.get("winner")
	var legal_phase: Variant = legal_rules.get("phase")
	_free_rules(legal_rules)
	if legal_result_or_error is String:
		return legal_result_or_error
	var legal_result: Dictionary = legal_result_or_error
	if legal_result.get("foul", true) or legal_winner != 0 or legal_phase != PHASE_GAME_OVER:
		return "pocketing the 8 after clearing own group was not a legal win"

	var missed_or_error: Variant = _assigned_solids_rules()
	if missed_or_error is String:
		return missed_or_error
	var missed_rules: Object = missed_or_error
	var missed_remaining := _remaining_except([1, 2, 3, 4, 5, 6, 7])
	missed_rules.call("begin_shot", "corner_right_top", missed_remaining)
	missed_rules.call("record_ball_contact", 0, 8)
	missed_rules.call("record_rail_contact", 8)
	var missed_result_or_error: Variant = _resolve(missed_rules, missed_remaining)
	_free_rules(missed_rules)
	if missed_result_or_error is String:
		return missed_result_or_error
	var missed_result: Dictionary = missed_result_or_error
	if missed_result.get("foul", true) or missed_result.get("ball_in_hand", true):
		return "shooting at the 8 after clearing own group incorrectly gave ball in hand"

	var early_or_error: Variant = _assigned_solids_rules()
	if early_or_error is String:
		return early_or_error
	var early_rules: Object = early_or_error
	var early_remaining := _remaining_except([1, 2, 3, 4, 5, 6])
	early_rules.call("begin_shot", "corner_right_top", early_remaining)
	early_rules.call("record_ball_contact", 0, 8)
	early_rules.call("record_pocket", 8, "corner_right_top")
	early_rules.call("record_pocket", 7)
	var early_result_or_error: Variant = _resolve(early_rules, _remaining_except([1, 2, 3, 4, 5, 6, 7]))
	var early_winner: Variant = early_rules.get("winner")
	_free_rules(early_rules)
	if early_result_or_error is String:
		return early_result_or_error
	var early_result: Dictionary = early_result_or_error
	if not early_result.get("foul", false) or early_winner != 1:
		return "pocketing the 8 before clearing the final group ball did not lose the rack"

	var uncalled_or_error: Variant = _assigned_solids_rules()
	if uncalled_or_error is String:
		return uncalled_or_error
	var uncalled_rules: Object = uncalled_or_error
	var uncalled_remaining := _remaining_except([1, 2, 3, 4, 5, 6, 7])
	uncalled_rules.call("begin_shot", "", uncalled_remaining)
	uncalled_rules.call("record_ball_contact", 0, 8)
	uncalled_rules.call("record_pocket", 8, "corner_right_top")
	var uncalled_result_or_error: Variant = _resolve(uncalled_rules, uncalled_remaining)
	var uncalled_winner: Variant = uncalled_rules.get("winner")
	_free_rules(uncalled_rules)
	if uncalled_result_or_error is String:
		return uncalled_result_or_error
	var uncalled_result: Dictionary = uncalled_result_or_error
	if not uncalled_result.get("foul", false) or uncalled_winner != 1:
		return "an uncalled 8-ball pocket did not award the rack to the opponent"

	var illegal_or_error: Variant = _new_rules()
	if illegal_or_error is String:
		return illegal_or_error
	var illegal_rules: Object = illegal_or_error
	illegal_rules.call("reset")
	illegal_rules.call("begin_shot")
	illegal_rules.call("record_ball_contact", 0, 8)
	illegal_rules.call("record_pocket", 8)
	var illegal_result_or_error: Variant = _resolve(illegal_rules, _remaining_except([]))
	var illegal_winner: Variant = illegal_rules.get("winner")
	var illegal_phase: Variant = illegal_rules.get("phase")
	_free_rules(illegal_rules)
	if illegal_result_or_error is String:
		return illegal_result_or_error
	var illegal_result: Dictionary = illegal_result_or_error
	if not illegal_result.get("foul", false) or illegal_winner != 1 or illegal_phase != PHASE_GAME_OVER:
		return "early 8-ball pocket did not award the rack to the opponent"
	return ""


func _test_other_player_eight_ball_ends_game() -> String:
	# Mirror the production signal route: player two pockets the final 8-ball,
	# then GameManager resolves the settled shot.  The rack must close before
	# either player can start another shot.
	var manager_or_error: Variant = _new_game_manager()
	if manager_or_error is String:
		return manager_or_error
	var manager: Object = manager_or_error
	var rules: Object = manager.get("rules")
	if rules == null:
		_free_rules(manager)
		return "GameManager did not create its EightBallRules instance"
	if bool(manager.call("call_eight_pocket", "corner_right_top")):
		_free_rules(manager)
		return "GameManager accepted an 8-ball pocket call before the group was cleared"

	# Break and open-table pocket establish player one as solids and player two
	# as stripes through the same manager event methods the game uses.
	manager.call("begin_shot")
	manager.call("on_ball_contacted", 0, 1)
	_manager_record_pocket(manager, 1)
	var result_or_error: Variant = manager.call("settle_shot", _remaining_except([1]))
	if not result_or_error is Dictionary or bool(result_or_error.get("foul", true)):
		_free_rules(manager)
		return "could not establish a legal break through GameManager"

	manager.call("begin_shot")
	manager.call("on_ball_contacted", 0, 2)
	_manager_record_pocket(manager, 2)
	result_or_error = manager.call("settle_shot", _remaining_except([1, 2]))
	if not result_or_error is Dictionary or bool(result_or_error.get("foul", true)):
		_free_rules(manager)
		return "could not assign groups through GameManager"

	# A legal dry solids shot hands the table to player two.
	manager.call("begin_shot")
	manager.call("on_ball_contacted", 0, 3)
	manager.call("on_ball_hit_cushion", 3)
	result_or_error = manager.call("settle_shot", _remaining_except([1, 2]))
	if not result_or_error is Dictionary or bool(result_or_error.get("foul", true)):
		_free_rules(manager)
		return "could not pass the turn to player two through GameManager"
	if rules.get("current_player") != 1 or rules.get("player_groups") != [GROUP_SOLIDS, GROUP_STRIPES]:
		_free_rules(manager)
		return "GameManager did not establish player two as the stripes shooter"

	var pocketed_before_final: Array[int] = [1, 2]
	for stripe in range(9, 16):
		manager.call("begin_shot")
		manager.call("on_ball_contacted", 0, stripe)
		_manager_record_pocket(manager, stripe)
		pocketed_before_final.append(stripe)
		result_or_error = manager.call("settle_shot", _remaining_except(pocketed_before_final))
		if not result_or_error is Dictionary or bool(result_or_error.get("foul", true)):
			_free_rules(manager)
			return "could not clear player two's stripes through GameManager"

	if not manager.has_method("call_eight_pocket") or not bool(manager.call("call_eight_pocket", "corner_right_top")):
		_free_rules(manager)
		return "GameManager did not accept the 8-ball pocket call"
	if not manager.has_method("clear_eight_pocket_call") or not bool(manager.call("clear_eight_pocket_call")) or manager.get("called_eight_pocket") != "":
		_free_rules(manager)
		return "GameManager did not clear a pending 8-ball pocket call"
	if not bool(manager.call("call_eight_pocket", "corner_right_top")):
		_free_rules(manager)
		return "GameManager did not accept the replacement 8-ball pocket call"
	manager.call("begin_shot")
	manager.call("on_ball_contacted", 0, 8)
	_manager_record_pocket_entry(manager, 8, "corner_right_top")
	_manager_record_pocket(manager, 8)

	var pocketed_after_final: Array[int] = pocketed_before_final.duplicate()
	pocketed_after_final.append(8)
	var remaining_object_balls := _remaining_except(pocketed_after_final)
	result_or_error = manager.call("settle_shot", remaining_object_balls)
	if not result_or_error is Dictionary:
		_free_rules(manager)
		return "GameManager.settle_shot() must return a Dictionary"
	var result: Dictionary = result_or_error

	var failure := ""
	if result.get("winner", -1) != 1 or rules.get("winner") != 1:
		failure = "player two's legal 8-ball did not award player two the rack"
	elif not manager.has_method("is_game_over") or not bool(manager.call("is_game_over")):
		failure = "8-ball resolution did not expose a finished-rack state"
	elif not manager.has_method("can_begin_shot") or bool(manager.call("can_begin_shot")):
		failure = "a new shot can begin after the 8-ball ended the rack"

	_free_rules(manager)
	return failure


func _manager_record_pocket(manager: Object, ball_number: int) -> void:
	var ball := PocketedBall.new()
	ball.ball_number = ball_number
	manager.call("on_ball_pocketed", ball)


func _manager_record_pocket_entry(manager: Object, ball_number: int, pocket_id: String) -> void:
	var ball := PocketedBall.new()
	ball.ball_number = ball_number
	manager.call("on_ball_entered_pocket", ball, pocket_id)


func _assigned_solids_rules() -> Variant:
	var rules_or_error: Variant = _new_rules()
	if rules_or_error is String:
		return rules_or_error
	var rules: Object = rules_or_error
	rules.call("reset")
	# A dry break opens the table and passes play to player 2. A legal dry
	# open-table shot then passes it back to player 1, who assigns solids.
	var error: String = _play_dry_legal_shot(rules, 1)
	if error == "":
		error = _play_dry_legal_shot(rules, 9)
	if error != "":
		_free_rules(rules)
		return error
	rules.call("begin_shot")
	rules.call("record_ball_contact", 0, 1)
	rules.call("record_pocket", 1)
	var result_or_error: Variant = _resolve(rules, _remaining_except([1]))
	if result_or_error is String:
		_free_rules(rules)
		return result_or_error
	var groups: Variant = rules.get("player_groups")
	if not groups is Array or groups.size() != 2 or groups[0] != GROUP_SOLIDS:
		_free_rules(rules)
		return "could not establish player 1 as solids"
	return rules


func _play_dry_legal_shot(rules: Object, contacted_ball: int) -> String:
	rules.call("begin_shot")
	rules.call("record_ball_contact", 0, contacted_ball)
	rules.call("record_rail_contact", contacted_ball)
	var result_or_error: Variant = _resolve(rules, _remaining_except([]))
	if result_or_error is String:
		return result_or_error
	var result: Dictionary = result_or_error
	if result.get("foul", false):
		return "setup dry shot on ball %s was unexpectedly a foul" % contacted_ball
	return ""


func _resolve(rules: Object, remaining_object_balls: Array[int]) -> Variant:
	var result: Variant = rules.call("resolve_shot", remaining_object_balls)
	if not result is Dictionary:
		return "resolve_shot() must return Dictionary, got %s" % type_string(typeof(result))
	return result


func _remaining_except(excluded: Array[int]) -> Array[int]:
	var balls: Array[int] = []
	for ball_number in range(1, 16):
		if ball_number not in excluded:
			balls.append(ball_number)
	return balls


func _new_rules() -> Variant:
	var script_path := "res://scripts/eight_ball_rules.gd"
	if not ResourceLoader.exists(script_path):
		return "res://scripts/eight_ball_rules.gd is not available"
	var script: Variant = load(script_path)
	if not script is Script:
		return "eight_ball_rules.gd did not load as a Script"
	var rules: Variant = script.new()
	if not rules is Object:
		return "EightBallRules could not be instantiated"
	for method_name in ["reset", "begin_shot", "record_ball_contact", "record_rail_contact", "record_pocket", "resolve_shot"]:
		if not rules.has_method(method_name):
			_free_rules(rules)
			return "EightBallRules lacks %s()" % method_name
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
	for method_name in ["begin_shot", "call_eight_pocket", "on_ball_contacted", "on_ball_entered_pocket", "on_ball_pocketed", "settle_shot"]:
		if not manager.has_method(method_name):
			_free_rules(manager)
			return "GameManager lacks %s()" % method_name
	return manager


func _free_rules(rules: Variant) -> void:
	if rules is Node:
		rules.free()
