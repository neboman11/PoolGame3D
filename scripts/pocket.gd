extends Area3D

## Legacy visual/sensor node. Accurate capture is evaluated by BilliardsPhysics
## using pocket throat, shelf, speed, and approach direction. The trigger can be
## enabled for isolated editor experiments, but is deliberately off in a match.

@export var legacy_trigger_enabled := false

func _ready() -> void:
	if legacy_trigger_enabled:
		body_entered.connect(_on_body_entered)

func _on_body_entered(body: Node3D) -> void:
	if body.has_method("pocket"):
		body.pocket()
