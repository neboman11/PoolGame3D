class_name NineBallRules
extends RefCounted

## A deterministic, event-driven WPA-style nine-ball referee. Physics code reports
## events during a shot; this class never examines or changes ball motion itself.
## There are no ball groups: the shooter must contact the lowest-numbered ball
## remaining on the table first each shot, and the 9-ball wins the rack outright
## for whoever legally pockets it, regardless of what else is still up.

enum Phase { BREAK, IN_PROGRESS, GAME_OVER }

const NINE_BALL := 9
const MIN_BREAK_RAILS := 4

var phase: Phase = Phase.BREAK
var current_player := 0
var winner := -1

var _first_object_contact := -1
var _pocketed: Array[int] = []
var _rail_after_first_contact := false
var _rail_contacted_balls: Array[int] = []
var _cue_scratch := false
var _lowest_at_shot_start := -1

func reset() -> void:
	phase = Phase.BREAK
	current_player = 0
	winner = -1
	clear_shot()

func begin_shot(_called_pocket: String = "", remaining_object_balls: Array[int] = []) -> void:
	clear_shot()
	_lowest_at_shot_start = _lowest_ball(remaining_object_balls)

func clear_shot() -> void:
	_first_object_contact = -1
	_pocketed.clear()
	_rail_after_first_contact = false
	_rail_contacted_balls.clear()
	_cue_scratch = false
	_lowest_at_shot_start = -1

func record_ball_contact(first: int, second: int) -> void:
	if _first_object_contact >= 0:
		return
	if first == 0 and second != 0:
		_first_object_contact = second
	elif second == 0 and first != 0:
		_first_object_contact = first

func record_rail_contact(ball_number: int) -> void:
	if ball_number > 0 and ball_number not in _rail_contacted_balls:
		_rail_contacted_balls.append(ball_number)
	if _first_object_contact >= 0 and ball_number >= 0:
		_rail_after_first_contact = true

func record_pocket(ball_number: int, _pocket_id: String = "") -> void:
	if ball_number == 0:
		_cue_scratch = true
		return
	if ball_number not in _pocketed:
		_pocketed.append(ball_number)

func resolve_shot(_remaining_object_balls: Array[int] = []) -> Dictionary:
	if phase == Phase.GAME_OVER:
		return _result(false, false, "Rack is over.", false)

	var foul := _cue_scratch or _first_object_contact < 0
	if not foul and _lowest_at_shot_start > 0 and _first_object_contact != _lowest_at_shot_start:
		foul = true
	if phase == Phase.BREAK:
		if not foul and _pocketed.is_empty() and _rail_contacted_balls.size() < MIN_BREAK_RAILS:
			foul = true
	elif not foul and _pocketed.is_empty() and not _rail_after_first_contact:
		foul = true

	if NINE_BALL in _pocketed:
		if phase == Phase.BREAK:
			phase = Phase.IN_PROGRESS
		if foul:
			# The 9 does not end the rack on a foul: it is respotted and the
			# opponent gets ball in hand, same as any other foul.
			current_player = 1 - current_player
			return _result(true, true, "9-ball pocketed on a foul: respotted, ball in hand for opponent.", false, [NINE_BALL])
		phase = Phase.GAME_OVER
		winner = current_player
		return _result(false, false, "9-ball pocketed: you win.", false)

	if phase == Phase.BREAK:
		phase = Phase.IN_PROGRESS

	var continues := not foul and not _pocketed.is_empty()
	if not continues:
		current_player = 1 - current_player

	if foul:
		return _result(true, true, "Foul: ball in hand for opponent.", false)
	return _result(false, false, "Continue shooting." if continues else "Turn passes.", continues)

## Only the lowest-numbered ball left on the table is a legal first contact.
func legal_targets(remaining_object_balls: Array[int]) -> Array[int]:
	var lowest := _lowest_ball(remaining_object_balls)
	return [lowest] if lowest > 0 else remaining_object_balls.duplicate()

## Nine-ball has no called-pocket rule; this stays a harmless no-op so
## GameManager's shared eight-ball-call plumbing works under either ruleset.
func can_call_eight_pocket(_remaining_object_balls: Array[int] = []) -> bool:
	return false

func is_game_over() -> bool:
	return phase == Phase.GAME_OVER

func _lowest_ball(remaining_object_balls: Array[int]) -> int:
	var lowest := -1
	for ball_number in remaining_object_balls:
		if lowest < 0 or ball_number < lowest:
			lowest = ball_number
	return lowest

func _result(foul: bool, ball_in_hand: bool, message: String, continues: bool, respot: Array[int] = []) -> Dictionary:
	return {
		"foul": foul,
		"ball_in_hand": ball_in_hand,
		"continue": continues,
		"winner": winner,
		"current_player": current_player,
		"message": message,
		"first_contact": _first_object_contact,
		"pocketed": _pocketed.duplicate(),
		"respot": respot,
	}
