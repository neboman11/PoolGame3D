# Headless billiards physics checks

Run the deterministic calibration suite from the repository root:

```sh
godot --headless --path . --script tests/run_headless.gd
```

The suite uses no addons, scenes, rendering, or project autoloads. Until the
physics core is present it exits with code `2` and explains the missing adapter.
Once present, assertion failures exit with code `1`.

## Pure-state test adapter

`BilliardsPhysics` may remain a `Node` for gameplay. To make its numerical
behavior testable without a live scene, expose these synchronous methods as
aliases or a small companion adapter:

```gdscript
func configure(config: Dictionary) -> void
func add_ball(id: int, position: Vector3, velocity := Vector3.ZERO,
        radius := 0.1, mass := 0.17) -> void
func step(delta: float) -> void
func snapshot() -> Dictionary
```

`snapshot()` must be read-only and return either a dictionary keyed by ball id,
or `{ "balls": ... }`. Each ball state must contain `position` (or
`global_position`) and `velocity` (or `linear_velocity`), both `Vector3`.

The runner locates `class_name BilliardsPhysics` dynamically, without a static
preload or a dependency on scene startup order.

## Calibrations covered

- Rolling friction: a 1 m/s ball with `mu = 0.016` on `g = 9.8` should have
  roughly 0.6864 m/s remaining after two seconds and travel about 1.6864 m.
- Equal-mass elastic head-on contact transfers cue velocity to the object ball.
- A 30-degree cut preserves momentum and produces the expected velocity split.
- A finite 31-degree rotated cushion reflects a ball along its rotated face
  normal, while an approach-gated pocket ignores outbound throat traffic.
- An actual `TableProfile.get_pocket_capture_descriptors()` entry captures an
  inward ball at its center, protecting the production visible-drop handoff.
- Two independently seeded fixed-step runs produce equal snapshots, and reading
  a snapshot does not mutate the world.

`test_eight_ball_rules.gd` additionally checks group assignment,
wrong-first-contact fouls, scratches and ball-in-hand, and both legal and early
8-ball outcomes through the rules engine's public event API.
