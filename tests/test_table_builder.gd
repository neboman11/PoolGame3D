class_name TableBuilderTests
extends RefCounted

const Profile := preload("res://scripts/table_profile.gd")

## A one-frame table smoke check complements pure solver tests. It protects
## the render-only CSG layer from restoring collider-looking rails or losing
## a pocket mouth in a playable scene.

var _passed := 0
var _failed: Array[String] = []


func create_table() -> Variant:
	## TableBuilder references the TextureGen autoload, which is registered only
	## after SceneTree startup. Loading it here also matches the game's order.
	var table_builder_script: Variant = load("res://scripts/table_builder.gd")
	if not table_builder_script is Script:
		return null
	var table: Variant = table_builder_script.new()
	return table if table is Node3D else null


func run(table: Node3D) -> int:
	_run_case("table visual rail smoke", func() -> String:
		return _test_visual_rails_and_physics_descriptors(table)
	)
	_run_case("active pocket mouth alignment", func() -> String:
		return _test_active_pocket_mouth_alignment(table)
	)
	_run_case("rendered cushion-nose collision alignment", func() -> String:
		return _test_rendered_cushion_nose_collision_alignment(table)
	)
	if _failed.is_empty():
		print("PASS: %d table builder checks" % _passed)
		return 0
	printerr("FAIL: %d table builder checks" % _failed.size())
	for failure in _failed:
		printerr("  - %s" % failure)
	return 1


func _run_case(name: String, test: Callable) -> void:
	var result: Variant = test.call()
	if not result is String:
		_failed.append("%s: test did not return a String failure result" % name)
		return
	var error: String = result
	if error.is_empty():
		_passed += 1
		print("PASS: %s" % name)
	else:
		_failed.append("%s: %s" % [name, error])


func _test_visual_rails_and_physics_descriptors(table: Node3D) -> String:
	var felt := table.get_node_or_null("Table_Felt_Surface")
	var rubber_rail := table.get_node_or_null("Table_Rubber_Rail")
	var rubber_cap := table.get_node_or_null("Table_Rubber_Rail_Cap")
	var wood_rail := table.get_node_or_null("Table_Wood_Rail")
	for visual in [felt, rubber_rail, rubber_cap, wood_rail]:
		if not visual is CSGShape3D:
			return "missing CSG visual rail node"
		if visual.use_collision:
			return "%s must remain render-only" % visual.name

	if _subtraction_cylinder_count(felt) != 6:
		return "felt has %d pocket cutouts; expected 6" % _subtraction_cylinder_count(felt)
	if _subtraction_cylinder_count(rubber_rail) != 6:
		return "rubber rail has %d pocket cutouts; expected 6" % _subtraction_cylinder_count(rubber_rail)
	if _subtraction_cylinder_count(rubber_cap) != 6:
		return "rubber cap has %d pocket cutouts; expected 6" % _subtraction_cylinder_count(rubber_cap)
	if _subtraction_cylinder_count(wood_rail) != 6:
		return "wood rail has %d pocket cutouts; expected 6" % _subtraction_cylinder_count(wood_rail)

	if not is_equal_approx(rubber_rail.size.y, Profile.CUSHION_HEIGHT) or not is_equal_approx(rubber_rail.position.y, Profile.CUSHION_HEIGHT * 0.5):
		return "rubber nose must match the profile cushion height"
	var rubber_top: float = rubber_cap.position.y + rubber_cap.size.y * 0.5
	var wood_top: float = wood_rail.position.y + wood_rail.size.y * 0.5
	if not is_equal_approx(rubber_top, wood_top):
		return "rubber top %.3f must align with wood top %.3f" % [rubber_top, wood_top]
	# The rail leans in toward the cloth: the cap/wood above step back from
	# the flush nose footprint, instead of continuing straight up.
	if rubber_cap.size.x <= rubber_rail.size.x + 0.001 or rubber_cap.size.z <= rubber_rail.size.z + 0.001:
		return "rubber cap must be set back from the flush nose to slant the rail"
	var pocket_error: String = _validate_visual_pockets(table, felt)
	if not pocket_error.is_empty():
		return pocket_error
	var descriptors: Array[Dictionary] = table.get_static_collision_descriptors()
	var kinds: Dictionary = {}
	for descriptor in descriptors:
		var kind := String(descriptor.get("kind", ""))
		kinds[kind] = int(kinds.get(kind, 0)) + 1
	for required_kind in ["bed", "cushion", "rail", "jaw"]:
		if int(kinds.get(required_kind, 0)) == 0:
			return "missing %s collision descriptor" % required_kind
	return ""


