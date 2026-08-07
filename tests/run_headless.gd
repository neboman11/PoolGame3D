extends SceneTree

## Minimal dependency-free entry point for the deterministic billiards checks.
##
## Run from the repository root:
##   godot --headless --path . --script tests/run_headless.gd

const BilliardsPhysicsTests := preload("res://tests/test_billiards_physics.gd")
const EightBallRulesTests := preload("res://tests/test_eight_ball_rules.gd")
const NineBallRulesTests := preload("res://tests/test_nine_ball_rules.gd")
const TableBuilderTests := preload("res://tests/test_table_builder.gd")
const CueInputStateTests := preload("res://tests/test_cue_input_state.gd")
const AIOpponentTests := preload("res://tests/test_ai_opponent.gd")
const TextureGeneratorTests := preload("res://tests/test_texture_generator.gd")


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var physics_suite := BilliardsPhysicsTests.new()
	var rules_suite := EightBallRulesTests.new()
	var nine_ball_rules_suite := NineBallRulesTests.new()
	var table_suite := TableBuilderTests.new()
	var cue_input_suite := CueInputStateTests.new()
	var ai_suite := AIOpponentTests.new()
	var texture_suite := TextureGeneratorTests.new()
	var physics_exit_code: int = physics_suite.run()
	var rules_exit_code: int = rules_suite.run()
	var nine_ball_rules_exit_code: int = nine_ball_rules_suite.run()
	var cue_input_exit_code: int = cue_input_suite.run()
	var ai_exit_code: int = ai_suite.run()
	var texture_exit_code: int = texture_suite.run()
	var table_or_error: Variant = table_suite.create_table()
	var table_exit_code := 1
	if table_or_error is Node3D:
		var table: Node3D = table_or_error
		get_root().add_child(table)
		await process_frame
		table_exit_code = table_suite.run(table)
		table.queue_free()
		await process_frame
	else:
		printerr("FAIL: table builder smoke could not instantiate TableBuilder")
	var exit_code: int = max(physics_exit_code, max(rules_exit_code, max(nine_ball_rules_exit_code, max(cue_input_exit_code, max(ai_exit_code, max(texture_exit_code, table_exit_code))))))
	quit(exit_code)
