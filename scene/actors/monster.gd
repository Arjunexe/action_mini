extends CharacterBody3D

@export var movement_speed: float = 1.3
@export var wander_radius: float = 10.0

@onready var nav_agent: NavigationAgent3D = $NavigationAgent3D
# ADJUST THIS PATH: Make sure this points to your actual AnimationPlayer node
@onready var anim_player: AnimationPlayer = $monster/AnimationPlayer

func _physics_process(_delta: float) -> void:
	# 1. Map Synchronization Check
	if NavigationServer3D.map_get_iteration_id(get_world_3d().get_navigation_map()) == 0:
		return 

	# 2. Get new target if finished
	if nav_agent.is_navigation_finished():
		_set_random_target()
		# If we are waiting for a new path, we might want to idle
		anim_player.play("mutantWalking") # Replace with "RESET" or "idle" if you have one
		return

	# 3. Calculate Movement
	var current_agent_position: Vector3 = global_position
	var next_path_position: Vector3 = nav_agent.get_next_path_position()
	var new_velocity: Vector3 = (next_path_position - current_agent_position).normalized() * movement_speed
	
	velocity = new_velocity
	
	# 4. Move and Animate
	move_and_slide()
	
	_update_animation_and_rotation()

func _update_animation_and_rotation() -> void:
	# Only rotate and animate if we are actually moving
	if velocity.length() > 0.1:
		# ANIMATION: Play the run loop
		anim_player.play("mutantWalking")
		
		# ROTATION: Look where we are going
		# We add our current position to the velocity to get a point ahead of us
		var look_target := global_position + velocity
		# Ensure we look horizontally only (keep Y the same) to avoid tilting into the ground
		look_target.y = global_position.y
		
		look_at(look_target, Vector3.UP)
	else:
		# If we aren't moving fast enough, play idle
		if anim_player.has_animation("mutantWalking"):
			anim_player.play("mutantWalking")
		else:
			anim_player.stop()

func _set_random_target() -> void:
	var random_dir: Vector3 = Vector3(
		randf_range(-1.0, 1.0), 
		0.0, 
		randf_range(-1.0, 1.0)
	).normalized()
	
	var random_pos: Vector3 = global_position + (random_dir * wander_radius)
	var map: RID = get_world_3d().get_navigation_map()
	var closest_point: Vector3 = NavigationServer3D.map_get_closest_point(map, random_pos)
	
	nav_agent.target_position = closest_point
