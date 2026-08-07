## Physical, data-driven definition of the game's nominal 8-foot pool table.
##
## All measurements start in metres and are converted once using
## WORLD_UNITS_PER_METER.  Keeping the conversion here prevents the rendered
## table, Godot collision shapes, and a future BilliardsPhysics solver from
## silently drifting apart.
class_name TableProfile
extends RefCounted


const NOMINAL_TABLE_SIZE_FT: int = 8
const WORLD_UNITS_PER_METER: float = 5.0

## Standard 8-foot "home/tournament" playing surface: 88 x 44 inches.
const PLAYING_SURFACE_LENGTH_METERS: float = 2.2352
const PLAYING_SURFACE_WIDTH_METERS: float = 1.1176
const PLAYING_SURFACE_LENGTH: float = PLAYING_SURFACE_LENGTH_METERS * WORLD_UNITS_PER_METER
const PLAYING_SURFACE_WIDTH: float = PLAYING_SURFACE_WIDTH_METERS * WORLD_UNITS_PER_METER

## The licensed traditional-table mesh is deliberately retained at its native
## proportions.  Its visible cushion noses sit slightly outside the nominal
## 88-by-44 cloth rectangle, so the solver must use these measured offsets
## rather than stopping a ball on the (invisible) nominal edge.
##
## A ball is stopped by a discrete per-frame box test, not a continuous one:
## place that box's face exactly on the mesh-traced rubber surface and a fast
## ball's centre is already past it by the time the next physics step checks,
## so the ball visibly buries itself in the rubber before the bounce fires.
## Keeping the collision face this far inside the rendered nose guarantees
## contact registers before the ball reaches the visible rubber.
const CUSHION_CLIP_SAFETY_MARGIN: float = 0.10
## Pulled in from the raw mesh-traced outset by CUSHION_CLIP_SAFETY_MARGIN
## above -- see that constant for why.
const RENDERED_CUSHION_NOSE_OUTSET_X: float = 0.368733 - CUSHION_CLIP_SAFETY_MARGIN
const RENDERED_CUSHION_NOSE_OUTSET_Z: float = 0.250530 - CUSHION_CLIP_SAFETY_MARGIN

## Where the straight cushion nose actually stops being straight and starts
## curving into a pocket, measured directly off the mesh's felt-boundary
## trace's turning angle (the vertex where the boundary bends sharply, not
## just an interior point that happens to sit near the corner -- an earlier
## measurement grabbed the latter and left the cushion box up to 0.09 units
## short of the real nose end at every corner).
const RENDERED_LONG_NOSE_CORNER_END_X: float = 5.54 # 5.5287743
const RENDERED_SHORT_NOSE_CORNER_END_Z: float = 2.618867 # 2.618867
const RENDERED_LONG_NOSE_SIDE_END_X: float = 0.48 # 0.460608
## Each jaw box is placed directly by its own center/length/width/rotation
## (measured for the sign_x=1, sign_z=1 quadrant; the two side-pocket jaws
## additionally use sign_x=1 as "right" of the pocket), then mirrored into
## the remaining quadrants by _mirrored_jaw_descriptor. Tune these by eye
## against the rendered mesh -- there is no anchor/tip bridge math to keep
## in sync any more.
const CORNER_LONG_JAW_CENTER_X: float = 5.42 # 5.450685
const CORNER_LONG_JAW_CENTER_Z: float = 3.15 # 3.064765
const CORNER_LONG_JAW_LENGTH: float = 0.37
const CORNER_LONG_JAW_WIDTH: float = 0.21
const CORNER_LONG_JAW_ROTATION_DEGREES: float = 45

const CORNER_SHORT_JAW_CENTER_X: float = 6.06 # 6.095866
const CORNER_SHORT_JAW_CENTER_Z: float = 2.52 # 2.579433
const CORNER_SHORT_JAW_LENGTH: float = 0.37
const CORNER_SHORT_JAW_WIDTH: float = 0.21
const CORNER_SHORT_JAW_ROTATION_DEGREES: float = 45

const SIDE_JAW_CENTER_X: float = 0.49 # 0.382059
const SIDE_JAW_CENTER_Z: float = 3.1 # 3.064765
const SIDE_JAW_LENGTH: float = 0.157387
const SIDE_JAW_WIDTH: float = 0.27
const SIDE_JAW_ROTATION_DEGREES: float = 60

