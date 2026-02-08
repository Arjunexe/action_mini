extends StaticBody3D
@export var open_angle: float = 90.0
@export var animation_time: float = 0.6

# Internal state
var is_open: bool = false
var closed_rotation_y: float

func _ready() -> void:
	# Store the starting Y rotation of the MESH (the parent)
	# We use get_parent() because this script is on the StaticBody child & we have to check the if parent of the static body is a 3D object
	if get_parent() is Node3D:
		closed_rotation_y = get_parent().rotation_degrees.y

# This function is called by your Player's RayCast
func interact() -> void:
	if is_open:
		_animate_door(closed_rotation_y)
	else:
		_animate_door(closed_rotation_y + open_angle)
	is_open = not is_open

func _animate_door(target_angle: float) -> void:
	# Create a tween for smooth movement
	var tween: Tween = create_tween()
	# Ease Out means it slows down as it opens (feels heavy/realistic)
	tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	# IMPORTANT: We rotate 'get_parent()' so the visual mesh moves!
	# The StaticBody (this node) will move with it automatically.
	tween.tween_property(get_parent(), "rotation_degrees:y", target_angle, animation_time)
