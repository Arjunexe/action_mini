extends CharacterBody3D

@export_group("Wander")
@export var movement_speed: float = 2.0
@export var wander_radius: float = 10.0

@export_group("Chase")
@export var chase_speed: float = 3.0
@export var detection_radius: float = 30.0
@export var sight_range: float = 25.0
@export var chase_giveup_time: float = 3.0

@onready var nav_agent: NavigationAgent3D = $NavigationAgent3D
@onready var anim_player: AnimationPlayer = $monster/AnimationPlayer
@onready var detection_area: Area3D = $DetectionArea

enum State {WANDER, ROAR, CHASE, CONFUSED}

const GRAVITY: float = 9.8
var state: State = State.WANDER
var player: CharacterBody3D
var player_detected: bool = false
var los_lost_time: float = 0.0
var has_roared: bool = false
var wander_direction: Vector3 = Vector3.ZERO
var wander_change_timer: float = 0.0
var _last_pos: Vector3 = Vector3.ZERO


func _ready() -> void:
	player = get_tree().get_first_node_in_group("player") as CharacterBody3D
	if not player:
		push_error("Player not found! Add it to the 'player' group.")
		return
	
	# Detection area setup
	detection_area.monitoring = true
	detection_area.monitorable = false
	detection_area.collision_mask = 1
	
	# Force sphere radius from export
	var shape_node: CollisionShape3D = detection_area.get_node("CollisionShape3D") as CollisionShape3D
	if shape_node and shape_node.shape is SphereShape3D:
		(shape_node.shape as SphereShape3D).radius = detection_radius
	else:
		push_error("CollisionShape3D missing under DetectionArea!")
	
	# Connect signals
	if not detection_area.body_entered.is_connected(_on_body_entered):
		detection_area.body_entered.connect(_on_body_entered)
	if not detection_area.body_exited.is_connected(_on_body_exited):
		detection_area.body_exited.connect(_on_body_exited)
	if not anim_player.animation_finished.is_connected(_on_animation_finished):
		anim_player.animation_finished.connect(_on_animation_finished)
	
	_pick_wander_direction()


func _physics_process(delta: float) -> void:
	# Nav safety
	if NavigationServer3D.map_get_iteration_id(get_world_3d().get_navigation_map()) == 0:
		return
	
	# State tick (cheap)
	_handle_state_transitions(delta)
	
	# Gravity
	if not is_on_floor():
		velocity.y -= GRAVITY * delta
	
	# During ROAR: stop moving, face the player
	if state == State.ROAR:
		velocity.x = 0.0
		velocity.z = 0.0
		move_and_slide()
		if player:
			var look_pos: Vector3 = player.global_position
			look_pos.y = global_position.y
			look_at(look_pos, Vector3.UP)
		return
	
	# During CONFUSED: stop moving, play animation
	if state == State.CONFUSED:
		velocity.x = 0.0
		velocity.z = 0.0
		move_and_slide()
		return
	
	# Move
	var direction: Vector3
	var speed: float
	
	if state == State.CHASE:
		# During chase: move directly toward player in 3D (including climbing hills)
		direction = (player.global_position - global_position).normalized()
		speed = chase_speed
	else:
		# Wander: simple timer-based random direction (horizontal only)
		wander_change_timer -= delta
		if wander_change_timer <= 0:
			_pick_wander_direction()
		direction = wander_direction
		speed = movement_speed
	
	velocity.x = direction.x * speed
	velocity.z = direction.z * speed
	if state == State.CHASE:
		velocity.y = direction.y * speed # Climb toward player
	
	# Slope climbing: if we were stuck last frame, hop up
	var horizontal_moved: float = Vector2(global_position.x - _last_pos.x, global_position.z - _last_pos.z).length()
	if horizontal_moved < 0.01 and is_on_floor() and (velocity.x != 0.0 or velocity.z != 0.0):
		velocity.y = 5.0
		floor_snap_length = 0.0
		if state == State.WANDER:
			_pick_wander_direction()
	else:
		floor_snap_length = 0.1
	
	_last_pos = global_position
	move_and_slide()
	_update_animation_and_rotation()

func _handle_state_transitions(delta: float) -> void:
	if state == State.WANDER:
		if player_detected:
			if not has_roared and anim_player.has_animation("mutantRoar"):
				state = State.ROAR
				anim_player.play("mutantRoar")
				has_roared = true
			else:
				state = State.CHASE
				los_lost_time = 0.0
	# ROAR state waits for animation_finished signal
	elif state == State.CHASE:
		var dist: float = global_position.distance_to(player.global_position)
		if dist > sight_range:
			los_lost_time += delta
			if los_lost_time > chase_giveup_time:
				state = State.CONFUSED
				los_lost_time = 0.0
				if anim_player.has_animation("confused"):
					anim_player.play("confused")
				else:
					push_warning("confused animation not found — skipping to WANDER")
					state = State.WANDER
		else:
			los_lost_time = 0.0
	elif state == State.CONFUSED:
		if player_detected:
			if not has_roared and anim_player.has_animation("mutantRoar"):
				state = State.ROAR
				anim_player.play("mutantRoar")
				has_roared = true
			else:
				state = State.CHASE
				los_lost_time = 0.0


func _on_body_entered(body: Node3D) -> void:
	if body == player:
		player_detected = true


func _on_body_exited(body: Node3D) -> void:
	if body == player:
		player_detected = false


func _on_animation_finished(anim_name: String) -> void:
	if anim_name == "mutantRoar" and state == State.ROAR:
		state = State.CHASE
		los_lost_time = 0.0
	elif anim_name == "confused" and state == State.CONFUSED:
		state = State.WANDER
		_pick_wander_direction()


func _update_animation_and_rotation() -> void:
	# Only rotate if we are actually moving
	var horizontal_velocity: Vector3 = velocity
	horizontal_velocity.y = 0 # Ignore falling speed for rotation
	
	if horizontal_velocity.length() > 0.1:
		var target_anim: String = ""
		if state == State.CHASE and anim_player.has_animation("monsterRun"):
			target_anim = "monsterRun"
		elif anim_player.has_animation("mutantWalking"):
			target_anim = "mutantWalking"
		
		if target_anim != "" and anim_player.current_animation != target_anim:
			anim_player.play(target_anim)
		
		# Look at where we are going + current position
		var target_look: Vector3 = global_position + horizontal_velocity
		look_at(target_look, Vector3.UP)
	else:
		if anim_player.is_playing():
			anim_player.stop()


func _pick_wander_direction() -> void:
	wander_direction = Vector3(randf_range(-1, 1), 0, randf_range(-1, 1)).normalized()
	wander_change_timer = randf_range(3.0, 5.0)