## A regulation 2.25 inch ball.  This matches Ball.gd's existing radius.
const BALL_DIAMETER_METERS: float = 0.05715
const BALL_RADIUS: float = BALL_DIAMETER_METERS * WORLD_UNITS_PER_METER * 0.5
const BALL_REST_CLEARANCE: float = 0.0025

## A racked ball must touch its neighbours. The forward spacing is the
## altitude of an equilateral triangle whose sides are one ball diameter.
## Keep these here so the live Game layout and deterministic break checks use
## the same production geometry instead of independently tuned gaps.
const RACK_LATERAL_BALL_SPACING: float = BALL_RADIUS * 2.0
const RACK_ROW_ADVANCE: float = RACK_LATERAL_BALL_SPACING * 0.8660254037844386

## Slate/cloth and nose geometry.  Cushion height is the exposed rubber nose,
## measured above the cloth.  The collider is intentionally a simple box: the
## following nose/jaw descriptors give a later solver enough data to replace it
## with an analytic cushion if desired.
const BED_THICKNESS_METERS: float = 0.0508
const BED_THICKNESS: float = BED_THICKNESS_METERS * WORLD_UNITS_PER_METER
const CUSHION_HEIGHT_METERS: float = 0.037
const CUSHION_HEIGHT: float = CUSHION_HEIGHT_METERS * WORLD_UNITS_PER_METER
const CUSHION_THICKNESS_METERS: float = 0.050
const CUSHION_THICKNESS: float = CUSHION_THICKNESS_METERS * WORLD_UNITS_PER_METER
const RAIL_WIDTH_METERS: float = 0.125
const RAIL_WIDTH: float = RAIL_WIDTH_METERS * WORLD_UNITS_PER_METER
const RAIL_HEIGHT: float = CUSHION_HEIGHT + 0.020

## Pocket mouths follow common WPA/BCA recreational-table targets.  A mouth is
## the opening at the cushion nose; the throat is narrower and lives behind the
## shelf.  Keeping both values avoids modelling a pocket as only a round hole.
## Modest league-table opening: corners go from 4.75/3.75 in to 5.00/4.00
## in (mouth/throat), with sides growing proportionately to 5.50/4.50 in.
## The descriptor's capture radius remains derived from the throat, and the
## jaw/cushion anchors below derive from these mouth widths.
const CORNER_MOUTH_METERS: float = 0.12700 # 5.00 in
const SIDE_MOUTH_METERS: float = 0.13970 # 5.50 in
const CORNER_THROAT_METERS: float = 0.10160 # 4.00 in
const SIDE_THROAT_METERS: float = 0.11430 # 4.50 in
const CORNER_SHELF_DEPTH_METERS: float = 0.0381 # 1.50 in
const SIDE_SHELF_DEPTH_METERS: float = 0.03175 # 1.25 in
const CORNER_MOUTH: float = CORNER_MOUTH_METERS * WORLD_UNITS_PER_METER
const SIDE_MOUTH: float = SIDE_MOUTH_METERS * WORLD_UNITS_PER_METER
const CORNER_THROAT: float = CORNER_THROAT_METERS * WORLD_UNITS_PER_METER
const SIDE_THROAT: float = SIDE_THROAT_METERS * WORLD_UNITS_PER_METER
const CORNER_SHELF_DEPTH: float = CORNER_SHELF_DEPTH_METERS * WORLD_UNITS_PER_METER
const SIDE_SHELF_DEPTH: float = SIDE_SHELF_DEPTH_METERS * WORLD_UNITS_PER_METER

## The leather pocket facing sits beyond the cushion nose.  Keeping its
## location in the shared profile makes the visual drop target agree with the
## visible hole instead of the legacy trigger at the cloth edge.
## The corner hole is not on the exact 45-degree diagonal from the nominal
## corner: it sits closer to the long rail than the short one, so X and Z
## need independent measured offsets rather than one diagonal scalar.
const CORNER_POCKET_VISUAL_OUTSET_X: float = 0.32 # 0.442470
const CORNER_POCKET_VISUAL_OUTSET_Z: float = 0.2 # 0.325989
const SIDE_POCKET_VISUAL_OUTSET: float = 0.48 # 0.655791

