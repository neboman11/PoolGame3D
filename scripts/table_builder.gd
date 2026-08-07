extends Node3D
## Builds the table directly from TableProfile.  TableProfile is the source of
## truth for scene dimensions, collision bodies, pocket geometry, and calibrated
## material values; this script only turns that data into Godot nodes.

const Profile := preload("res://scripts/table_profile.gd")
const PocketScript := preload("res://scripts/pocket.gd")
const TraditionalTableModel := preload("res://assets/models/traditional_pool_table/scene_poolgame.gltf")

## Backwards-compatible dimensions consumed by Game.gd and existing scene code.
const LENGTH: float = Profile.PLAYING_SURFACE_LENGTH
const WIDTH: float = Profile.PLAYING_SURFACE_WIDTH
const TRADITIONAL_TABLE_HORIZONTAL_SCALE := 5.2
const TRADITIONAL_TABLE_VERTICAL_SCALE := 2.9
const TRADITIONAL_TABLE_CLOTH_HEIGHT := 0.757

var pocket_positions: Array[Vector3] = []
var _physics_descriptors: Array[Dictionary] = []
var _pocket_highlights: Dictionary = {} # pocket id -> MeshInstance3D ring


func _ready() -> void:
	_physics_descriptors = Profile.get_physics_descriptors()
	_build_collision_geometry()
	_build_pockets()
	_build_legs()
	_build_traditional_table_visual()


## Public physics API.  Each call returns fresh descriptor dictionaries, so a
## consumer cannot accidentally mutate the geometry used by a different caller.
## Entries with kind `bed`, `cushion`, `rail`, and `jaw` are oriented boxes.
## Entries with kind `pocket` include mouth, throat, shelf, and trigger data.
func get_physics_descriptors() -> Array[Dictionary]:
	return _copy_descriptors(_physics_descriptors if not _physics_descriptors.is_empty() else Profile.get_physics_descriptors())


func get_static_collision_descriptors() -> Array[Dictionary]:
	return _copy_descriptors(Profile.get_static_collision_descriptors())


func get_pocket_capture_descriptors() -> Array[Dictionary]:
	return _copy_descriptors(Profile.get_pocket_capture_descriptors())


func get_ball_radius() -> float:
	return Profile.get_ball_radius()


func get_head_spot() -> Vector3:
	return Profile.get_head_spot()


func get_rack_apex() -> Vector3:
	return Profile.get_rack_apex()


## Ball-in-hand helper.  The profile checks the in-bounds cloth rectangle and
## rejects all six physical pocket-mouth regions.
func is_position_on_cloth(position: Vector3, radius: float = Profile.BALL_RADIUS) -> bool:
	return Profile.is_position_on_cloth(position, radius)


func get_table_calibration() -> Dictionary:
	return Profile.get_calibration().duplicate(true)


func _copy_descriptors(source: Array[Dictionary]) -> Array[Dictionary]:
	var copy: Array[Dictionary] = []
	for descriptor in source:
		copy.append(descriptor.duplicate(true))
	return copy


func _build_collision_geometry() -> void:
	var felt := _felt_material()
	var rubber := _rubber_material()
	var wood := _wood_material()
	for descriptor in Profile.get_static_collision_descriptors():
		var kind := String(descriptor["kind"])
		var material: StandardMaterial3D
		match kind:
			"bed":
				material = felt
				# The collider remains a solid slate bed, but its visual surface is
				# built below with pocket cutouts rather than a full box across every
				# mouth.
				_make_box_body_from_descriptor(descriptor, material, false)
			"cushion", "jaw":
				material = rubber
				# These boxes are authoritative collision geometry, but their hard
				# edges are not the visual cushion.  The table-top builder below
				# supplies a continuous rubber rail with rounded pocket mouths.
				_make_box_body_from_descriptor(descriptor, material, false)
			"rail":
				# Public rail descriptors remain available to BilliardsPhysics.  Their
				# old full-length render boxes crossed the six pocket mouths, so visual
				# rails are assembled in pocket-aware segments below.
				continue
			_:
				continue
	_build_felt_surface(felt)
	_hide_legacy_felt_surface()
	_build_visual_rails(wood, rubber)
	_hide_legacy_rail_shell()
	_build_reference_felt(felt)
	_build_reference_rails(wood, rubber)


func _make_box_body_from_descriptor(descriptor: Dictionary, material: StandardMaterial3D, add_visual: bool = true) -> void:
	var size: Vector3 = descriptor["size"]
	var center: Vector3 = descriptor["center"]
	_make_box_body(
		size,
		center,
		material,
		float(descriptor["friction"]),
		float(descriptor["restitution"]),
		String(descriptor["id"]),
		bool(descriptor["rough"]),
		bool(descriptor["absorbent"]),
		float(descriptor["rotation_y"]),
		add_visual
	)


func _make_box_body(
	size: Vector3,
	position: Vector3,
	material: StandardMaterial3D,
	friction: float,
	restitution: float,
	name_hint: String,
	rough: bool,
	absorbent: bool,
	rotation_y: float,
	add_visual: bool = true
) -> void:
	var body := StaticBody3D.new()
	body.name = "Table_%s" % name_hint
	body.position = position
	body.rotation = Vector3(0.0, rotation_y, 0.0)
	var physics_material := PhysicsMaterial.new()
	physics_material.friction = friction
	physics_material.bounce = restitution
	physics_material.rough = rough
	physics_material.absorbent = absorbent
	body.physics_material_override = physics_material
	add_child(body)

	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	body.add_child(shape)

	if not add_visual:
		return

	var mesh_instance := MeshInstance3D.new()
	var box_mesh := BoxMesh.new()
	box_mesh.size = size
	mesh_instance.mesh = box_mesh
	mesh_instance.set_surface_override_material(0, material)
	body.add_child(mesh_instance)


## The physical slate is still one simple collision box.  Its visible cloth is
## a thin CSG surface so each pocket is a real rounded opening rather than a
## green rectangle placed over a dark pocket mesh.
func _build_felt_surface(material: StandardMaterial3D) -> void:
	var felt := CSGBox3D.new()
	felt.name = "Table_Felt_Surface"
	felt.size = Vector3(LENGTH, 0.024, WIDTH)
	felt.position = Vector3(0.0, -0.012, 0.0)
	felt.material = material
	felt.use_collision = false
	for descriptor in Profile.get_pocket_capture_descriptors():
		felt.add_child(_make_pocket_cutter(descriptor, 0.080, material))
	add_child(felt)


