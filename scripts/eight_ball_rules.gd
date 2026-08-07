class_name EightBallRules
extends RefCounted

## A deterministic, event-driven WPA-style eight-ball referee. Physics code reports
## events during a shot; this class never examines or changes ball motion itself.

enum Group { UNASSIGNED, SOLIDS, STRIPES }
enum Phase { BREAK, OPEN_TABLE, GROUPS_ASSIGNED, GAME_OVER }

var phase: Phase = Phase.BREAK
var current_player := 0
var player_groups: Array[Group] = [Group.UNASSIGNED, Group.UNASSIGNED]
var winner := -1

var _first_object_contact := -1
var _pocketed: Array[int] = []
var _rail_after_first_contact := false
var _cue_scratch := false
var _called_eight_pocket := ""
var _eight_pocket := ""
var _eight_was_legal_at_shot_start := false

func reset() -> void:
	phase = Phase.BREAK
	current_player = 0
	player_groups = [Group.UNASSIGNED, Group.UNASSIGNED]
	winner = -1
	clear_shot()

func begin_shot(called_eight_pocket: String = "", remaining_object_balls: Array[int] = []) -> void:
	clear_shot()
	_called_eight_pocket = called_eight_pocket
	var own_group := player_groups[current_player]
	_eight_was_legal_at_shot_start = not remaining_object_balls.is_empty() and own_group != Group.UNASSIGNED and _own_group_cleared(own_group, remaining_object_balls)

func clear_shot() -> void:
	_first_object_contact = -1
	_pocketed.clear()
	_rail_after_first_contact = false
	_cue_scratch = false
	_called_eight_pocket = ""
	_eight_pocket = ""
	_eight_was_legal_at_shot_start = false

func record_ball_contact(first: int, second: int) -> void:
	if _first_object_contact >= 0:
		return
	if first == 0 and second != 0:
		_first_object_contact = second
	elif second == 0 and first != 0:
		_first_object_contact = first

func record_rail_contact(ball_number: int) -> void:
	if _first_object_contact >= 0 and ball_number >= 0:
		_rail_after_first_contact = true

func record_pocket(ball_number: int, pocket_id: String = "") -> void:
	if ball_number == 0:
		_cue_scratch = true
		return
	if ball_number == 8 and not pocket_id.is_empty():
		_eight_pocket = pocket_id
	if ball_number not in _pocketed:
		_pocketed.append(ball_number)

func resolve_shot(remaining_object_balls: Array[int]) -> Dictionary:
	if phase == Phase.GAME_OVER:
		return _result(false, false, "Rack is over.")

	var foul := _cue_scratch or _first_object_contact < 0
	var own_group := player_groups[current_player]
	if not foul and own_group != Group.UNASSIGNED:
		if _first_object_contact == 8:
			foul = not _eight_was_legal_at_shot_start
		elif _group_for_ball(_first_object_contact) != own_group:
			foul = true
	elif not foul and _first_object_contact == 8:
		foul = true

	if not foul and _pocketed.is_empty() and not _rail_after_first_contact:
		foul = true

	var eight_pocketed := 8 in _pocketed
	if eight_pocketed:
		if foul or own_group == Group.UNASSIGNED or not _eight_was_legal_at_shot_start or not _eight_pocket_matches_call():
			phase = Phase.GAME_OVER
			winner = 1 - current_player
			return _result(true, true, "Illegal 8-ball: opponent wins.")
		phase = Phase.GAME_OVER
		winner = current_player
		return _result(false, false, "8-ball pocketed: you win.")

	if not foul and phase == Phase.OPEN_TABLE:
		var called_group := _first_pocketed_group()
		if called_group != Group.UNASSIGNED:
			player_groups[current_player] = called_group
			player_groups[1 - current_player] = _opposite(called_group)
			phase = Phase.GROUPS_ASSIGNED

	var continues := not foul and _pocketed_own_group(player_groups[current_player])
	if phase == Phase.BREAK:
		phase = Phase.OPEN_TABLE
		continues = not foul and not _pocketed.is_empty()
	if not continues:
		current_player = 1 - current_player

	if foul:
		return _result(true, true, "Foul: ball in hand for opponent.")
	return _result(false, false, "Continue shooting." if continues else "Turn passes.")

## Balls the current player may legally strike first, given what remains on
## the table. Shared by shot-selection code (e.g. the AI opponent) so it
## follows the same group rules as `resolve_shot` instead of a duplicate copy.
func legal_targets(remaining_object_balls: Array[int]) -> Array[int]:
	var own_group := player_groups[current_player]
	if own_group == Group.UNASSIGNED:
		var non_eight: Array[int] = []
		for ball_number in remaining_object_balls:
			if ball_number != 8:
				non_eight.append(ball_number)
		return non_eight if not non_eight.is_empty() else remaining_object_balls.duplicate()
	var own: Array[int] = []
	for ball_number in remaining_object_balls:
		if _group_for_ball(ball_number) == own_group:
			own.append(ball_number)
	if own.is_empty():
		return [8] if 8 in remaining_object_balls else remaining_object_balls.duplicate()
	return own

## The 8 is available as soon as the shooter's seven assigned balls are gone;
## the opponent's balls remain on the table and must not make this a foul.
func can_call_eight_pocket(remaining_object_balls: Array[int]) -> bool:
	var own_group := player_groups[current_player]
	return phase == Phase.GROUPS_ASSIGNED and own_group != Group.UNASSIGNED and 8 in remaining_object_balls and _own_group_cleared(own_group, remaining_object_balls)

func is_game_over() -> bool:
	return phase == Phase.GAME_OVER

func _own_group_cleared(group: Group, remaining_object_balls: Array[int]) -> bool:
	for ball_number in remaining_object_balls:
		if _group_for_ball(ball_number) == group:
			return false
	return true

func _eight_pocket_matches_call() -> bool:
	return not _called_eight_pocket.is_empty() and _called_eight_pocket == _eight_pocket

func _first_pocketed_group() -> Group:
	for ball_number in _pocketed:
		var group := _group_for_ball(ball_number)
		if group != Group.UNASSIGNED:
			return group
	return Group.UNASSIGNED

func _pocketed_own_group(group: Group) -> bool:
	if group == Group.UNASSIGNED:
		return not _pocketed.is_empty()
	for ball_number in _pocketed:
		if _group_for_ball(ball_number) == group:
			return true
	return false

func _group_for_ball(ball_number: int) -> Group:
	if ball_number >= 1 and ball_number <= 7:
		return Group.SOLIDS
	if ball_number >= 9 and ball_number <= 15:
		return Group.STRIPES
	return Group.UNASSIGNED

func _opposite(group: Group) -> Group:
	return Group.STRIPES if group == Group.SOLIDS else Group.SOLIDS

func _result(foul: bool, ball_in_hand: bool, message: String) -> Dictionary:
	return {
		"foul": foul,
		"ball_in_hand": ball_in_hand,
		"continue": not foul and winner < 0 and _pocketed_own_group(player_groups[current_player]),
		"winner": winner,
		"current_player": current_player,
		"message": message,
		"first_contact": _first_object_contact,
		"pocketed": _pocketed.duplicate(),
		"called_eight_pocket": _called_eight_pocket,
		"eight_pocket": _eight_pocket,
	}