## Clips the long cushion box's own corner (see _cushion_descriptors) so it
## stops short of where the rendered nose curves away into the pocket mouth
## instead of visibly overlapping the pocket liner.
const LONG_JAW_ANCHOR_INSET: float = 0.17

## Mirrors LONG_JAW_ANCHOR_INSET for the short cushion's own corner.
const SHORT_JAW_ANCHOR_INSET: float = 0.16
## The rubber points/jaws reduce the effective opening on off-angle shots.
const JAW_LENGTH_METERS: float = 0.055
const JAW_LENGTH: float = JAW_LENGTH_METERS * WORLD_UNITS_PER_METER
const JAW_HEIGHT: float = CUSHION_HEIGHT
const CORNER_JAW_ANGLE_DEGREES: float = 0.0
const SIDE_JAW_ANGLE_DEGREES: float = 0.0

## A pocket trigger sits below the cloth and only represents the throat/drop
## zone.  The live collision jaws decide whether a ball can actually reach it.
const POCKET_DROP_DEPTH_METERS: float = 0.128
const POCKET_DROP_DEPTH: float = POCKET_DROP_DEPTH_METERS * WORLD_UNITS_PER_METER
const POCKET_TRIGGER_TOP: float = 0.040
const POCKET_TRIGGER_CENTER_Y: float = POCKET_TRIGGER_TOP - POCKET_DROP_DEPTH * 0.5

## Calibrated material values shared by generated Godot collision bodies and
## the exported descriptors.  Ball.gd owns cloth rolling resistance; bed
## friction is deliberately small so contact friction does not double-count it.
const BED_FRICTION: float = 0.02
const BED_RESTITUTION: float = 0.05
const CUSHION_FRICTION: float = 0.23
const CUSHION_RESTITUTION: float = 0.72
const JAW_FRICTION: float = 0.25
const JAW_RESTITUTION: float = 0.66
const RAIL_FRICTION: float = 0.40
const RAIL_RESTITUTION: float = 0.10
const CUSHION_TANGENTIAL_DAMPING: float = 0.89

## Cloth/ball coefficients are dimensionless; gravity is converted to the
## project scale so velocities remain five scene units per real metre.
const GRAVITY: float = 9.8 * WORLD_UNITS_PER_METER
const CLOTH_SLIDING_FRICTION: float = 0.20
## A 2.0 m/s rolling ball travels v²/(2 μ g) = 5.831 m at μ = 0.035.
## That is 2.19 playing-surface lengths, yet much shorter than the 12.755 m
## glide from the previous μ = 0.016 calibration.
const CLOTH_ROLLING_FRICTION: float = 0.035
const CLOTH_SPIN_FRICTION: float = 0.045
const BALL_RESTITUTION: float = 0.93
const BALL_CONTACT_FRICTION: float = 0.05

const LEG_HEIGHT: float = 2.0
const LEG_TOP_RADIUS: float = 0.175
const LEG_BOTTOM_RADIUS: float = 0.225


static func meters_to_units(distance_meters: float) -> float:
	return distance_meters * WORLD_UNITS_PER_METER


static func units_to_meters(distance_units: float) -> float:
	return distance_units / WORLD_UNITS_PER_METER


static func get_playing_surface_size() -> Vector2:
	return Vector2(PLAYING_SURFACE_LENGTH, PLAYING_SURFACE_WIDTH)


static func get_ball_radius() -> float:
	return BALL_RADIUS


## The head spot is one quarter of the playing length from the head rail.
static func get_head_spot() -> Vector3:
	return Vector3(-PLAYING_SURFACE_LENGTH * 0.25, BALL_RADIUS + BALL_REST_CLEARANCE, 0.0)


## The rack apex mirrors the head spot at the foot end of the table.
static func get_rack_apex() -> Vector3:
	return Vector3(PLAYING_SURFACE_LENGTH * 0.25, BALL_RADIUS + BALL_REST_CLEARANCE, 0.0)


static func get_rack_lateral_ball_spacing() -> float:
	return RACK_LATERAL_BALL_SPACING


static func get_rack_row_advance() -> float:
	return RACK_ROW_ADVANCE