## The collision descriptors deliberately retain their simple boxes for the
## solver.  This render-only layer turns them into a conventional table top:
## rubber is flush with the cloth at the base and steps back under the rail
## cap, the higher wood cap is a rounded rectangle, and each cutout is shared
## by every layer.
func _build_visual_rails(wood: StandardMaterial3D, rubber: StandardMaterial3D) -> void:
	# The cushion nose stays a single flush slab matching the collision
	# profile's footprint exactly - splitting it into stacked pieces made the
	# pocket cutouts (each carved independently per piece, off the same
	# absolute positions but into differently sized boxes) drift out of
	# alignment with each other, showing up as gaps and z-fighting seams at
	# oblique angles. The "slant in towards the bottom" lean instead comes
	# from the rail cap and wood above stepping back from this flush nose,
	# a single clean overhang rather than a second seam inside the cushion.
	var nose_taper := Profile.CUSHION_THICKNESS * 0.42
	var flush_half_length := LENGTH * 0.5 + Profile.CUSHION_THICKNESS
	var flush_half_width := WIDTH * 0.5 + Profile.CUSHION_THICKNESS

	var nose := CSGBox3D.new()
	nose.name = "Table_Rubber_Rail"
	nose.size = Vector3(flush_half_length * 2.0, Profile.CUSHION_HEIGHT, flush_half_width * 2.0)
	nose.position = Vector3(0.0, Profile.CUSHION_HEIGHT * 0.5, 0.0)
	nose.material = rubber
	nose.use_collision = false
	var nose_opening := CSGBox3D.new()
	nose_opening.operation = CSGShape3D.OPERATION_SUBTRACTION
	nose_opening.size = Vector3(LENGTH, Profile.CUSHION_HEIGHT + 0.040, WIDTH)
	nose.add_child(nose_opening)
	for descriptor in Profile.get_pocket_capture_descriptors():
		nose.add_child(_make_pocket_cutter(descriptor, Profile.CUSHION_HEIGHT + 0.040, rubber))
	add_child(nose)

	# The rest of the rail (cap and wood) steps back from the flush nose,
	# forming the overhang lean above the cushion.
	var rubber_half_length := flush_half_length + nose_taper
	var rubber_half_width := flush_half_width + nose_taper

	# A separate cosmetic cap carries the rubber surface to the wood-rail top.
	# Splitting it from the nose avoids suggesting a taller physical cushion.
	var rubber_cap := CSGBox3D.new()
	rubber_cap.name = "Table_Rubber_Rail_Cap"
	rubber_cap.size = Vector3(
		rubber_half_length * 2.0,
		Profile.RAIL_HEIGHT,
		rubber_half_width * 2.0
	)
	rubber_cap.position = Vector3(0.0, Profile.CUSHION_HEIGHT + Profile.RAIL_HEIGHT * 0.5, 0.0)
	rubber_cap.material = rubber
	rubber_cap.use_collision = false
	var cap_cloth_opening := CSGBox3D.new()
	cap_cloth_opening.operation = CSGShape3D.OPERATION_SUBTRACTION
	cap_cloth_opening.size = Vector3(LENGTH + nose_taper * 2.0, Profile.RAIL_HEIGHT + 0.040, WIDTH + nose_taper * 2.0)
	rubber_cap.add_child(cap_cloth_opening)
	for descriptor in Profile.get_pocket_capture_descriptors():
		rubber_cap.add_child(_make_pocket_cutter(descriptor, Profile.RAIL_HEIGHT + 0.040, rubber, _cap_radius_padding(descriptor, nose_taper)))
	add_child(rubber_cap)

	var wood_half_length := rubber_half_length + Profile.RAIL_WIDTH
	var wood_half_width := rubber_half_width + Profile.RAIL_WIDTH
	var corner_radius := minf(Profile.RAIL_WIDTH * 0.72, 0.440)
	var wood_rail := _make_rounded_rail_base(
		"Table_Wood_Rail",
		Vector3(wood_half_length * 2.0, Profile.RAIL_HEIGHT, wood_half_width * 2.0),
		corner_radius,
		wood
	)
	wood_rail.position = Vector3(
		0.0,
		Profile.CUSHION_HEIGHT + Profile.RAIL_HEIGHT * 0.5,
		0.0
	)
	var rubber_opening := CSGBox3D.new()
	rubber_opening.operation = CSGShape3D.OPERATION_SUBTRACTION
	rubber_opening.size = Vector3(
		rubber_half_length * 2.0,
		Profile.RAIL_HEIGHT + 0.040,
		rubber_half_width * 2.0
	)
	wood_rail.add_child(rubber_opening)
	for descriptor in Profile.get_pocket_capture_descriptors():
		wood_rail.add_child(_make_pocket_cutter(descriptor, Profile.RAIL_HEIGHT + 0.040, wood, _wood_radius_padding(descriptor, nose_taper)))
	add_child(wood_rail)


## The legacy shell remains instantiated only for backwards-compatible scene
## checks.  It is intentionally hidden: a real table uses discrete rail
## sections around six openings, not a single slab with six circular bores.
func _hide_legacy_felt_surface() -> void:
	var felt_surface := get_node_or_null("Table_Felt_Surface")
	if felt_surface is VisualInstance3D:
		felt_surface.visible = false


func _hide_legacy_rail_shell() -> void:
	for node_name in ["Table_Rubber_Rail", "Table_Rubber_Rail_Cap", "Table_Wood_Rail"]:
		var legacy_visual := get_node_or_null(NodePath(node_name))
		if legacy_visual is VisualInstance3D:
			legacy_visual.visible = false


func _build_realistic_rails(wood: StandardMaterial3D, rubber: StandardMaterial3D) -> void:
	var half_length := LENGTH * 0.5
	var half_width := WIDTH * 0.5
	var visual_wood_width := 0.440 # 3.5 in; with the cushion, a 5.5 in rail.
	var visual_wood_height := 0.260
	var rail_top := Profile.CUSHION_HEIGHT + 0.022
	var rail_center_y := rail_top - visual_wood_height * 0.5
	var long_segment_length := (LENGTH - 2.0 * Profile.CORNER_MOUTH - Profile.SIDE_MOUTH) * 0.5
	var long_segment_offset := Profile.SIDE_MOUTH * 0.5 + long_segment_length * 0.5
	var short_segment_length := WIDTH - 2.0 * Profile.CORNER_MOUTH

	for sign_z in [1.0, -1.0]:
		for sign_x in [1.0, -1.0]:
			var long_position := Vector3(
				sign_x * long_segment_offset,
				rail_center_y,
				sign_z * (half_width + Profile.CUSHION_THICKNESS + visual_wood_width * 0.5)
			)
			_add_render_box(
				"Rail_Wood_Long_%s_%s" % ["Right" if sign_x > 0.0 else "Left", "Top" if sign_z > 0.0 else "Bottom"],
				Vector3(long_segment_length, visual_wood_height, visual_wood_width),
				long_position,
				wood
			)
			_add_rail_sight("Rail_Sight_Long_%s_%s" % [sign_x, sign_z], long_position, rail_top)

	for sign_x in [1.0, -1.0]:
		var short_position := Vector3(
			sign_x * (half_length + Profile.CUSHION_THICKNESS + visual_wood_width * 0.5),
			rail_center_y,
			0.0
		)
		_add_render_box(
			"Rail_Wood_Short_%s" % ["Right" if sign_x > 0.0 else "Left"],
			Vector3(visual_wood_width, visual_wood_height, short_segment_length),
			short_position,
			wood
		)
		_add_rail_sight("Rail_Sight_Short_%s" % sign_x, short_position, rail_top)

	for descriptor in Profile.get_static_collision_descriptors():
		var kind := String(descriptor["kind"])
		if kind != "cushion" and kind != "jaw":
			continue
		var prefix := "Rail_Cushion_" if kind == "cushion" else "Rail_Jaw_"
		_add_render_box(
			prefix + String(descriptor["id"]),
			descriptor["size"],
			descriptor["center"],
			rubber,
			float(descriptor.get("rotation_y", 0.0))
		)