func _validate_visual_pockets(table: Node3D, felt: CSGShape3D) -> String:
	for descriptor in Profile.get_pocket_capture_descriptors():
		var pocket_id := String(descriptor["id"])
		var center_value: Variant = descriptor.get("center", null)
		var position_value: Variant = descriptor.get("position", null)
		var cutout_node := felt.get_node_or_null("PocketCutout_%s" % pocket_id)
		if not cutout_node is CSGCylinder3D:
			return "missing visual cutout for %s" % pocket_id
		var cutout: CSGCylinder3D = cutout_node
		var mouth_width := float(descriptor["mouth_width"])
		var visual_radius := float(descriptor.get("visual_radius", mouth_width * 0.5))
		var capture_radius := float(descriptor["capture_radius"])
		var maximum_radius := minf(visual_radius * 1.15, capture_radius + Profile.BALL_RADIUS * 0.75)
		if String(descriptor["pocket_type"]) == "corner":
			# A corner cut is offset along the mouth's 45-degree bisector to
			# clear the combined cushion+rail depth at the joint, so its
			# cylinder radius runs bigger than a straight pocket's for the
			# same visible mouth width; the visible-mouth check above already
			# keeps the on-table opening honest.
			maximum_radius = (Profile.CUSHION_THICKNESS + Profile.RAIL_WIDTH) * 0.56
		var profile_position: Vector3 = descriptor["position"]
		var inward: Vector3 = descriptor["inward_normal"]
		inward.y = 0.0
		inward = inward.normalized()
		var lip_offset := (profile_position - cutout.position).dot(inward)
		# Corner pockets must punch through the much thicker combined
		# cushion + wood-rail mass at the 90-degree rail joint, so their
		# cutout reaches deeper than a straight side-rail cross-section.
		var lip_ceiling := Profile.CUSHION_THICKNESS
		if String(descriptor["pocket_type"]) == "corner":
			lip_ceiling = Profile.CUSHION_THICKNESS + Profile.RAIL_WIDTH
		if lip_offset <= 0.0 or lip_offset > lip_ceiling + 0.001:
			return "%s cutout must sit just inside its profile mouth" % pocket_id
		var visible_mouth_width: float
		if String(descriptor["pocket_type"]) == "corner":
			var rail_offset := lip_offset * 0.70710678
			visible_mouth_width = rail_offset + sqrt(maxf(cutout.radius * cutout.radius - rail_offset * rail_offset, 0.0))
		else:
			visible_mouth_width = 2.0 * sqrt(maxf(cutout.radius * cutout.radius - lip_offset * lip_offset, 0.0))
		var minimum_mouth_scale := 0.75 if String(descriptor["pocket_type"]) == "corner" else 0.90
		if visible_mouth_width + 0.001 < mouth_width * minimum_mouth_scale:
			return "%s visual mouth %.3f is too small for profile mouth %.3f" % [pocket_id, visible_mouth_width, mouth_width]
		if visible_mouth_width > mouth_width * 1.02:
			return "%s visual mouth %.3f exceeds profile mouth %.3f" % [pocket_id, visible_mouth_width, mouth_width]
		if cutout.radius > maximum_radius + 0.001:
			return "%s visual cutout %.3f exceeds its mouth/capture cap %.3f" % [pocket_id, cutout.radius, maximum_radius]
		var well_node := table.get_node_or_null("PocketWell_%s" % pocket_id)
		if well_node == null:
			continue
		if not well_node is MeshInstance3D or not well_node.mesh is CylinderMesh:
			return "%s requires a smooth cylindrical pocket well" % pocket_id
		var well: MeshInstance3D = well_node
		var well_mesh: CylinderMesh = well.mesh
		if well_mesh.top_radius < cutout.radius * 0.98 or well_mesh.top_radius > maximum_radius + 0.001 or well_mesh.radial_segments < 32 or well_mesh.rings < 4:
			return "%s pocket well must closely follow its smooth cutout" % pocket_id
		var well_top: float = well.position.y + well_mesh.height * 0.5
		if well_top > -0.006:
			return "%s pocket well must remain recessed below the cloth" % pocket_id
	return ""