## Valid ball-in-hand area: the cloth rectangle, inset by the supplied ball
## radius, with each pocket mouth removed.  The caller may pass a smaller
## radius for a point/cursor test, but ball placement should use BALL_RADIUS.
static func is_position_on_cloth(position: Vector3, radius: float = BALL_RADIUS) -> bool:
	var safe_radius := maxf(radius, 0.0)
	var half_length := PLAYING_SURFACE_LENGTH * 0.5 - safe_radius
	var half_width := PLAYING_SURFACE_WIDTH * 0.5 - safe_radius
	if absf(position.x) > half_length or absf(position.z) > half_width:
		return false
	for pocket in get_pocket_capture_descriptors():
		var mouth_center: Vector3 = pocket["position"]
		var delta := Vector2(position.x - mouth_center.x, position.z - mouth_center.z)
		var excluded_radius := float(pocket["mouth_width"]) * 0.5 + safe_radius
		if delta.length_squared() < excluded_radius * excluded_radius:
			return false
	return true


## Stable physical constants for UI/debugging or a future physics backend.
static func get_calibration() -> Dictionary:
	return {
		"gravity": GRAVITY,
		"world_units_per_meter": WORLD_UNITS_PER_METER,
		"ball_radius": BALL_RADIUS,
		"rolling_friction": CLOTH_ROLLING_FRICTION,
		"sliding_friction": CLOTH_SLIDING_FRICTION,
		"spin_friction": CLOTH_SPIN_FRICTION,
		"ball_restitution": BALL_RESTITUTION,
		"ball_friction": BALL_CONTACT_FRICTION,
		"bed_friction": BED_FRICTION,
		"bed_restitution": BED_RESTITUTION,
		"cushion_friction": CUSHION_FRICTION,
		"cushion_restitution": CUSHION_RESTITUTION,
		"cushion_tangential_damping": CUSHION_TANGENTIAL_DAMPING,
		"jaw_friction": JAW_FRICTION,
		"jaw_restitution": JAW_RESTITUTION,
	}


## Returns every static solid collider used to build the table.  Each returned
## dictionary is a fresh value and contains an oriented-box definition:
## id, kind, center, size, normal, rotation_y, friction, restitution, rough,
## absorbent.  `normal` points from the collider toward the legal play area.
static func get_static_collision_descriptors() -> Array[Dictionary]:
	var descriptors: Array[Dictionary] = []
	descriptors.append(_bed_descriptor())
	descriptors.append_array(_cushion_descriptors())
	descriptors.append_array(_rail_descriptors())
	descriptors.append_array(_jaw_descriptors())
	return descriptors


## Returns the six non-binary pocket regions.  `mouth_width`, `throat_width`,
## `shelf_depth`, and jaw angle are supplied alongside the trigger cylinder so
## BilliardsPhysics can evaluate jaw/shelf entry rather than use distance alone.
static func get_pocket_capture_descriptors() -> Array[Dictionary]:
	var pockets: Array[Dictionary] = []
	var half_length := PLAYING_SURFACE_LENGTH * 0.5
	var half_width := PLAYING_SURFACE_WIDTH * 0.5
	for sign_x in [1.0, -1.0]:
		for sign_z in [1.0, -1.0]:
			var position := Vector3(sign_x * half_length, 0.0, sign_z * half_width)
			pockets.append(_pocket_descriptor(
				"corner_%s_%s" % ["right" if sign_x > 0.0 else "left", "top" if sign_z > 0.0 else "bottom"],
				"corner",
				position,
				Vector3(-sign_x, 0.0, -sign_z).normalized(),
				CORNER_MOUTH,
				CORNER_THROAT,
				CORNER_SHELF_DEPTH,
				CORNER_JAW_ANGLE_DEGREES
			))
	for sign_z in [1.0, -1.0]:
		pockets.append(_pocket_descriptor(
			"side_%s" % ["top" if sign_z > 0.0 else "bottom"],
			"side",
			Vector3(0.0, 0.0, sign_z * half_width),
			Vector3(0.0, 0.0, -sign_z),
			SIDE_MOUTH,
			SIDE_THROAT,
			SIDE_SHELF_DEPTH,
			SIDE_JAW_ANGLE_DEGREES
		))
	return pockets


