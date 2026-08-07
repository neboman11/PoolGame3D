extends Node
## Autoload "TextureGen".
## Generates every texture used by the game procedurally at runtime.
## No external image files are loaded anywhere in this project.

var ball_texture_cache: Dictionary = {}
var _felt_texture: ImageTexture
var _wood_texture: ImageTexture
var _rubber_texture: ImageTexture
var _pocket_texture: ImageTexture
var _spin_selector_texture: ImageTexture

const BALL_COLORS := {
	1: Color(0.95, 0.78, 0.05),   # yellow
	2: Color(0.06, 0.18, 0.68),   # blue
	3: Color(0.80, 0.06, 0.06),   # red
	4: Color(0.35, 0.06, 0.55),   # purple
	5: Color(0.95, 0.45, 0.02),   # orange
	6: Color(0.03, 0.42, 0.15),   # green
	7: Color(0.42, 0.06, 0.06),   # maroon
	8: Color(0.04, 0.04, 0.04),   # black
}

# Small bitmap glyphs are deliberately baked directly into the ball texture.
# Rendering a Label through a temporary viewport left an opaque viewport
# rectangle on some renderers, which read as a black bar instead of a number.
const NUMBER_GLYPHS := {
	"0": ["01110", "10001", "10011", "10101", "11001", "10001", "01110"],
	"1": ["00100", "01100", "00100", "00100", "00100", "00100", "01110"],
	"2": ["01110", "10001", "00001", "00010", "00100", "01000", "11111"],
	"3": ["11110", "00001", "00001", "01110", "00001", "00001", "11110"],
	"4": ["00010", "00110", "01010", "10010", "11111", "00010", "00010"],
	"5": ["11111", "10000", "10000", "11110", "00001", "00001", "11110"],
	"6": ["01110", "10000", "10000", "11110", "10001", "10001", "01110"],
	"7": ["11111", "00001", "00010", "00100", "01000", "01000", "01000"],
	"8": ["01110", "10001", "10001", "01110", "10001", "10001", "01110"],
	"9": ["01110", "10001", "10001", "01111", "00001", "00001", "01110"],
}

func get_ball_color(number: int) -> Color:
	var base_num := number
	if number > 8:
		base_num = number - 8
	return BALL_COLORS.get(base_num, Color.WHITE)

func is_stripe(number: int) -> bool:
	return number >= 9 and number <= 15

## ---------------------------------------------------------------------
## Ball textures (solid / stripe patterns + baked number glyph)
## ---------------------------------------------------------------------

func preload_all_ball_textures() -> void:
	for n in range(0, 16):
		if not ball_texture_cache.has(n):
			ball_texture_cache[n] = await generate_ball_texture(n)

func get_ball_texture(number: int) -> ImageTexture:
	return ball_texture_cache.get(number, null)

func generate_ball_texture(number: int) -> ImageTexture:
	var size := 256
	var img := Image.create_empty(size, size, false, Image.FORMAT_RGBA8)

	if number == 0:
		img = _create_cue_ball_albedo(size)
		var tex := ImageTexture.create_from_image(img)
		ball_texture_cache[0] = tex
		return tex

	var color := get_ball_color(number)
	var cream := Color(0.94, 0.91, 0.83)
	var stripe := is_stripe(number)

	for y in range(size):
		var v: float = float(y) / size
		for x in range(size):
			var c := color
			if stripe and (v < 0.30 or v > 0.70):
				c = cream
			img.set_pixel(x, y, c)

	# Number disc(s) - two opposite patches so the digit is visible from
	# most rotations while the ball rolls.
	var patch_centers := [Vector2(0.25, 0.5), Vector2(0.75, 0.5)]
	var radius: float = size * 0.15
	for center in patch_centers:
		var cx: float = center.x * size
		var cy: float = center.y * size
		for y in range(int(cy - radius), int(cy + radius)):
			for x in range(int(cx - radius), int(cx + radius)):
				if x < 0 or y < 0 or x >= size or y >= size:
					continue
				var d := Vector2(x - cx, y - cy).length()
				if d <= radius:
					img.set_pixel(x, y, cream)

	for center in patch_centers:
		_draw_number_glyph(img, center * size, radius, number)

	var out_tex := ImageTexture.create_from_image(img)
	ball_texture_cache[number] = out_tex
	return out_tex


func _create_cue_ball_albedo(size: int) -> Image:
	# This is shared by the 3D cue ball and the spin selector; lighting is added
	# by their respective renderers rather than baked into the albedo.
	var img := Image.create_empty(size, size, false, Image.FORMAT_RGBA8)
	var noise := FastNoiseLite.new()
	noise.seed = 42
	noise.frequency = 0.15
	for y in range(size):
		for x in range(size):
			var n: float = noise.get_noise_2d(x, y) * 0.015
			img.set_pixel(x, y, Color(0.94 + n, 0.93 + n, 0.88 + n))
	return img


func _draw_number_glyph(img: Image, center: Vector2, patch_radius: float, number: int) -> void:
	var digits := str(number)
	var glyph_scale := maxf(3.0, patch_radius * (0.145 if digits.length() == 1 else 0.105))
	var glyph_width := 5.0 * glyph_scale
	var digit_gap := glyph_scale * 0.7
	var total_width := glyph_width * digits.length() + digit_gap * (digits.length() - 1)
	var start_x := center.x - total_width * 0.5
	var start_y := center.y - 3.5 * glyph_scale
	for digit_index in range(digits.length()):
		var glyph: Array = NUMBER_GLYPHS.get(digits[digit_index], NUMBER_GLYPHS["0"])
		var digit_x := start_x + digit_index * (glyph_width + digit_gap)
		for row in range(glyph.size()):
			var glyph_row: String = glyph[row]
			for column in range(glyph_row.length()):
				if glyph_row[column] == "1":
					_draw_glyph_cell(img, Vector2(digit_x + column * glyph_scale, start_y + row * glyph_scale), glyph_scale)