func _test_active_pocket_mouth_alignment(table: Node3D) -> String:
	for descriptor in Profile.get_pocket_capture_descriptors():
		var pocket_id := String(descriptor["id"])
		var center_value: Variant = descriptor.get("center", null)
		var position_value: Variant = descriptor.get("position", null)
		var drop_center_value: Variant = descriptor.get("drop_center", null)
		if not drop_center_value is Vector3:
			return "%s needs a visible pocket drop center" % pocket_id
		if not center_value is Vector3 or not position_value is Vector3:
			return "%s needs a shared visible mouth center" % pocket_id
		var center: Vector3 = center_value
		var position: Vector3 = position_value
		var drop_center: Vector3 = drop_center_value
		if center.distance_to(position) > 0.00001 or center.distance_to(drop_center) > 0.00001:
			return "%s capture, visual position, and drop center must be identical" % pocket_id
		# The licensed table model owns its pocket castings.  A procedural void
		# here would render as a second black disk over the actual opening.
		if table.get_node_or_null("TraditionalPocketVoid_%s" % pocket_id) != null:
			return "duplicate traditional pocket void %s must not be built" % pocket_id
		for legacy_name in ["PocketWell_", "PocketLeatherRim_", "PocketMouth_"]:
			if table.get_node_or_null("%s%s" % [legacy_name, pocket_id]) != null:
				return "legacy pocket marker %s%s must not be built" % [legacy_name, pocket_id]
	return ""

## The imported traditional table is retained at its native proportions.  This
## protects the measured visual rubber-nose planes from silently returning to
## the narrower nominal playing rectangle used by racking and pocket centers.
func _test_rendered_cushion_nose_collision_alignment(table: Node3D) -> String:
	var expected_end_nose := Profile.PLAYING_SURFACE_LENGTH * 0.5 + Profile.RENDERED_CUSHION_NOSE_OUTSET_X
	var expected_side_nose := Profile.PLAYING_SURFACE_WIDTH * 0.5 + Profile.RENDERED_CUSHION_NOSE_OUTSET_Z
	var end_count := 0
	var side_count := 0
	var jaw_count := 0
	for descriptor in table.get_static_collision_descriptors():
		var kind := String(descriptor.get("kind", ""))
		if kind == "rail":
			if bool(descriptor.get("solver_enabled", true)):
				return "%s wood rail must not create a second solver collision plane" % descriptor.get("id", "rail")
			continue
		if kind == "jaw":
			jaw_count += 1
			if not bool(descriptor.get("solver_enabled", true)):
				return "%s jaw must guard the real mouth opening in the solver" % descriptor.get("id", "jaw")
			var jaw_id := String(descriptor.get("id", ""))
			var jaw_center: Vector3 = descriptor.get("center", Vector3.ZERO)
			var jaw_tolerance: float = Profile.CUSHION_THICKNESS + Profile.JAW_LENGTH
			if jaw_id.begins_with("corner_long") or jaw_id.begins_with("side_"):
				if absf(absf(jaw_center.z) - expected_side_nose) > jaw_tolerance:
					return "%s jaw is not anchored to the rendered side nose" % jaw_id
			elif jaw_id.begins_with("corner_short"):
				if absf(absf(jaw_center.x) - expected_end_nose) > jaw_tolerance:
					return "%s jaw is not anchored to the rendered end nose" % jaw_id
			continue
		if kind != "cushion":
			continue
		var normal: Vector3 = descriptor.get("normal", Vector3.ZERO)
		var point: Vector3 = descriptor.get("point", Vector3.ZERO)
		if absf(normal.x) > 0.5:
			end_count += 1
			if not is_equal_approx(absf(point.x), expected_end_nose):
				return "%s collision plane %.4f does not reach rendered end-rail nose %.4f" % [descriptor.get("id", "end cushion"), absf(point.x), expected_end_nose]
		elif absf(normal.z) > 0.5:
			side_count += 1
			if not is_equal_approx(absf(point.z), expected_side_nose):
				return "%s collision plane %.4f does not reach rendered side-rail nose %.4f" % [descriptor.get("id", "side cushion"), absf(point.z), expected_side_nose]
	if end_count != 2:
		return "expected 2 end-rail cushion planes, found %d" % end_count
	if side_count != 4:
		return "expected 4 side-rail cushion planes, found %d" % side_count
	if jaw_count == 0:
		return "expected pocket-jaw descriptors for visual/debug geometry"
	return ""


func _subtraction_cylinder_count(parent: Node) -> int:
	var count := 0
	for child in parent.get_children():
		if child is CSGCylinder3D and child.operation == CSGShape3D.OPERATION_SUBTRACTION:
			count += 1
	return count
