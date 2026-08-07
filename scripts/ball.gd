class_name BilliardsBall
extends RigidBody3D

## Regulation pool ball.  It can still run with Godot's physics, but a
## BilliardsPhysics node may take ownership through the custom-state methods.
const RADIUS := 0.142875 # 2.25 inches at this project's x5 table scale.
const MASS := 0.17
const WORLD_SCALE := 5.0
const GRAVITY := 9.8 * WORLD_SCALE
const MU_SLIDE := 0.20
const MU_ROLL := 0.016
const MU_SPIN := 0.045
const INERTIA := 0.4 * MASS * RADIUS * RADIUS
const SLEEP_LINEAR := 0.004
const SLEEP_ANGULAR := 0.04

@export var ball_number: int = 0 # 0 is the cue ball.

var pocketed := false
var physics_velocity := Vector3.ZERO
var physics_angular_velocity := Vector3.ZERO
var physics_resting := false
var custom_solver_active := false
var _pocket_drop_elapsed := -1.0
var _pocket_drop_duration := 0.42
var _pocket_drop_start := Vector3.ZERO
var _pocket_entry_target := Vector3.ZERO
var _pocket_drop_target := Vector3.ZERO

@onready var mesh_instance: MeshInstance3D = $MeshInstance3D
@onready var collision_shape: CollisionShape3D = $CollisionShape3D


func _ready() -> void:
	mass = MASS
	gravity_scale = 1.0
	continuous_cd = true
	max_contacts_reported = 4
	contact_monitor = true
	linear_damp = 0.0
	angular_damp = 0.0
	can_sleep = true

	var shape := SphereShape3D.new()
	shape.radius = RADIUS
	collision_shape.shape = shape

	var mesh := SphereMesh.new()
	mesh.radius = RADIUS
	mesh.height = RADIUS * 2.0
	mesh.radial_segments = 32
	mesh.rings = 16
	mesh_instance.mesh = mesh

	var mat := StandardMaterial3D.new()
	mat.albedo_texture = await _get_texture()
	mat.roughness = 0.35
	mat.metallic = 0.05
	mesh_instance.set_surface_override_material(0, mat)

	var phys_mat := PhysicsMaterial.new()
	phys_mat.friction = 0.25
	phys_mat.bounce = 0.6
	physics_material_override = phys_mat


func _get_texture() -> ImageTexture:
	# The ball is also loaded by standalone deterministic tests, where autoloads
	# are not installed.  Resolve the optional generator at runtime instead.
	var texture_gen := get_node_or_null("/root/TextureGen")
	if texture_gen != null:
		var cached: ImageTexture = texture_gen.call("get_ball_texture", ball_number)
		if cached:
			return cached
		return await texture_gen.call("generate_ball_texture", ball_number)
	var fallback_image := Image.create(1, 1, false, Image.FORMAT_RGBA8)
	fallback_image.fill(Color.WHITE)
	return ImageTexture.create_from_image(fallback_image)


## Called by a pocket Area or by BilliardsPhysics after a pocket descriptor hit.
func pocket(pocket_center: Vector3 = Vector3.ZERO, drop_depth: float = 0.64) -> void:
	if pocketed:
		return
	pocketed = true
	physics_velocity = Vector3.ZERO
	physics_angular_velocity = Vector3.ZERO
	physics_resting = true
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	freeze = true
	collision_layer = 0
	collision_mask = 0
	_pocket_drop_start = global_position
	var target_center := pocket_center if pocket_center != Vector3.ZERO else global_position
	# The solver captures at the shelf so fast shots do not rebound from a jaw.
	# Keep the visible ball on the cloth until it reaches the actual mouth.
	_pocket_entry_target = Vector3(target_center.x, global_position.y, target_center.z)
	_pocket_drop_target = Vector3(target_center.x, target_center.y - maxf(drop_depth, RADIUS * 1.5), target_center.z)
	_pocket_drop_elapsed = 0.0
	var game_manager := get_node_or_null("/root/GameManager")
	if game_manager != null:
		game_manager.call("on_ball_pocketed", self)


## Ball-in-hand free placement: lets the cue ball pass through other balls
## while the player repositions it, and marks it visually as not-yet-placed.
func set_ghost_placement(enabled: bool) -> void:
	if enabled:
		freeze = true
		collision_layer = 0
		collision_mask = 0
	else:
		freeze = custom_solver_active
		collision_layer = 1
		collision_mask = 1 | 2
	if is_instance_valid(mesh_instance):
		mesh_instance.transparency = 0.55 if enabled else 0.0


