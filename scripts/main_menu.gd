extends Control

const AI_OPPONENT := preload("res://scripts/ai_opponent.gd")

@onready var play_button: Button = $CenterContainer/VBoxContainer/PlayButton
@onready var settings_button: Button = $CenterContainer/VBoxContainer/SettingsButton
@onready var quit_button: Button = $CenterContainer/VBoxContainer/QuitButton
@onready var status_label: Label = $CenterContainer/VBoxContainer/StatusLabel
@onready var game_type_option: OptionButton = $CenterContainer/VBoxContainer/GameTypeOption
@onready var opponent_option: OptionButton = $CenterContainer/VBoxContainer/OpponentOption

func _ready() -> void:
	play_button.disabled = true
	status_label.text = "Loading..."
	play_button.pressed.connect(_on_play_pressed)
	settings_button.pressed.connect(_on_settings_pressed)
	quit_button.pressed.connect(_on_quit_pressed)
	quit_button.visible = OS.get_name() != "Android"

	game_type_option.clear()
	game_type_option.add_item("8-Ball")
	game_type_option.add_item("9-Ball")
	game_type_option.selected = 0

	opponent_option.clear()
	opponent_option.add_item("2 Players")
	for difficulty in [AI_OPPONENT.Difficulty.ROOKIE, AI_OPPONENT.Difficulty.AMATEUR, AI_OPPONENT.Difficulty.PRO, AI_OPPONENT.Difficulty.CHAMPION]:
		opponent_option.add_item("vs AI — %s" % AI_OPPONENT.label_for(difficulty))
	opponent_option.selected = 0

	await TextureGen.preload_all_ball_textures()

	status_label.text = ""
	play_button.disabled = false

func _on_play_pressed() -> void:
	GameManager.game_type = GameManager.GameType.NINE_BALL if game_type_option.selected == 1 else GameManager.GameType.EIGHT_BALL
	var selection := opponent_option.selected
	GameManager.vs_ai = selection > 0
	if GameManager.vs_ai:
		GameManager.ai_difficulty = selection - 1
	GameManager.start_game()

func _on_settings_pressed() -> void:
	GameManager.goto_scene("res://scenes/SettingsMenu.tscn")

func _on_quit_pressed() -> void:
	GameManager.quit_game()