## One array is convenient for consumers that process all table geometry in a
## single pass.  Pocket entries have kind == "pocket" and are not solid boxes.
static func get_physics_descriptors() -> Array[Dictionary]:
	var descriptors := get_static_collision_descriptors()
	descriptors.append_array(get_pocket_capture_descriptors())
	return descriptors


static func _bed_descriptor() -> Dictionary:
	return _box_descriptor(
		"bed",
		"bed",
		Vector3(0.0, -BED_THICKNESS * 0.5, 0.0),
		Vector3(PLAYING_SURFACE_LENGTH, BED_THICKNESS, PLAYING_SURFACE_WIDTH),
		Vector3.UP,
		BED_FRICTION,
		BED_RESTITUTION,
		true,
		false
	)


static func _cushion_descriptors() -> Array[Dictionary]:
	var descriptors: Array[Dictionary] = []
	var half_length := PLAYING_SURFACE_LENGTH * 0.5
	var half_width := PLAYING_SURFACE_WIDTH * 0.5
	var cushion_half_length := half_length + RENDERED_CUSHION_NOSE_OUTSET_X
	var cushion_half_width := half_width + RENDERED_CUSHION_NOSE_OUTSET_Z
	# Segment extents follow the rendered nose's actual straight run, not the
	# regulation mouth widths -- see RENDERED_LONG_NOSE_CORNER_END_X and kin.
	# The corner end is clipped by LONG_JAW_ANCHOR_INSET so this box's own
	# corner -- a hard 90-degree point a flat box cannot avoid, unlike the
	# real rubber, which is already curving away into the pocket mouth there
	# -- does not project into a ball's real diagonal path through the mouth.
	# The long jaw picks up exactly at this clipped point (same inset), so
	# the rendered nose is still covered edge-to-edge with no gap or overlap.
	var long_nose_corner_clipped := RENDERED_LONG_NOSE_CORNER_END_X - LONG_JAW_ANCHOR_INSET
	var long_segment_length := long_nose_corner_clipped - RENDERED_LONG_NOSE_SIDE_END_X
	var long_segment_offset := (long_nose_corner_clipped + RENDERED_LONG_NOSE_SIDE_END_X) * 0.5
	var short_nose_corner_clipped := RENDERED_SHORT_NOSE_CORNER_END_Z - SHORT_JAW_ANCHOR_INSET
	var short_segment_length := short_nose_corner_clipped * 2.0
	var center_y := CUSHION_HEIGHT * 0.5

	for sign_z in [1.0, -1.0]:
		for sign_x in [1.0, -1.0]:
			descriptors.append(_box_descriptor(
				"long_%s_%s" % ["right" if sign_x > 0.0 else "left", "top" if sign_z > 0.0 else "bottom"],
				"cushion",
				Vector3(sign_x * long_segment_offset, center_y, sign_z * (cushion_half_width + CUSHION_THICKNESS * 0.5)),
				Vector3(long_segment_length, CUSHION_HEIGHT, CUSHION_THICKNESS),
				Vector3(0.0, 0.0, -sign_z),
				CUSHION_FRICTION,
				CUSHION_RESTITUTION,
				false,
				true
			))

	for sign_x in [1.0, -1.0]:
		descriptors.append(_box_descriptor(
			"short_%s" % ["right" if sign_x > 0.0 else "left"],
			"cushion",
			Vector3(sign_x * (cushion_half_length + CUSHION_THICKNESS * 0.5), center_y, 0.0),
			Vector3(CUSHION_THICKNESS, CUSHION_HEIGHT, short_segment_length),
			Vector3(-sign_x, 0.0, 0.0),
			CUSHION_FRICTION,
			CUSHION_RESTITUTION,
			false,
			true
		))
	return descriptors


