extends Control

@onready var rack_tightness_slider: HSlider = $CenterContainer/VBoxContainer/RackTightnessRow/RackTightnessSlider
@onready var rack_tightness_value_label: Label = $CenterContainer/VBoxContainer/RackTightnessRow/RackTightnessValueLabel
@onready var camera_sensitivity_slider: HSlider = $CenterContainer/VBoxContainer/CameraSensitivityRow/CameraSensitivitySlider
@onready var camera_sensitivity_value_label: Label = $CenterContainer/VBoxContainer/CameraSensitivityRow/CameraSensitivityValueLabel
@onready var precision_aim_slider: HSlider = $CenterContainer/VBoxContainer/PrecisionAimRow/PrecisionAimSlider
@onready var precision_aim_value_label: Label = $CenterContainer/VBoxContainer/PrecisionAimRow/PrecisionAimValueLabel
@onready var aim_guide_check: CheckBox = $CenterContainer/VBoxContainer/AimGuideRow/AimGuideCheck
@onready var extended_aim_preview_check: CheckBox = $CenterContainer/VBoxContainer/ExtendedAimPreviewRow/ExtendedAimPreviewCheck
@onready var back_button: Button = $CenterContainer/VBoxContainer/BackButton

func _ready() -> void:
	rack_tightness_slider.min_value = 0.0
	rack_tightness_slider.max_value = 1.0
	rack_tightness_slider.step = 0.05
	rack_tightness_slider.value = Settings.rack_tightness
	_update_rack_tightness_label(Settings.rack_tightness)
	rack_tightness_slider.value_changed.connect(_on_rack_tightness_changed)

	camera_sensitivity_slider.min_value = Settings.CAMERA_SENSITIVITY_MIN
	camera_sensitivity_slider.max_value = Settings.CAMERA_SENSITIVITY_MAX
	camera_sensitivity_slider.step = 0.05
	camera_sensitivity_slider.value = Settings.camera_sensitivity
	_update_camera_sensitivity_label(Settings.camera_sensitivity)
	camera_sensitivity_slider.value_changed.connect(_on_camera_sensitivity_changed)

	precision_aim_slider.min_value = Settings.PRECISION_AIM_SENSITIVITY_MIN
	precision_aim_slider.max_value = Settings.PRECISION_AIM_SENSITIVITY_MAX
	precision_aim_slider.step = 0.01
	precision_aim_slider.value = Settings.precision_aim_sensitivity
	_update_precision_aim_label(Settings.precision_aim_sensitivity)
	precision_aim_slider.value_changed.connect(_on_precision_aim_changed)

	aim_guide_check.button_pressed = Settings.aim_guide_default
	aim_guide_check.toggled.connect(_on_aim_guide_toggled)

	extended_aim_preview_check.button_pressed = Settings.extended_aim_preview
	extended_aim_preview_check.toggled.connect(_on_extended_aim_preview_toggled)

	back_button.pressed.connect(_on_back_pressed)

func _on_rack_tightness_changed(value: float) -> void:
	Settings.rack_tightness = value
	_update_rack_tightness_label(value)
	Settings.save_settings()

func _on_camera_sensitivity_changed(value: float) -> void:
	Settings.camera_sensitivity = value
	_update_camera_sensitivity_label(value)
	Settings.save_settings()

func _on_precision_aim_changed(value: float) -> void:
	Settings.precision_aim_sensitivity = value
	_update_precision_aim_label(value)
	Settings.save_settings()

func _on_aim_guide_toggled(pressed: bool) -> void:
	Settings.aim_guide_default = pressed
	Settings.save_settings()

func _on_extended_aim_preview_toggled(pressed: bool) -> void:
	Settings.extended_aim_preview = pressed
	Settings.save_settings()

func _update_rack_tightness_label(value: float) -> void:
	var descriptor := "Tight"
	if value >= 0.66:
		descriptor = "Loose"
	elif value >= 0.33:
		descriptor = "Realistic"
	rack_tightness_value_label.text = "%s (%d%%)" % [descriptor, roundi(value * 100)]

func _update_camera_sensitivity_label(value: float) -> void:
	camera_sensitivity_value_label.text = "%.2fx" % value

func _update_precision_aim_label(value: float) -> void:
	precision_aim_value_label.text = "%d%%" % roundi(value * 100)

func _on_back_pressed() -> void:
	GameManager.goto_menu()