func _add_render_box(
	name_hint: String,
	size: Vector3,
	position: Vector3,
	material: StandardMaterial3D,
	rotation_y: float = 0.0
) -> void:
	var visual := MeshInstance3D.new()
	visual.name = name_hint
	var box := BoxMesh.new()
	box.size = size
	visual.mesh = box
	visual.position = position
	visual.rotation.y = rotation_y
	visual.set_surface_override_material(0, material)
	add_child(visual)


func _add_rail_sight(name_hint: String, rail_position: Vector3, rail_top: float) -> void:
	var sight_material := StandardMaterial3D.new()
	sight_material.albedo_color = Color(0.78, 0.67, 0.47)
	sight_material.metallic = 0.15
	sight_material.roughness = 0.38
	var sight := MeshInstance3D.new()
	sight.name = name_hint
	var mesh := BoxMesh.new()
	mesh.size = Vector3(0.075, 0.012, 0.075)
	sight.mesh = mesh
	sight.position = Vector3(rail_position.x, rail_top + 0.006, rail_position.z)
	sight.rotation.y = PI * 0.25
	sight.set_surface_override_material(0, sight_material)
	add_child(sight)


## Visible table construction follows the traditional leather-pocket table in
## the supplied reference: broad polished-wood rails, slim sloping cushions,
## and recessed pockets rather than independent boards around circular holes.
func _build_reference_felt(material: StandardMaterial3D) -> void:
	var felt := CSGBox3D.new()
	felt.name = "Reference_Felt_Surface"
	felt.size = Vector3(LENGTH, 0.018, WIDTH)
	felt.position = Vector3(0.0, -0.009, 0.0)
	felt.material = material
	felt.use_collision = false
	for descriptor in Profile.get_pocket_capture_descriptors():
		var cutter := CSGCylinder3D.new()
		cutter.name = "ReferencePocketCutout_%s" % String(descriptor["id"])
		cutter.operation = CSGShape3D.OPERATION_SUBTRACTION
		cutter.radius = _reference_pocket_radius(descriptor)
		cutter.height = 0.070
		cutter.sides = 32
		cutter.smooth_faces = true
		var center := _reference_pocket_center(descriptor)
		cutter.position = Vector3(center.x, 0.0, center.z)
		felt.add_child(cutter)
	add_child(felt)
	_build_reference_pockets()


func _build_reference_rails(wood: StandardMaterial3D, rubber: StandardMaterial3D) -> void:
	var half_length := LENGTH * 0.5
	var half_width := WIDTH * 0.5
	var wood_width := 0.580
	var wood_body_height := 0.320
	var rail_top := 0.205
	var wood_center_y := rail_top - wood_body_height * 0.5
	var long_length := (LENGTH - 2.0 * Profile.CORNER_MOUTH - Profile.SIDE_MOUTH) * 0.5
	var long_offset := Profile.SIDE_MOUTH * 0.5 + long_length * 0.5
	var short_length := WIDTH - 2.0 * Profile.CORNER_MOUTH
	var cap_material := _polished_wood_material()
	var sight_material := _sight_material()
	for sign_z in [1.0, -1.0]:
		for sign_x in [1.0, -1.0]:
			var position := Vector3(sign_x * long_offset, wood_center_y, sign_z * (half_width + Profile.CUSHION_THICKNESS + wood_width * 0.5))
			var wood_origin := Vector3(position.x, 0.0, sign_z * (half_width + Profile.CUSHION_THICKNESS))
			_add_beveled_wood_rail("Rail_Wood_Long_%s_%s" % ["Right" if sign_x > 0.0 else "Left", "Top" if sign_z > 0.0 else "Bottom"], long_length, Vector3.RIGHT, wood_origin, Vector3(0.0, 0.0, sign_z), wood)
			_add_reference_sight("Sight_Long_%s_%s" % [sign_x, sign_z], wood_origin + Vector3(0.0, rail_top + 0.018, 0.0) + Vector3(0.0, 0.0, sign_z * wood_width * 0.42), sight_material)
			_add_sloped_cushion("Rail_Cushion_Long_%s_%s" % [sign_x, sign_z], Vector3(long_length + 0.090, 0.135, 0.235), Vector3(position.x, 0.078, sign_z * (half_width + 0.108)), Vector3(deg_to_rad(-sign_z * 28.0), 0.0, 0.0), rubber)

	for sign_x in [1.0, -1.0]:
		var position := Vector3(sign_x * (half_length + Profile.CUSHION_THICKNESS + wood_width * 0.5), wood_center_y, 0.0)
		var wood_origin := Vector3(sign_x * (half_length + Profile.CUSHION_THICKNESS), 0.0, 0.0)
		_add_beveled_wood_rail("Rail_Wood_Short_%s" % ["Right" if sign_x > 0.0 else "Left"], short_length, Vector3.FORWARD, wood_origin, Vector3(sign_x, 0.0, 0.0), wood)
		_add_reference_sight("Sight_Short_%s" % sign_x, wood_origin + Vector3(0.0, rail_top + 0.018, 0.0) + Vector3(sign_x * wood_width * 0.42, 0.0, 0.0), sight_material)
		_add_sloped_cushion("Rail_Cushion_Short_%s" % sign_x, Vector3(0.235, 0.135, short_length + 0.090), Vector3(sign_x * (half_length + 0.108), 0.078, 0.0), Vector3(0.0, 0.0, deg_to_rad(sign_x * 28.0)), rubber)

	for descriptor in Profile.get_static_collision_descriptors():
		if String(descriptor["kind"]) != "jaw":
			continue
		var size: Vector3 = descriptor["size"]
		_add_render_box("Rail_Jaw_%s" % String(descriptor["id"]), Vector3(size.x, size.y * 0.82, size.z), descriptor["center"], rubber, float(descriptor.get("rotation_y", 0.0)))