func reset_to(pos: Vector3) -> void:
	pocketed = false
	physics_velocity = Vector3.ZERO
	physics_angular_velocity = Vector3.ZERO
	physics_resting = false
	_pocket_drop_elapsed = -1.0
	_pocket_entry_target = Vector3.ZERO
	freeze = custom_solver_active
	visible = true
	collision_layer = 1
	collision_mask = 1 | 2
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	global_position = pos
	rotation = Vector3.ZERO

func _process(delta: float) -> void:
	if _pocket_drop_elapsed < 0.0:
		return
	_pocket_drop_elapsed += delta
	var t := clampf(_pocket_drop_elapsed / _pocket_drop_duration, 0.0, 1.0)
	const ENTRY_FRACTION := 0.20
	if t <= ENTRY_FRACTION:
		global_position = _pocket_drop_start.lerp(_pocket_entry_target, t / ENTRY_FRACTION)
	else:
		var drop_t := (t - ENTRY_FRACTION) / (1.0 - ENTRY_FRACTION)
		# Accelerating descent begins only once the ball reaches the visible mouth.
		global_position = _pocket_entry_target.lerp(_pocket_drop_target, drop_t * drop_t)
	rotate_z(delta * 9.0)
	rotate_x(delta * 5.0)
	if t >= 1.0:
		_pocket_drop_elapsed = -1.0
		visible = false


func is_moving(threshold: float = 0.01) -> bool:
	if custom_solver_active:
		return physics_velocity.length() > threshold or physics_angular_velocity.length() > threshold
	return linear_velocity.length() > threshold or angular_velocity.length() > threshold


## These methods are the small bridge used by BilliardsPhysics.  Keeping the
## state here also makes legacy code that reads ball movement remain correct.
func set_custom_solver_active(active: bool) -> void:
	custom_solver_active = active
	if active:
		physics_velocity = linear_velocity
		physics_angular_velocity = angular_velocity
		linear_velocity = Vector3.ZERO
		angular_velocity = Vector3.ZERO
		freeze = true
	elif not pocketed:
		freeze = false
		linear_velocity = physics_velocity
		angular_velocity = physics_angular_velocity


func set_custom_state(position: Vector3, velocity: Vector3, angular_velocity_value: Vector3, resting: bool) -> void:
	physics_velocity = velocity
	physics_angular_velocity = angular_velocity_value
	physics_resting = resting
	global_position = position
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO


func custom_state() -> Dictionary:
	return {
		"position": global_position,
		"velocity": physics_velocity,
		"angular_velocity": physics_angular_velocity,
		"radius": RADIUS,
		"mass": MASS,
		"pocketed": pocketed,
		"sleeping": physics_resting,
	}


## Legacy engine-physics cloth model.  The custom solver owns this when active.
func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	if custom_solver_active or pocketed or freeze:
		return
	if abs(state.transform.origin.y - RADIUS) > RADIUS * 0.1:
		return

	var delta := state.step
	var lin := state.linear_velocity
	var ang := state.angular_velocity
	if lin.length() < SLEEP_LINEAR and ang.length() < SLEEP_ANGULAR:
		state.linear_velocity = Vector3(0.0, lin.y, 0.0)
		state.angular_velocity = Vector3.ZERO
		return

	var contact_offset := Vector3(0.0, -RADIUS, 0.0)
	var slip := lin + ang.cross(contact_offset)
	slip.y = 0.0
	if slip.length() > 0.02:
		var dv := -slip.normalized() * MU_SLIDE * GRAVITY * delta
		if dv.length() > slip.length():
			dv = -slip
		state.linear_velocity += dv
		var friction_force := dv * (MASS / delta)
		state.angular_velocity += contact_offset.cross(friction_force) * (delta / INERTIA)
	else:
		var horizontal := Vector3(lin.x, 0.0, lin.z)
		if horizontal.length() > 0.001:
			var roll_dv := -horizontal.normalized() * MU_ROLL * GRAVITY * delta
			if roll_dv.length() > horizontal.length():
				roll_dv = -horizontal
			state.linear_velocity += roll_dv

	if abs(ang.y) > 0.001:
		var spin_delta := MU_SPIN * GRAVITY / RADIUS * delta
		state.angular_velocity.y += -sign(ang.y) * min(spin_delta, abs(ang.y))