func _draw_glyph_cell(img: Image, top_left: Vector2, glyph_scale: float) -> void:
	var edge_softness := maxf(1.0, glyph_scale * 0.18)
	var left := floori(top_left.x)
	var top := floori(top_left.y)
	var right := ceili(top_left.x + glyph_scale)
	var bottom := ceili(top_left.y + glyph_scale)
	for y in range(top, bottom):
		for x in range(left, right):
			if x < 0 or y < 0 or x >= img.get_width() or y >= img.get_height():
				continue
			var edge_distance := minf(minf(x - left, right - 1 - x), minf(y - top, bottom - 1 - y))
			var shade := lerpf(0.025, 0.085, clampf(edge_distance / edge_softness, 0.0, 1.0))
			img.set_pixel(x, y, Color(shade, shade, shade, 1.0))


func get_spin_selector_texture(size: int = 192) -> ImageTexture:
	if _spin_selector_texture and _spin_selector_texture.get_width() == size:
		return _spin_selector_texture
	var cue_albedo := _create_cue_ball_albedo(size)
	var selector := Image.create_empty(size, size, false, Image.FORMAT_RGBA8)
	var light_direction := Vector3(-0.48, 0.58, 0.66).normalized()
	for y in range(size):
		for x in range(size):
			var local := Vector2((float(x) + 0.5) / size * 2.0 - 1.0, (float(y) + 0.5) / size * 2.0 - 1.0)
			var radius_squared := local.length_squared()
			if radius_squared > 1.0:
				selector.set_pixel(x, y, Color.TRANSPARENT)
				continue
			var normal := Vector3(local.x, -local.y, sqrt(maxf(0.0, 1.0 - radius_squared))).normalized()
			var diffuse := maxf(normal.dot(light_direction), 0.0)
			var view_reflection := maxf((-light_direction).reflect(normal).dot(Vector3.FORWARD), 0.0)
			var highlight := pow(view_reflection, 34.0) * 0.32
			var rim_shadow := smoothstep(0.78, 1.0, sqrt(radius_squared)) * 0.18
			var light_amount := 0.28 + diffuse * 0.72 - rim_shadow
			var albedo := cue_albedo.get_pixel(x, y)
			selector.set_pixel(x, y, Color(
				clampf(albedo.r * light_amount + highlight, 0.0, 1.0),
				clampf(albedo.g * light_amount + highlight, 0.0, 1.0),
				clampf(albedo.b * light_amount + highlight, 0.0, 1.0),
				1.0
			))
	_spin_selector_texture = ImageTexture.create_from_image(selector)
	return _spin_selector_texture

## ---------------------------------------------------------------------
## Table / environment textures
## ---------------------------------------------------------------------

func generate_felt_texture(size: int = 512) -> ImageTexture:
	if _felt_texture:
		return _felt_texture
	var img := Image.create_empty(size, size, false, Image.FORMAT_RGB8)
	var noise := FastNoiseLite.new()
	noise.seed = 1337
	noise.frequency = 0.05
	noise.fractal_octaves = 4
	var weave := FastNoiseLite.new()
	weave.seed = 77
	weave.frequency = 0.9
	var base := Color(0.018, 0.255, 0.085)
	for y in range(size):
		for x in range(size):
			var n: float = noise.get_noise_2d(x, y) * 0.05
			var w: float = weave.get_noise_2d(x, y) * 0.02
			img.set_pixel(x, y, Color(base.r + n + w, base.g + n + w, base.b + n + w))
	_felt_texture = ImageTexture.create_from_image(img)
	return _felt_texture

func generate_wood_texture(size: int = 512) -> ImageTexture:
	if _wood_texture:
		return _wood_texture
	var img := Image.create_empty(size, size, false, Image.FORMAT_RGB8)
	var noise := FastNoiseLite.new()
	noise.seed = 99
	noise.frequency = 0.02
	var grain := FastNoiseLite.new()
	grain.seed = 5
	grain.frequency = 0.25
	var dark := Color(0.050, 0.015, 0.008)
	var light := Color(0.220, 0.055, 0.020)
	for y in range(size):
		for x in range(size):
			var stripe_n: float = noise.get_noise_2d(x * 0.2, y * 2.0)
			var g: float = grain.get_noise_2d(x, y * 0.3) * 0.08
			var t: float = clamp((stripe_n + 1.0) * 0.5 + g, 0.0, 1.0)
			img.set_pixel(x, y, dark.lerp(light, t))
	_wood_texture = ImageTexture.create_from_image(img)
	return _wood_texture

func generate_rubber_texture(size: int = 256) -> ImageTexture:
	if _rubber_texture:
		return _rubber_texture
	var img := Image.create_empty(size, size, false, Image.FORMAT_RGB8)
	var noise := FastNoiseLite.new()
	noise.seed = 21
	noise.frequency = 0.1
	var base := Color(0.012, 0.185, 0.055)
	for y in range(size):
		for x in range(size):
			var n: float = noise.get_noise_2d(x, y) * 0.03
			img.set_pixel(x, y, Color(base.r + n, base.g + n, base.b + n))
	_rubber_texture = ImageTexture.create_from_image(img)
	return _rubber_texture

func generate_pocket_texture(size: int = 128) -> ImageTexture:
	if _pocket_texture:
		return _pocket_texture
	var img := Image.create_empty(size, size, false, Image.FORMAT_RGB8)
	img.fill(Color(0.01, 0.01, 0.01))
	_pocket_texture = ImageTexture.create_from_image(img)
	return _pocket_texture
