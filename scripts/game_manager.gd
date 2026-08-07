extends Node

## Cross-scene match state and the sole bridge from physical shot events to
## eight-ball rules. The physics world remains authoritative for motion.

const AI_OPPONENT := preload("res://scripts/ai_opponent.gd")
const AI_PLAYER_INDEX := 1

enum GameType { EIGHT_BALL, NINE_BALL }

const EIGHT_BALL_POCKET_IDS := [
	"corner_right_top",
	"corner_right_bottom",
	"corner_left_top",
	"corner_left_bottom",
	"side_top",
	"side_bottom",
]

signal ball_pocketed(ball_number: int)
signal balls_settled
signal shot_resolved(result: Dictionary)

var pocketed_balls: Array[int] = []
var current_game: Node = null
var rules = EightBallRules.new() # EightBallRules or NineBallRules, chosen by game_type
var ball_in_hand := false
var active_shot := false
var called_eight_pocket := ""

## Set by the main menu before start_game(). Persists across rerack() so a
## rack reset doesn't silently drop back to hot-seat multiplayer.
var vs_ai := false
var ai_difficulty: int = AI_OPPONENT.Difficulty.AMATEUR

## Set by the main menu before start_game(). Persists across rerack() so a
## rack reset doesn't silently switch game types mid-match.
var game_type: GameType = GameType.EIGHT_BALL

func goto_scene(path: String) -> void:
	get_tree().change_scene_to_file(path)

func start_game() -> void:
	reset_state()
	goto_scene("res://scenes/Game.tscn")

func goto_menu() -> void:
	goto_scene("res://scenes/MainMenu.tscn")

func reset_state() -> void:
	pocketed_balls.clear()
	rules = NineBallRules.new() if game_type == GameType.NINE_BALL else EightBallRules.new()
	rules.reset()
	ball_in_hand = false
	active_shot = false
	called_eight_pocket = ""

func register_game(game_node: Node) -> void:
	current_game = game_node

func is_game_over() -> bool:
	return rules.is_game_over()

## Number of object balls racked for the current game type (1-9 for nine-ball,
## 1-15 for eight-ball).
func rack_ball_count() -> int:
	return 9 if game_type == GameType.NINE_BALL else 15


func can_begin_shot() -> bool:
	return not active_shot and not is_game_over()


func call_eight_pocket(pocket_id: String) -> bool:
	if active_shot or is_game_over() or pocket_id not in EIGHT_BALL_POCKET_IDS or not can_call_eight_pocket():
		return false
	called_eight_pocket = pocket_id
	return true


func clear_eight_pocket_call() -> bool:
	if active_shot:
		return false
	called_eight_pocket = ""
	return true


func can_call_eight_pocket() -> bool:
	return rules.can_call_eight_pocket(_remaining_object_ball_numbers())


func begin_shot() -> bool:
	if not can_begin_shot():
		return false
	active_shot = true
	rules.begin_shot(called_eight_pocket, _remaining_object_ball_numbers())
	called_eight_pocket = ""
	return true

func on_ball_pocketed(ball) -> void:
	var ball_number: int = ball.ball_number
	if ball_number != 0 and ball_number not in pocketed_balls:
		pocketed_balls.append(ball_number)
	rules.record_pocket(ball_number)
	ball_pocketed.emit(ball_number)


func on_ball_entered_pocket(ball, pocket_id: String) -> void:
	if not active_shot or ball == null:
		return
	rules.record_pocket(int(ball.ball_number), pocket_id)


func _remaining_object_ball_numbers() -> Array[int]:
	var remaining: Array[int] = []
	for ball_number in range(1, rack_ball_count() + 1):
		if ball_number not in pocketed_balls:
			remaining.append(ball_number)
	return remaining

func on_ball_contacted(first: int, second: int) -> void:
	if active_shot:
		rules.record_ball_contact(first, second)

func on_ball_hit_cushion(ball_number: int) -> void:
	if active_shot:
		rules.record_rail_contact(ball_number)

func settle_shot(remaining_object_balls: Array[int]) -> Dictionary:
	if not active_shot:
		return {}
	active_shot = false
	var result: Dictionary = rules.resolve_shot(remaining_object_balls)
	ball_in_hand = bool(result.get("ball_in_hand", false))
	balls_settled.emit()
	shot_resolved.emit(result)
	return result

func turn_label() -> String:
	if rules.is_game_over():
		return "%s wins" % _player_label(rules.winner)
	if game_type == GameType.NINE_BALL:
		return "%s's shot" % _player_label(rules.current_player)
	var group: EightBallRules.Group = rules.player_groups[rules.current_player]
	var group_label := "open table"
	if group == EightBallRules.Group.SOLIDS:
		group_label = "solids"
	elif group == EightBallRules.Group.STRIPES:
		group_label = "stripes"
	return "%s — %s" % [_player_label(rules.current_player), group_label]

func _player_label(player_index: int) -> String:
	if vs_ai and player_index == AI_PLAYER_INDEX:
		return "AI (%s)" % AI_OPPONENT.label_for(ai_difficulty)
	return "Player %d" % (player_index + 1)

func quit_game() -> void:
	get_tree().quit()