func _add_beveled_wood_rail(name_hint: String, length: float, tangent: Vector3, origin: Vector3, outward: Vector3, material: StandardMaterial3D) -> void:
	var profile: Array[Vector2] = [
		Vector2(0.000, -0.145),
		Vector2(0.000, 0.105),
		Vector2(0.085, 0.180),
		Vector2(0.480, 0.205),
		Vector2(0.580, 0.150),
		Vector2(0.580, -0.205),
	]
	var half_tangent := tangent.normalized() * length * 0.5
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	for index in range(profile.size()):
		var next := (index + 1) % profile.size()
		var a: Vector2 = profile[index]
		var b: Vector2 = profile[next]
		var left_a: Vector3 = origin - half_tangent + outward * a.x + Vector3.UP * a.y
		var right_a: Vector3 = origin + half_tangent + outward * a.x + Vector3.UP * a.y
		var left_b: Vector3 = origin - half_tangent + outward * b.x + Vector3.UP * b.y
		var right_b: Vector3 = origin + half_tangent + outward * b.x + Vector3.UP * b.y
		var v_a := float(index) / float(profile.size())
		var v_b := float(next) / float(profile.size())
		_add_textured_vertex(surface, left_a, Vector2(0.0, v_a))
		_add_textured_vertex(surface, right_a, Vector2(1.0, v_a))
		_add_textured_vertex(surface, right_b, Vector2(1.0, v_b))
		_add_textured_vertex(surface, left_a, Vector2(0.0, v_a))
		_add_textured_vertex(surface, right_b, Vector2(1.0, v_b))
		_add_textured_vertex(surface, left_b, Vector2(0.0, v_b))
	for index in range(1, profile.size() - 1):
		var start: Vector2 = profile[0]
		var a: Vector2 = profile[index]
		var b: Vector2 = profile[index + 1]
		_add_textured_vertex(surface, origin - half_tangent + outward * start.x + Vector3.UP * start.y, Vector2(0.0, 0.0))
		_add_textured_vertex(surface, origin - half_tangent + outward * b.x + Vector3.UP * b.y, Vector2(1.0, 1.0))
		_add_textured_vertex(surface, origin - half_tangent + outward * a.x + Vector3.UP * a.y, Vector2(1.0, 0.0))
		_add_textured_vertex(surface, origin + half_tangent + outward * start.x + Vector3.UP * start.y, Vector2(0.0, 0.0))
		_add_textured_vertex(surface, origin + half_tangent + outward * a.x + Vector3.UP * a.y, Vector2(1.0, 0.0))
		_add_textured_vertex(surface, origin + half_tangent + outward * b.x + Vector3.UP * b.y, Vector2(1.0, 1.0))
	surface.generate_normals()
	var rail := MeshInstance3D.new()
	rail.name = name_hint
	rail.mesh = surface.commit()
	rail.set_surface_override_material(0, material)
	add_child(rail)


func _add_textured_vertex(surface: SurfaceTool, vertex: Vector3, uv: Vector2) -> void:
	surface.set_uv(uv)
	surface.add_vertex(vertex)


func _add_sloped_cushion(name_hint: String, size: Vector3, position: Vector3, rotation: Vector3, material: StandardMaterial3D) -> void:
	var cushion := MeshInstance3D.new()
	cushion.name = name_hint
	var mesh := BoxMesh.new()
	mesh.size = size
	cushion.mesh = mesh
	cushion.position = position
	cushion.rotation = rotation
	cushion.set_surface_override_material(0, material)
	add_child(cushion)


func _add_reference_sight(name_hint: String, position: Vector3, material: StandardMaterial3D) -> void:
	var sight := MeshInstance3D.new()
	sight.name = name_hint
	var mesh := BoxMesh.new()
	mesh.size = Vector3(0.060, 0.010, 0.060)
	sight.mesh = mesh
	sight.position = position
	sight.rotation.y = PI * 0.25
	sight.set_surface_override_material(0, material)
	add_child(sight)


func _build_reference_pockets() -> void:
	var pocket_material := StandardMaterial3D.new()
	pocket_material.albedo_color = Color(0.008, 0.006, 0.004)
	pocket_material.roughness = 0.92
	pocket_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	pocket_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	var leather := _leather_material()
	for descriptor in Profile.get_pocket_capture_descriptors():
		var center := _reference_pocket_center(descriptor)
		var radius := _reference_pocket_radius(descriptor)
		var cavity := MeshInstance3D.new()
		cavity.name = "ReferencePocketCavity_%s" % String(descriptor["id"])
		var funnel := CylinderMesh.new()
		funnel.top_radius = radius * 0.98
		funnel.bottom_radius = maxf(float(descriptor["throat_width"]) * 0.34, Profile.BALL_RADIUS * 0.72)
		funnel.height = Profile.POCKET_DROP_DEPTH * 0.86
		funnel.radial_segments = 32
		funnel.rings = 4
		cavity.mesh = funnel
		cavity.position = center + Vector3(0.0, -funnel.height * 0.5, 0.0)
		cavity.set_surface_override_material(0, pocket_material)
		add_child(cavity)
		_add_reference_leather_ring(descriptor, center, radius, leather)


func _add_reference_leather_ring(descriptor: Dictionary, center: Vector3, cavity_radius: float, material: StandardMaterial3D) -> void:
	var outer_radius := cavity_radius + 0.070
	var inner_radius := cavity_radius * 0.92
	var inward: Vector3 = descriptor["inward_normal"]
	inward.y = 0.0
	inward = inward.normalized()
	var outward := -inward
	var center_angle := atan2(outward.z, outward.x)
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	for index in range(16):
		var angle_a := center_angle - PI * 0.5 + PI * float(index) / 16.0
		var angle_b := center_angle - PI * 0.5 + PI * float(index + 1) / 16.0
		var outer_a := Vector3(center.x + cos(angle_a) * outer_radius, 0.026, center.z + sin(angle_a) * outer_radius)
		var outer_b := Vector3(center.x + cos(angle_b) * outer_radius, 0.026, center.z + sin(angle_b) * outer_radius)
		var inner_a := Vector3(center.x + cos(angle_a) * inner_radius, 0.044, center.z + sin(angle_a) * inner_radius)
		var inner_b := Vector3(center.x + cos(angle_b) * inner_radius, 0.044, center.z + sin(angle_b) * inner_radius)
		surface.add_vertex(outer_a)
		surface.add_vertex(outer_b)
		surface.add_vertex(inner_b)
		surface.add_vertex(outer_a)
		surface.add_vertex(inner_b)
		surface.add_vertex(inner_a)
	surface.generate_normals()
	var ring := MeshInstance3D.new()
	ring.name = "ReferenceLeatherRing_%s" % String(descriptor["id"])
	ring.mesh = surface.commit()
	ring.set_surface_override_material(0, material)
	add_child(ring)


func _reference_pocket_center(descriptor: Dictionary) -> Vector3:
	var inward: Vector3 = descriptor["inward_normal"]
	inward.y = 0.0
	inward = inward.normalized()
	var pocket_position: Vector3 = descriptor["position"]
	return pocket_position + inward * (float(descriptor["mouth_width"]) * 0.30)


func _reference_pocket_radius(descriptor: Dictionary) -> float:
	var mouth_width := float(descriptor["mouth_width"])
	return mouth_width * (0.52 if String(descriptor["pocket_type"]) == "corner" else 0.50)