static func _rail_descriptors() -> Array[Dictionary]:
	var descriptors: Array[Dictionary] = []
	var half_length := PLAYING_SURFACE_LENGTH * 0.5
	var half_width := PLAYING_SURFACE_WIDTH * 0.5
	var center_y := RAIL_HEIGHT * 0.5
	for sign_z in [1.0, -1.0]:
		descriptors.append(_box_descriptor(
			"rail_long_%s" % ["top" if sign_z > 0.0 else "bottom"],
			"rail",
			Vector3(0.0, center_y, sign_z * (half_width + CUSHION_THICKNESS + RAIL_WIDTH * 0.5)),
			Vector3(PLAYING_SURFACE_LENGTH + 2.0 * RAIL_WIDTH, RAIL_HEIGHT, RAIL_WIDTH),
			Vector3(0.0, 0.0, -sign_z),
			RAIL_FRICTION,
			RAIL_RESTITUTION,
			false,
			false
		))
	for sign_x in [1.0, -1.0]:
		descriptors.append(_box_descriptor(
			"rail_short_%s" % ["right" if sign_x > 0.0 else "left"],
			"rail",
			Vector3(sign_x * (half_length + CUSHION_THICKNESS + RAIL_WIDTH * 0.5), center_y, 0.0),
			Vector3(RAIL_WIDTH, RAIL_HEIGHT, PLAYING_SURFACE_WIDTH + 2.0 * CUSHION_THICKNESS),
			Vector3(-sign_x, 0.0, 0.0),
			RAIL_FRICTION,
			RAIL_RESTITUTION,
			false,
			false
		))
	return descriptors


## Each jaw box is placed and sized directly (center, length, width, rotation)
## rather than derived from cushion/mouth anchor points, so it can be eyeballed
## against the rendered mesh like the plain rail boxes are. Every jaw's
## constants above describe the sign_x=1, sign_z=1 quadrant (the corner jaws)
## or the sign_x=1 "right of the pocket" jaw (the side pockets);
## _mirrored_jaw_descriptor reflects that single placement into the table's
## other quadrants.
static func _jaw_descriptors() -> Array[Dictionary]:
	var descriptors: Array[Dictionary] = []
	var center_y := JAW_HEIGHT * 0.5

	for sign_x in [1.0, -1.0]:
		for sign_z in [1.0, -1.0]:
			descriptors.append(_mirrored_jaw_descriptor(
				"corner_long_%s_%s" % [sign_x, sign_z],
				CORNER_LONG_JAW_CENTER_X, CORNER_LONG_JAW_CENTER_Z,
				CORNER_LONG_JAW_LENGTH, CORNER_LONG_JAW_WIDTH,
				CORNER_LONG_JAW_ROTATION_DEGREES,
				sign_x, sign_z, center_y
			))
			descriptors.append(_mirrored_jaw_descriptor(
				"corner_short_%s_%s" % [sign_x, sign_z],
				CORNER_SHORT_JAW_CENTER_X, CORNER_SHORT_JAW_CENTER_Z,
				CORNER_SHORT_JAW_LENGTH, CORNER_SHORT_JAW_WIDTH,
				CORNER_SHORT_JAW_ROTATION_DEGREES,
				sign_x, sign_z, center_y
			))

	for sign_z in [1.0, -1.0]:
		descriptors.append(_mirrored_jaw_descriptor(
			"side_left_%s" % sign_z,
			SIDE_JAW_CENTER_X, SIDE_JAW_CENTER_Z,
			SIDE_JAW_LENGTH, SIDE_JAW_WIDTH,
			SIDE_JAW_ROTATION_DEGREES,
			-1.0, sign_z, center_y
		))
		descriptors.append(_mirrored_jaw_descriptor(
			"side_right_%s" % sign_z,
			SIDE_JAW_CENTER_X, SIDE_JAW_CENTER_Z,
			SIDE_JAW_LENGTH, SIDE_JAW_WIDTH,
			SIDE_JAW_ROTATION_DEGREES,
			1.0, sign_z, center_y
		))
	return descriptors


## Reflects a single hand-placed jaw box (given for sign_x=1, sign_z=1) into
## whichever quadrant this call's signs select. Center mirrors component-wise;
## rotation mirrors by flipping the sign fed to each axis of the box's local
## forward direction before re-deriving the angle, which reproduces the same
## reflection a mirrored center/tip pair would have produced without needing
## a separate rotation number per quadrant.
static func _mirrored_jaw_descriptor(
	id: String,
	center_x: float,
	center_z: float,
	length: float,
	width: float,
	rotation_degrees: float,
	sign_x: float,
	sign_z: float,
	center_y: float
) -> Dictionary:
	var base_rotation := deg_to_rad(rotation_degrees)
	var rotation_y := atan2(sign_x * sin(base_rotation), sign_z * cos(base_rotation))
	var normal := -Vector3(sin(rotation_y), 0.0, cos(rotation_y))
	return _box_descriptor(
		id,
		"jaw",
		Vector3(sign_x * center_x, center_y, sign_z * center_z),
		Vector3(width, JAW_HEIGHT, length),
		normal,
		JAW_FRICTION,
		JAW_RESTITUTION,
		false,
		true,
		rotation_y
	)


