class_name TextureGeneratorTests
extends RefCounted

## Regression checks for procedural UI/ball textures. These run without a
## renderer so texture defects are caught before a visual smoke pass.
const TEXTURE_GENERATOR := preload("res://scripts/texture_generator.gd")

var _passed := 0
var _failed: Array[String] = []


func run() -> int:
	_run_case("ball numbers are glyphs, not viewport rectangles", _test_number_glyph_coverage)
	_run_case("spin selector is an opaque shaded cue-ball circle", _test_spin_selector_circle)
	if _failed.is_empty():
		print("PASS: %d texture generator checks" % _passed)
		return 0
	printerr("FAIL: %d/%d texture generator checks failed" % [_failed.size(), _passed + _failed.size()])
	for failure in _failed:
		printerr(" - %s" % failure)
	return 1


func _run_case(label: String, test: Callable) -> void:
	var error: String = test.call()
	if error.is_empty():
		_passed += 1
		print("PASS: %s" % label)
	else:
		_failed.append("%s: %s" % [label, error])


func _test_number_glyph_coverage() -> String:
	var generator: Node = TEXTURE_GENERATOR.new()
	var texture: ImageTexture = generator.generate_ball_texture(1)
	var image := texture.get_image()
	var dark_pixels := 0
	for y in range(92, 164):
		for x in range(28, 100):
			var color := image.get_pixel(x, y)
			if color.a > 0.95 and color.get_luminance() < 0.20:
				dark_pixels += 1
	generator.free()
	if dark_pixels < 40:
		return "the 1-ball number patch did not contain a readable dark glyph"
	if dark_pixels > 900:
		return "the 1-ball number patch contains an opaque rectangle instead of a glyph"
	return ""


func _test_spin_selector_circle() -> String:
	var generator: Node = TEXTURE_GENERATOR.new()
	var texture: ImageTexture = generator.get_spin_selector_texture(128)
	var image := texture.get_image()
	var center := image.get_pixel(64, 64)
	var corner := image.get_pixel(0, 0)
	var rim := image.get_pixel(123, 64)
	generator.free()
	if corner.a > 0.01:
		return "spin selector must be circular, not a square texture"
	if center.a < 0.99 or rim.a < 0.99:
		return "spin selector circle is unexpectedly transparent"
	if center.get_luminance() <= rim.get_luminance() + 0.12:
		return "spin selector lacks the cue ball's spherical shading"
	return ""