func _make_rounded_rail_base(
	name_hint: String,
	size: Vector3,
	corner_radius: float,
	material: StandardMaterial3D
) -> CSGBox3D:
	var base := CSGBox3D.new()
	base.name = name_hint
	base.size = Vector3(size.x - corner_radius * 2.0, size.y, size.z)
	base.material = material
	base.use_collision = false

	var crossbar := CSGBox3D.new()
	crossbar.operation = CSGShape3D.OPERATION_UNION
	crossbar.size = Vector3(size.x, size.y, size.z - corner_radius * 2.0)
	crossbar.material = material
	base.add_child(crossbar)

	for sign_x in [1.0, -1.0]:
		for sign_z in [1.0, -1.0]:
			var corner := CSGCylinder3D.new()
			corner.operation = CSGShape3D.OPERATION_UNION
			corner.radius = corner_radius
			corner.height = size.y
			corner.sides = 20
			corner.smooth_faces = true
			corner.position = Vector3(
				sign_x * (size.x * 0.5 - corner_radius),
				0.0,
				sign_z * (size.z * 0.5 - corner_radius)
			)
			corner.material = material
			base.add_child(corner)
	return base


func _make_pocket_cutter(descriptor: Dictionary, height: float, material: StandardMaterial3D = null, radius_padding: float = 0.0) -> CSGCylinder3D:
	var cutter := CSGCylinder3D.new()
	cutter.name = "PocketCutout_%s" % String(descriptor["id"])
	cutter.operation = CSGShape3D.OPERATION_SUBTRACTION
	# The cap and wood layers sit progressively further out than the flush
	# cushion nose (that's the rail's taper). A cutter sized only for the
	# nose leaves an uncut rim of cap/wood material bridging over the outer
	# edge of the opening on those wider layers.
	cutter.radius = _pocket_cutout_radius(descriptor) + radius_padding
	cutter.height = height
	# A subtraction cutter with no material of its own leaves Godot's flat
	# default gray on the newly exposed cut wall instead of the material it
	# cut into - showing up as a pale disc bridging the pocket mouth from a
	# low, near-table angle even though the hole itself is sized correctly.
	if material != null:
		cutter.material = material
	cutter.sides = 32
	cutter.smooth_faces = true
	var center := _pocket_cutout_center(descriptor)
	cutter.position = Vector3(center.x, 0.0, center.z)
	return cutter


func _pocket_cutout_center(descriptor: Dictionary) -> Vector3:
	var inward: Vector3 = descriptor["inward_normal"]
	inward.y = 0.0
	inward = inward.normalized()
	var mouth_radius := _pocket_cutout_radius(descriptor)
	var lip_offset := _pocket_lip_offset(descriptor)
	var pocket_position: Vector3 = descriptor["position"]
	return pocket_position - inward * lip_offset


## CSG cutters for the hidden legacy rail shell need to live outside the
## cloth.  A real pocket mouth is instead set only slightly into the playing
## surface, which keeps its leather rim attached to the cushion line.
func _pocket_visual_center(descriptor: Dictionary) -> Vector3:
	var inward: Vector3 = descriptor["inward_normal"]
	inward.y = 0.0
	inward = inward.normalized()
	var mouth_width := float(descriptor["mouth_width"])
	var inset := minf(mouth_width * 0.50, Profile.BALL_RADIUS * 2.50)
	var pocket_position: Vector3 = descriptor["position"]
	return pocket_position + inward * inset


func _pocket_lip_offset(descriptor: Dictionary) -> float:
	var mouth_width := float(descriptor["mouth_width"])
	if String(descriptor["pocket_type"]) == "corner":
		# A corner mouth must open through both the cushion nose and the much
		# thicker wood rail where two perpendicular rails join, so its visual
		# centre sits near the middle of that combined depth rather than just
		# past the cushion nose (which only clears the thin straight rails).
		return (Profile.CUSHION_THICKNESS + Profile.RAIL_WIDTH) * 0.5
	return minf(Profile.CUSHION_THICKNESS * 0.90, mouth_width * 0.325)


## Corner cutouts are already sized off the combined cushion+rail depth, so
## they already reach past the cap/wood footprint; padding them further only
## risks merging with the neighboring side pocket's cutout. Side pockets are
## sized off the much narrower straight-mouth width, so they need the extra
## reach to clear the wider cap/wood layers above the flush cushion nose.
func _cap_radius_padding(descriptor: Dictionary, nose_taper: float) -> float:
	if String(descriptor["pocket_type"]) == "corner":
		return 0.0
	return nose_taper


func _wood_radius_padding(descriptor: Dictionary, nose_taper: float) -> float:
	if String(descriptor["pocket_type"]) == "corner":
		return 0.0
	return nose_taper + Profile.RAIL_WIDTH


func _pocket_cutout_radius(descriptor: Dictionary) -> float:
	var mouth_width := float(descriptor["mouth_width"])
	var visual_radius := float(descriptor.get("visual_radius", mouth_width * 0.5))
	var capture_radius := float(descriptor["capture_radius"])
	if String(descriptor["pocket_type"]) == "corner":
		# The corner cut must clear the combined cushion+rail depth at the
		# 90-degree rail joint, which is far chunkier than a straight side
		# rail; sizing it off the cushion mouth width alone leaves only a
		# sliver notch through the wood.
		return maxf(visual_radius, (Profile.CUSHION_THICKNESS + Profile.RAIL_WIDTH) * 0.50)
	# The dark cut may flare very slightly beyond the profile's nominal mouth,
	# but never so far that its visible radius outruns the capture region by
	# more than a fraction of a ball.  This keeps pocketed visuals credible.
	var mouth_cap := visual_radius * 1.15
	var capture_cap := capture_radius + Profile.BALL_RADIUS * 0.75
	return minf(visual_radius * 1.14, minf(mouth_cap, capture_cap))


## Retained only as an inactive reference for the former panel construction.
func _build_legacy_felt_panels(material: StandardMaterial3D) -> void:
	var half_length := LENGTH * 0.5
	var half_width := WIDTH * 0.5
	var cut_depth := maxf(Profile.CORNER_MOUTH * 0.95, Profile.SIDE_MOUTH * 0.70)
	var corner_cut_width := Profile.CORNER_MOUTH
	var side_half_width := Profile.SIDE_MOUTH * 0.5

	# Preserve a little visible slate body below the separate cloth panels.
	_make_visual_box(
		"BedUnderlay",
		Vector3(LENGTH, Profile.BED_THICKNESS, WIDTH),
		Vector3(0.0, -Profile.BED_THICKNESS * 0.5 - 0.012, 0.0),
		material
	)

	_add_felt_panel(
		"Center",
		Vector3(0.0, 0.006, 0.0),
		Vector2(LENGTH, WIDTH - cut_depth * 2.0),
		material
	)

	var left_start := -half_length + corner_cut_width
	var left_end := -side_half_width
	var right_start := side_half_width
	var right_end := half_length - corner_cut_width
	for sign_z in [1.0, -1.0]:
		var strip_center_z: float = sign_z * (half_width - cut_depth * 0.5)
		_add_felt_panel(
			"%s_Left" % ["Top" if sign_z > 0.0 else "Bottom"],
			Vector3((left_start + left_end) * 0.5, 0.006, strip_center_z),
			Vector2(left_end - left_start, cut_depth),
			material
		)
		_add_felt_panel(
			"%s_Right" % ["Top" if sign_z > 0.0 else "Bottom"],
			Vector3((right_start + right_end) * 0.5, 0.006, strip_center_z),
			Vector2(right_end - right_start, cut_depth),
			material
		)