static func _pocket_descriptor(
	id: String,
	pocket_type: String,
	position: Vector3,
	inward_normal: Vector3,
	mouth_width: float,
	throat_width: float,
	shelf_depth: float,
	jaw_angle_degrees: float
) -> Dictionary:
	var outward := -inward_normal.normalized()
	# `position` is the nominal cloth-edge location used for table sizing.
	# The imported table's leather mouths are farther out, so capture, jaw
	# placement and the falling-ball target must share this visible center.
	# Corner holes are not on the exact 45-degree diagonal from the nominal
	# corner, so they need independent measured X/Z offsets rather than one
	# diagonal scalar; side holes only move along Z.
	var visible_center: Vector3
	if pocket_type == "corner":
		visible_center = position + Vector3(signf(outward.x) * CORNER_POCKET_VISUAL_OUTSET_X, 0.0, signf(outward.z) * CORNER_POCKET_VISUAL_OUTSET_Z)
	else:
		visible_center = position + outward * SIDE_POCKET_VISUAL_OUTSET
	return {
		"id": id,
		"type": "pocket",
		"kind": "pocket",
		"cloth_center": position,
		"center": visible_center,
		"pocket_type": pocket_type,
		"position": visible_center,
		"inward_normal": inward_normal,
		"mouth_width": mouth_width,
		"throat_width": throat_width,
		"shelf_depth": shelf_depth,
		"jaw_angle_degrees": jaw_angle_degrees,
		"capture_radius": throat_width * 0.5,
		"trigger_center_y": POCKET_TRIGGER_CENTER_Y,
		"trigger_height": POCKET_DROP_DEPTH,
		# Keep the visible well and a pocketed ball's fall target tied to the
		# same physical table depth.  Older consumers can continue using
		# trigger_height unchanged.
		"drop_depth": POCKET_DROP_DEPTH,
		"drop_center": visible_center,
		"visual_radius": mouth_width * 0.5,
	}


static func _box_descriptor(
	id: String,
	kind: String,
	center: Vector3,
	size: Vector3,
	normal: Vector3,
	friction: float,
	restitution: float,
	rough: bool,
	absorbent: bool,
	rotation_y: float = 0.0
) -> Dictionary:
	var solver_type := "cushion" if kind == "cushion" or kind == "jaw" else "static"
	var plane_point := _box_plane_point(center, size, normal, rotation_y)
	return {
		"id": id,
		"type": solver_type,
		"kind": kind,
		"center": center,
		"size": size,
		"normal": normal,
		"point": plane_point,
		"offset": normal.dot(plane_point),
		"rotation_y": rotation_y,
		"friction": friction,
		"restitution": restitution,
		"rough": rough,
		"absorbent": absorbent,
		# Full wood-rail boxes sit behind the rubber nose and must not close the
		# six pocket gaps in the custom ball solver. Jaws are enabled: they now
		# anchor to the rendered cushion-nose plane (see _jaw_descriptors), so
		# they guard the real mouth opening instead of blocking it early, and a
		# missed capture deflects off the point instead of escaping the table.
		"solver_enabled": kind != "rail",
	}


## Returns the face touching the legal play area for an arbitrarily yawed box.
## BilliardsPhysics currently consumes this plane while Godot uses full boxes.
static func _box_plane_point(center: Vector3, size: Vector3, normal: Vector3, rotation_y: float) -> Vector3:
	var normalized_normal := normal.normalized()
	var local_x := Vector3(cos(rotation_y), 0.0, -sin(rotation_y))
	var local_z := Vector3(sin(rotation_y), 0.0, cos(rotation_y))
	var extent := absf(normalized_normal.dot(local_x)) * size.x * 0.5
	extent += absf(normalized_normal.y) * size.y * 0.5
	extent += absf(normalized_normal.dot(local_z)) * size.z * 0.5
	return center + normalized_normal * extent
