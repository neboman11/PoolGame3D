extends Node

## Visual-structure smoke check: a real table has six discrete hardwood rail
## sections rather than one CSG slab with circular holes punched through it.
const TableBuilderScript := preload("res://scripts/table_builder.gd")
const TableBuilderTests := preload("res://tests/test_table_builder.gd")

func _ready() -> void:
	call_deferred("_run")

func _run() -> void:
	var table: Node3D = TableBuilderScript.new()
	add_child(table)
	await get_tree().process_frame
	var traditional_model := table.get_node_or_null("TraditionalTableVisual")
	if traditional_model == null:
		printerr("expected the licensed traditional table visual")
		get_tree().quit(1)
		return
	if _visible_table_mesh_count(traditional_model) == 0:
		printerr("expected a visible pool-table mesh in the imported model")
		get_tree().quit(1)
		return
	if _visible_model_prop_count(traditional_model) != 0:
		printerr("imported cue, balls, or ceiling light must stay hidden")
		get_tree().quit(1)
		return

	var wood_sections := 0
	var cushion_or_jaw_sections := 0
	for child in table.get_children():
		if child.name.begins_with("Rail_Wood_"):
			wood_sections += 1
		elif child.name.begins_with("Rail_Cushion_") or child.name.begins_with("Rail_Jaw_"):
			cushion_or_jaw_sections += 1

	if wood_sections != 6:
		printerr("expected six separated hardwood rail sections, found %d" % wood_sections)
		get_tree().quit(1)
		return
	if cushion_or_jaw_sections == 0:
		printerr("expected visible cloth-rubber cushions and pocket jaw facings")
		get_tree().quit(1)
		return
	var legacy_tests := TableBuilderTests.new()
	var legacy_exit_code: int = legacy_tests.run(table)
	if legacy_exit_code != 0:
		get_tree().quit(legacy_exit_code)
		return

	table.queue_free()
	get_tree().quit(0)


func _visible_table_mesh_count(node: Node) -> int:
	var count := 0
	if node is MeshInstance3D and String(node.name).contains("pool_table_mat") and node.visible:
		count += 1
	for child in node.get_children():
		count += _visible_table_mesh_count(child)
	return count


func _visible_model_prop_count(node: Node) -> int:
	var count := 0
	if node is MeshInstance3D:
		var part_name := String(node.name).to_lower()
		if (
			part_name.begins_with("billiard_ball")
			or part_name.begins_with("pool_cue")
			or part_name.begins_with("ceiling_light")
		) and node.visible:
			count += 1
	for child in node.get_children():
		count += _visible_model_prop_count(child)
	return count