## Wood is intentionally visual-only: the profile keeps the pre-existing rail
## descriptors for external solver consumers, while these pieces stop at every
## corner and side mouth.
func _build_legacy_visual_rails(material: StandardMaterial3D) -> void:
	var half_length := LENGTH * 0.5
	var half_width := WIDTH * 0.5
	var long_segment_length := (LENGTH - 2.0 * Profile.CORNER_MOUTH - Profile.SIDE_MOUTH) * 0.5
	var long_segment_offset := Profile.SIDE_MOUTH * 0.5 + long_segment_length * 0.5
	var short_segment_length := WIDTH - 2.0 * Profile.CORNER_MOUTH
	var center_y := Profile.CUSHION_HEIGHT + Profile.RAIL_HEIGHT * 0.5

	for sign_z in [1.0, -1.0]:
		for sign_x in [1.0, -1.0]:
			_make_visual_box(
				"RailLong_%s_%s" % ["Right" if sign_x > 0.0 else "Left", "Top" if sign_z > 0.0 else "Bottom"],
				Vector3(long_segment_length, Profile.RAIL_HEIGHT, Profile.RAIL_WIDTH),
				Vector3(
					sign_x * long_segment_offset,
					center_y,
					sign_z * (half_width + Profile.CUSHION_THICKNESS + Profile.RAIL_WIDTH * 0.5)
				),
				material
			)

	for sign_x in [1.0, -1.0]:
		_make_visual_box(
			"RailShort_%s" % ["Right" if sign_x > 0.0 else "Left"],
			Vector3(Profile.RAIL_WIDTH, Profile.RAIL_HEIGHT, short_segment_length),
			Vector3(
				sign_x * (half_length + Profile.CUSHION_THICKNESS + Profile.RAIL_WIDTH * 0.5),
				center_y,
				0.0
			),
			material
		)


func _add_felt_panel(name_hint: String, position: Vector3, size: Vector2, material: StandardMaterial3D) -> void:
	if size.x <= 0.0 or size.y <= 0.0:
		return
	var panel := MeshInstance3D.new()
	panel.name = "Table_Felt_%s" % name_hint
	var plane := PlaneMesh.new()
	plane.size = size
	panel.mesh = plane
	panel.position = position
	panel.set_surface_override_material(0, material)
	add_child(panel)


func _make_visual_box(name_hint: String, size: Vector3, position: Vector3, material: StandardMaterial3D) -> void:
	var visual := MeshInstance3D.new()
	visual.name = "Table_Visual_%s" % name_hint
	var box := BoxMesh.new()
	box.size = size
	visual.mesh = box
	visual.position = position
	visual.set_surface_override_material(0, material)
	add_child(visual)


func _build_pockets() -> void:
	pocket_positions.clear()
	_pocket_highlights.clear()

	for descriptor in Profile.get_pocket_capture_descriptors():
		var pocket_position: Vector3 = descriptor["position"]
		pocket_positions.append(pocket_position)
		var area := Area3D.new()
		area.name = "Pocket_%s" % String(descriptor["id"])
		area.position = pocket_position + Vector3(0.0, float(descriptor["trigger_center_y"]), 0.0)
		area.collision_layer = 4
		area.collision_mask = 1
		area.set_script(PocketScript)
		add_child(area)

		var shape := CollisionShape3D.new()
		var cylinder := CylinderShape3D.new()
		cylinder.radius = float(descriptor["capture_radius"])
		cylinder.height = float(descriptor["trigger_height"])
		shape.shape = cylinder
		area.add_child(shape)

		_pocket_highlights[String(descriptor["id"])] = _make_pocket_highlight_ring(descriptor)


## A glowing ring hovering just above the cloth at the called pocket's mouth,
## so the player can see which pocket is committed to for the 8-ball -
## clicking the pocket or the HUD dropdown both call set_eight_pocket_highlight.
func _make_pocket_highlight_ring(descriptor: Dictionary) -> MeshInstance3D:
	var ring := MeshInstance3D.new()
	ring.name = "PocketHighlight_%s" % String(descriptor["id"])
	var torus := TorusMesh.new()
	var visual_radius: float = float(descriptor["visual_radius"])
	torus.outer_radius = visual_radius * 1.1
	torus.inner_radius = visual_radius * 1.0
	ring.mesh = torus
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color(1.0, 0.82, 0.15, 0.9)
	material.emission_enabled = true
	material.emission = Color(1.0, 0.75, 0.1)
	material.emission_energy_multiplier = 2.0
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	ring.material_override = material
	ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	ring.position = Vector3(descriptor["position"].x, 0.02, descriptor["position"].z)
	ring.visible = false
	add_child(ring)
	return ring


## Highlights the pocket currently called for the 8-ball, or clears the
## highlight if `pocket_id` is empty / doesn't match any pocket.
func set_eight_pocket_highlight(pocket_id: String) -> void:
	for id in _pocket_highlights:
		_pocket_highlights[id].visible = id == pocket_id


## A pocket well is lower than the cloth and tapers toward the drop.  It is
## deliberately attached to the table rather than the translated trigger
## Area3D, which prevents a second position offset from lifting it into the
## rail.
## A thin leather ring reads as a fitted pocket liner rather than a raw hole
## in the slate.  The opening remains non-colliding; the calibrated Area3D
## directly below it continues to own pocket capture.
func _build_visual_pocket_mouth(descriptor: Dictionary, material: StandardMaterial3D) -> void:
	var mouth := MeshInstance3D.new()
	mouth.name = "PocketMouth_%s" % String(descriptor["id"])
	var mesh := CylinderMesh.new()
	var mouth_radius := float(descriptor["mouth_width"]) * 0.5
	mesh.top_radius = mouth_radius * 0.90
	mesh.bottom_radius = mouth_radius * 0.82
	mesh.height = 0.018
	mesh.radial_segments = 32
	mouth.mesh = mesh
	mouth.position = _pocket_visual_center(descriptor) + Vector3(0.0, 0.014, 0.0)
	mouth.set_surface_override_material(0, material)
	mouth.visible = false
	add_child(mouth)


func _build_pocket_leather_rim(descriptor: Dictionary, material: StandardMaterial3D) -> void:
	var center := _pocket_visual_center(descriptor)
	var outer_radius := float(descriptor["mouth_width"]) * 0.5
	var rim_width := outer_radius * 0.10
	var inner_radius := maxf(outer_radius - rim_width, Profile.BALL_RADIUS * 0.82)
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	for index in range(32):
		var angle_a := TAU * float(index) / 32.0
		var angle_b := TAU * float(index + 1) / 32.0
		var outer_a := Vector3(center.x + cos(angle_a) * outer_radius, 0.018, center.z + sin(angle_a) * outer_radius)
		var outer_b := Vector3(center.x + cos(angle_b) * outer_radius, 0.018, center.z + sin(angle_b) * outer_radius)
		var inner_a := Vector3(center.x + cos(angle_a) * inner_radius, 0.020, center.z + sin(angle_a) * inner_radius)
		var inner_b := Vector3(center.x + cos(angle_b) * inner_radius, 0.020, center.z + sin(angle_b) * inner_radius)
		surface.add_vertex(outer_a)
		surface.add_vertex(outer_b)
		surface.add_vertex(inner_b)
		surface.add_vertex(outer_a)
		surface.add_vertex(inner_b)
		surface.add_vertex(inner_a)
	surface.generate_normals()
	var rim := MeshInstance3D.new()
	rim.name = "PocketLeatherRim_%s" % String(descriptor["id"])
	rim.mesh = surface.commit()
	rim.set_surface_override_material(0, material)
	rim.visible = false
	add_child(rim)


