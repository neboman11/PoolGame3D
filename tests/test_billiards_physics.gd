class_name BilliardsPhysicsTests
extends RefCounted

## Deterministic calibration tests for the pure-state BilliardsPhysics adapter.
##
## Thin aggregator: checks the adapter is available, then runs the four
## category suites (rollout, collisions, break, pockets) and combines their
## pass/fail results. See billiards_physics_test_harness.gd for the shared
## world helpers and tests/test_billiards_physics_*.gd for the cases themselves.

const HARNESS := preload("res://tests/billiards_physics_test_harness.gd")
const RolloutTests := preload("res://tests/test_billiards_physics_rollout.gd")
const CollisionsTests := preload("res://tests/test_billiards_physics_collisions.gd")
const BreakTests := preload("res://tests/test_billiards_physics_break.gd")
const PocketsTests := preload("res://tests/test_billiards_physics_pockets.gd")


func run() -> int:
	var probe := HARNESS.new()
	var prototype_or_error: Variant = probe._make_world(probe._base_config())
	if prototype_or_error is String:
		printerr("BilliardsPhysics test harness cannot run: %s" % prototype_or_error)
		printerr("Expected deterministic adapter: configure(Dictionary), add_ball(id, position, velocity, radius, mass), step(delta), snapshot().")
		return 2
	probe._free_world(prototype_or_error)

	var suites: Array = [RolloutTests.new(), CollisionsTests.new(), BreakTests.new(), PocketsTests.new()]
	var passed := 0
	var failed: Array[String] = []
	for suite in suites:
		suite.run()
		var suite_results: Dictionary = suite.results()
		passed += int(suite_results["passed"])
		failed.append_array(suite_results["failed"])

	if failed.is_empty():
		print("PASS: %d deterministic billiards physics checks" % passed)
		return 0

	printerr("FAIL: %d/%d deterministic billiards physics checks failed" % [failed.size(), passed + failed.size()])
	for failure in failed:
		printerr("  - %s" % failure)
	return 1
