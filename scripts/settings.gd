extends Node

## Persisted user settings (rack tightness, camera sensitivity, precision aim
## sensitivity, aim guide default). Uses ConfigFile against user:// -- Godot
## resolves that to the right per-platform app data directory on its own, so
## the same path/API persists correctly on both desktop and Android with no
## branching here.

const SETTINGS_PATH := "user://settings.cfg"
const SECTION := "gameplay"

const RACK_TIGHTNESS_DEFAULT: float = 0.4
const CAMERA_SENSITIVITY_DEFAULT: float = 1.0
const PRECISION_AIM_SENSITIVITY_DEFAULT: float = 0.2
const AIM_GUIDE_DEFAULT: bool = false
const EXTENDED_AIM_PREVIEW_DEFAULT: bool = false

const CAMERA_SENSITIVITY_MIN: float = 0.5
const CAMERA_SENSITIVITY_MAX: float = 2.0

## Lower = finer/slower precision-aim drag. Bounds keep it strictly slower
## than full-speed drag (< 1.0) while never reaching a dead stick (> 0.0).
const PRECISION_AIM_SENSITIVITY_MIN: float = 0.05
const PRECISION_AIM_SENSITIVITY_MAX: float = 0.5

var rack_tightness: float = RACK_TIGHTNESS_DEFAULT
var camera_sensitivity: float = CAMERA_SENSITIVITY_DEFAULT
var precision_aim_sensitivity: float = PRECISION_AIM_SENSITIVITY_DEFAULT
var aim_guide_default: bool = AIM_GUIDE_DEFAULT
var extended_aim_preview: bool = EXTENDED_AIM_PREVIEW_DEFAULT

func _ready() -> void:
	load_settings()

func load_settings() -> void:
	var config := ConfigFile.new()
	if config.load(SETTINGS_PATH) != OK:
		return # no file yet (first run) or unreadable -- keep defaults
	rack_tightness = clampf(config.get_value(SECTION, "rack_tightness", RACK_TIGHTNESS_DEFAULT), 0.0, 1.0)
	camera_sensitivity = clampf(config.get_value(SECTION, "camera_sensitivity", CAMERA_SENSITIVITY_DEFAULT), CAMERA_SENSITIVITY_MIN, CAMERA_SENSITIVITY_MAX)
	precision_aim_sensitivity = clampf(config.get_value(SECTION, "precision_aim_sensitivity", PRECISION_AIM_SENSITIVITY_DEFAULT), PRECISION_AIM_SENSITIVITY_MIN, PRECISION_AIM_SENSITIVITY_MAX)
	aim_guide_default = config.get_value(SECTION, "aim_guide_default", AIM_GUIDE_DEFAULT)
	extended_aim_preview = config.get_value(SECTION, "extended_aim_preview", EXTENDED_AIM_PREVIEW_DEFAULT)

func save_settings() -> void:
	var config := ConfigFile.new()
	config.set_value(SECTION, "rack_tightness", rack_tightness)
	config.set_value(SECTION, "camera_sensitivity", camera_sensitivity)
	config.set_value(SECTION, "precision_aim_sensitivity", precision_aim_sensitivity)
	config.set_value(SECTION, "aim_guide_default", aim_guide_default)
	config.set_value(SECTION, "extended_aim_preview", extended_aim_preview)
	config.save(SETTINGS_PATH)