func _build_pocket_well(descriptor: Dictionary, material: StandardMaterial3D) -> void:
	var drop_depth := maxf(
		float(descriptor.get("drop_depth", descriptor["trigger_height"])),
		Profile.POCKET_DROP_DEPTH
	)
	var well := MeshInstance3D.new()
	well.name = "PocketWell_%s" % String(descriptor["id"])
	var mesh := CylinderMesh.new()
	# Keep the dark taper nearly flush with the cut edge, while remaining
	# slightly below the cloth so the opening reads as a clean recess.
	mesh.top_radius = _pocket_cutout_radius(descriptor) * 0.99
	mesh.bottom_radius = maxf(
		float(descriptor["throat_width"]) * 0.28,
		Profile.BALL_RADIUS * 0.62
	)
	mesh.height = drop_depth
	mesh.radial_segments = 32
	mesh.rings = 4
	well.mesh = mesh
	well.visible = false
	well.position = _pocket_cutout_center(descriptor) + Vector3(0.0, -drop_depth * 0.5 - 0.008, 0.0)
	well.set_surface_override_material(0, material)
	add_child(well)


## Retained only as an inactive reference for the former four-sided recess.
func _build_legacy_pocket_recess(area: Area3D, descriptor: Dictionary, material: StandardMaterial3D) -> void:
	var top_y := -float(descriptor["trigger_center_y"]) + 0.012
	var drop_depth := float(descriptor.get("drop_depth", descriptor["trigger_height"]))
	var mouth := _pocket_mouth_outline(descriptor, top_y)
	var throat := _pocket_throat_outline(mouth, top_y - drop_depth)
	var recess := MeshInstance3D.new()
	recess.name = "PocketRecess_%s" % String(descriptor["id"])
	recess.mesh = _make_pocket_recess_mesh(mouth, throat)
	recess.set_surface_override_material(0, material)
	area.add_child(recess)


func _pocket_mouth_outline(descriptor: Dictionary, top_y: float) -> Array[Vector3]:
	var inward: Vector3 = descriptor["inward_normal"]
	inward.y = 0.0
	inward = inward.normalized()
	var lateral := Vector3(-inward.z, 0.0, inward.x)
	var mouth_width := float(descriptor["mouth_width"])
	var throat_width := float(descriptor["throat_width"])
	var shelf_depth := float(descriptor["shelf_depth"])
	var is_corner := String(descriptor["pocket_type"]) == "corner"
	var lip_depth := maxf(
		shelf_depth + Profile.CUSHION_THICKNESS,
		mouth_width * (0.66 if is_corner else 0.52)
	)
	var outer_center := -inward * maxf(Profile.CUSHION_THICKNESS * 0.25, 0.035)
	var inner_center := inward * lip_depth
	var outer_half := mouth_width * 0.5
	var inner_half := throat_width * 0.5
	return [
		Vector3(outer_center.x + lateral.x * outer_half, top_y, outer_center.z + lateral.z * outer_half),
		Vector3(outer_center.x - lateral.x * outer_half, top_y, outer_center.z - lateral.z * outer_half),
		Vector3(inner_center.x - lateral.x * inner_half, top_y, inner_center.z - lateral.z * inner_half),
		Vector3(inner_center.x + lateral.x * inner_half, top_y, inner_center.z + lateral.z * inner_half),
	]


func _pocket_throat_outline(mouth: Array[Vector3], bottom_y: float) -> Array[Vector3]:
	var center := Vector3.ZERO
	for point in mouth:
		center += point
	center /= float(mouth.size())
	var throat: Array[Vector3] = []
	for point in mouth:
		var inset := center + (point - center) * 0.56
		inset.y = bottom_y
		throat.append(inset)
	return throat


func _make_pocket_recess_mesh(mouth: Array[Vector3], throat: Array[Vector3]) -> ArrayMesh:
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	for index in mouth.size():
		var next_index := (index + 1) % mouth.size()
		surface.add_vertex(mouth[index])
		surface.add_vertex(mouth[next_index])
		surface.add_vertex(throat[next_index])
		surface.add_vertex(mouth[index])
		surface.add_vertex(throat[next_index])
		surface.add_vertex(throat[index])
	for index in range(1, throat.size() - 1):
		surface.add_vertex(throat[0])
		surface.add_vertex(throat[index + 1])
		surface.add_vertex(throat[index])
	surface.generate_normals()
	return surface.commit()


## Keeps gameplay colliders and pocket areas data-driven while presenting the
## licensed traditional table model instead of procedural placeholder geometry.
func _build_traditional_table_visual() -> void:
	_hide_procedural_table_visuals()
	var model := TraditionalTableModel.instantiate()
	model.name = "TraditionalTableVisual"
	model.scale = Vector3(
		TRADITIONAL_TABLE_HORIZONTAL_SCALE,
		TRADITIONAL_TABLE_VERTICAL_SCALE,
		TRADITIONAL_TABLE_HORIZONTAL_SCALE,
	)
	# The source scene sits on its own floor, with the cloth 0.757m above it.
	# Align that cloth with the calibrated play plane at y = 0.
	model.position.y = -TRADITIONAL_TABLE_CLOTH_HEIGHT * TRADITIONAL_TABLE_VERTICAL_SCALE
	# The asset's long axis is Z; gameplay uses X for the table length.
	model.rotation.y = PI * 0.5
	_hide_traditional_model_props(model)
	add_child(model)
	# The licensed model already supplies its leather pocket castings.  Keeping a
	# second procedural facing here stacked opaque disks over those openings.


func _hide_procedural_table_visuals() -> void:
	for child in get_children():
		if child is VisualInstance3D:
			child.visible = false


func _hide_traditional_model_props(node: Node, hidden_ancestor: bool = false) -> void:
	var node_name := String(node.name).to_lower()
	var should_hide := hidden_ancestor or (
		node_name.begins_with("billiard_ball")
		or node_name.begins_with("pool_cue")
		or node_name.begins_with("ceiling_light")
	)
	if node is Light3D:
		should_hide = true
	if should_hide and node is VisualInstance3D:
		node.visible = false
	for child in node.get_children():
		_hide_traditional_model_props(child, should_hide)


func _build_traditional_pocket_facings() -> void:
	var leather := _traditional_leather_material()
	var cavity := _traditional_pocket_cavity_material()
	for descriptor in Profile.get_pocket_capture_descriptors():
		_add_traditional_pocket_facing(descriptor, leather, cavity)


func _add_traditional_pocket_facing(
	descriptor: Dictionary,
	leather: StandardMaterial3D,
	cavity: StandardMaterial3D,
) -> void:
	var mouth_radius := float(descriptor["visual_radius"])
	var inward: Vector3 = descriptor["inward_normal"]
	inward.y = 0.0
	inward = inward.normalized()
	var outward := -inward
	var is_corner := String(descriptor["pocket_type"]) == "corner"
	var outer_radius := mouth_radius + (0.085 if is_corner else 0.070)
	var inner_radius := mouth_radius * (0.76 if is_corner else 0.70)
	var center: Vector3 = descriptor.get("drop_center", descriptor["position"])
	var rim_top := 0.180
	var rim_bottom := 0.142
	var center_angle := atan2(outward.z, outward.x)
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	for index in range(18):
		var ratio_a := float(index) / 18.0
		var ratio_b := float(index + 1) / 18.0
		var angle_a := center_angle - PI * 0.5 + PI * ratio_a
		var angle_b := center_angle - PI * 0.5 + PI * ratio_b
		var outer_top_a := _pocket_arc_vertex(center, outer_radius, angle_a, rim_top)
		var outer_top_b := _pocket_arc_vertex(center, outer_radius, angle_b, rim_top)
		var inner_top_a := _pocket_arc_vertex(center, inner_radius, angle_a, rim_top)
		var inner_top_b := _pocket_arc_vertex(center, inner_radius, angle_b, rim_top)
		var outer_bottom_a := _pocket_arc_vertex(center, outer_radius, angle_a, rim_bottom)
		var outer_bottom_b := _pocket_arc_vertex(center, outer_radius, angle_b, rim_bottom)
		var inner_bottom_a := _pocket_arc_vertex(center, inner_radius, angle_a, rim_bottom)
		var inner_bottom_b := _pocket_arc_vertex(center, inner_radius, angle_b, rim_bottom)
		_add_textured_vertex(surface, outer_top_a, Vector2(ratio_a, 0.0))
		_add_textured_vertex(surface, outer_top_b, Vector2(ratio_b, 0.0))
		_add_textured_vertex(surface, inner_top_b, Vector2(ratio_b, 1.0))
		_add_textured_vertex(surface, outer_top_a, Vector2(ratio_a, 0.0))
		_add_textured_vertex(surface, inner_top_b, Vector2(ratio_b, 1.0))
		_add_textured_vertex(surface, inner_top_a, Vector2(ratio_a, 1.0))
		_add_textured_vertex(surface, outer_top_a, Vector2(ratio_a, 0.0))
		_add_textured_vertex(surface, outer_bottom_a, Vector2(ratio_a, 1.0))
		_add_textured_vertex(surface, outer_bottom_b, Vector2(ratio_b, 1.0))
		_add_textured_vertex(surface, outer_top_a, Vector2(ratio_a, 0.0))
		_add_textured_vertex(surface, outer_bottom_b, Vector2(ratio_b, 1.0))
		_add_textured_vertex(surface, outer_top_b, Vector2(ratio_b, 0.0))
		_add_textured_vertex(surface, inner_top_a, Vector2(ratio_a, 0.0))
		_add_textured_vertex(surface, inner_top_b, Vector2(ratio_b, 0.0))
		_add_textured_vertex(surface, inner_bottom_b, Vector2(ratio_b, 1.0))
		_add_textured_vertex(surface, inner_top_a, Vector2(ratio_a, 0.0))
		_add_textured_vertex(surface, inner_bottom_b, Vector2(ratio_b, 1.0))
		_add_textured_vertex(surface, inner_bottom_a, Vector2(ratio_a, 1.0))
	surface.generate_normals()
	var rim := MeshInstance3D.new()
	rim.name = "TraditionalLeatherFacing_%s" % String(descriptor["id"])
	rim.mesh = surface.commit()
	rim.set_surface_override_material(0, leather)
	add_child(rim)

	var pocket_void := MeshInstance3D.new()
	pocket_void.name = "TraditionalPocketVoid_%s" % String(descriptor["id"])
	var void_mesh := CylinderMesh.new()
	void_mesh.top_radius = inner_radius * 0.93
	void_mesh.bottom_radius = inner_radius * 0.82
	void_mesh.height = 0.018
	void_mesh.radial_segments = 32
	pocket_void.mesh = void_mesh
	pocket_void.position = center + Vector3(0.0, rim_bottom - 0.012, 0.0)
	pocket_void.set_surface_override_material(0, cavity)
	add_child(pocket_void)


func _pocket_arc_vertex(center: Vector3, radius: float, angle: float, height: float) -> Vector3:
	return center + Vector3(cos(angle) * radius, height, sin(angle) * radius)


func _traditional_leather_material() -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_texture = load("res://assets/textures/leather_pocket_facing.png")
	material.albedo_color = Color(0.16, 0.035, 0.025)
	material.roughness = 0.42
	material.metallic = 0.0
	material.uv1_scale = Vector3(2.0, 2.0, 1.0)
	return material


func _traditional_pocket_cavity_material() -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.006, 0.003, 0.002)
	material.roughness = 0.95
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	return material


func _build_legs() -> void:
	var leg_material := _wood_material()
	for sign_x in [1.0, -1.0]:
		for sign_z in [1.0, -1.0]:
			var leg := MeshInstance3D.new()
			var cylinder := CylinderMesh.new()
			cylinder.top_radius = Profile.LEG_TOP_RADIUS
			cylinder.bottom_radius = Profile.LEG_BOTTOM_RADIUS
			cylinder.height = Profile.LEG_HEIGHT
			leg.mesh = cylinder
			leg.set_surface_override_material(0, leg_material)
			leg.position = Vector3(
				sign_x * (LENGTH * 0.5 - 0.5),
				-Profile.BED_THICKNESS - Profile.LEG_HEIGHT * 0.5,
				sign_z * (WIDTH * 0.5 - 0.5)
			)
			add_child(leg)


func _felt_material() -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_texture = TextureGen.generate_felt_texture()
	material.roughness = 0.95
	material.metallic = 0.0
	material.uv1_scale = Vector3(4.0, 4.0, 1.0)
	return material


func _rubber_material() -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_texture = TextureGen.generate_rubber_texture()
	material.roughness = 0.8
	return material


func _polished_wood_material() -> StandardMaterial3D:
	var material := _wood_material()
	material.roughness = 0.28
	material.metallic = 0.08
	return material


func _sight_material() -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.78, 0.66, 0.42)
	material.metallic = 0.18
	material.roughness = 0.30
	return material


func _leather_material() -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.018, 0.006, 0.003)
	material.roughness = 0.38
	material.metallic = 0.0
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	return material


func _wood_material() -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_texture = load("res://assets/textures/mahogany_rail.png")
	material.albedo_color = Color(0.52, 0.34, 0.28)
	material.roughness = 0.70
	material.metallic = 0.0
	material.uv1_scale = Vector3(0.45, 0.45, 1.0)
	return material
