extends CharacterBody3D

@export_group("Wander")
@export var movement_speed: float = 2.0
@export var wander_radius: float = 10.0

@export_group("Chase")
@export var chase_speed: float = 3.0
@export var detection_radius: float = 30.0
@export var sight_range: float = 25.0
@export var chase_giveup_time: float = 3.0
@export var los_check_interval: float = 0.3

@onready var nav_agent: NavigationAgent3D = $NavigationAgent3D
@onready var anim_player: AnimationPlayer = $monster/AnimationPlayer
@onready var detection_area: Area3D = $DetectionArea
@onready var los_ray: RayCast3D = $LOSRay
@onready var los_timer: Timer = $LOSCheckTimer

enum State {WANDER, ROAR, CHASE, CONFUSED}

const GRAVITY: float = 9.8
var state: State = State.WANDER
var player: CharacterBody3D
var player_detected: bool = false
var has_los: bool = false
var los_lost_time: float = 0.0
var has_roared: bool = false
var wander_direction: Vector3 = Vector3.ZERO
var wander_change_timer: float = 0.0
var _last_pos: Vector3 = Vector3.ZERO


func _ready() -> void:
	# 1. FORCE Player cache (error if missing)
	player = get_tree().get_first_node_in_group("player") as CharacterBody3D
	if not player:
		push_error("FIX: Player → Inspector → GROUPS → Add 'player'")
		print("Open Player scene → Inspector (right) → GROUPS button → + → 'player'")
		return
	print("1 PLAYER FOUND: ", player.name)
	
	# 2. FORCE Ray (ignore self, mask player)
	los_ray.add_exception(self )
	los_ray.collision_mask = 1
	
	# 3. FORCE Timer (no Inspector needed!)
	los_timer.wait_time = los_check_interval
	los_timer.autostart = false
	los_timer.one_shot = false
	print("2 TIMER: ", los_timer.wait_time, "s interval")
	
	# 4. FORCE Area3D (monitoring ON, mask Layer 1)
	detection_area.monitoring = true
	detection_area.monitorable = false
	detection_area.collision_mask = 1
	print("3 AREA monitoring=TRUE | mask=1 (Layer1)")
	
	# 5. FORCE Sphere radius (overrides Inspector)
	var shape_node: CollisionShape3D = detection_area.get_node("CollisionShape3D") as CollisionShape3D
	if shape_node and shape_node.shape is SphereShape3D:
		(shape_node.shape as SphereShape3D).radius = detection_radius
		print("4 SPHERE radius=%.1fm" % detection_radius)
	else:
		push_error("CollisionShape3D missing under DetectionArea!")
	
	# 6. Connect signals (safe, prints if fail)
	if not detection_area.body_entered.is_connected(_on_body_entered):
		detection_area.body_entered.connect(_on_body_entered)
	if not detection_area.body_exited.is_connected(_on_body_exited):
		detection_area.body_exited.connect(_on_body_exited)
	if not los_timer.timeout.is_connected(_on_los_check):
		los_timer.timeout.connect(_on_los_check)
	if not anim_player.animation_finished.is_connected(_on_animation_finished):
		anim_player.animation_finished.connect(_on_animation_finished)
	print("5 SIGNALS connected")
	
	# 7. Pick initial wander direction
	_pick_wander_direction()


func _physics_process(delta: float) -> void:
	# Nav safety
	if NavigationServer3D.map_get_iteration_id(get_world_3d().get_navigation_map()) == 0:
		return
	
	# **DEBUG PRINT EVERY 60 FRAMES** (1/sec, not spam)
	if Engine.get_process_frames() % 60 == 0:
		print("DEBUG | Detected:%s | LOS:%s | State:%s | Dist:%.1f" % [
			player_detected,
			has_los,
			["WANDER", "ROAR", "CHASE", "CONFUSED"][state],
			global_position.distance_to(player.global_position) if player else 999.0
		])
	
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
				print("→ ROAR (first time spotting player!)")
				state = State.ROAR
				anim_player.play("mutantRoar")
				has_roared = true
			else:
				print("→ CHASE (already roared, skip to chase)")
				state = State.CHASE
				los_lost_time = 0.0
				los_timer.start()
	# ROAR state waits for animation_finished signal (see _on_animation_finished)
	elif state == State.CHASE:
		# Use distance-based tracking during chase (more reliable than Area3D)
		var dist: float = global_position.distance_to(player.global_position)
		if dist > sight_range:
			los_lost_time += delta
			if los_lost_time > chase_giveup_time:
				print("→ CONFUSED (lost player)")
				state = State.CONFUSED
				los_lost_time = 0.0
				los_timer.stop()
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
				print("→ ROAR (spotted player while confused!)")
				state = State.ROAR
				anim_player.play("mutantRoar")
				has_roared = true
			else:
				print("→ CHASE (re-spotted, skip roar)")
				state = State.CHASE
				los_lost_time = 0.0
				los_timer.start()


func _on_body_entered(body: Node3D) -> void:
	if body == player:
		player_detected = true
		print("👀 PLAYER DETECTED! Timer START")


func _on_body_exited(body: Node3D) -> void:
	if body == player:
		player_detected = false


func _on_animation_finished(anim_name: String) -> void:
	if anim_name == "mutantRoar" and state == State.ROAR:
		print("→ CHASE (roar finished)")
		state = State.CHASE
		los_lost_time = 0.0
		los_timer.start()
	elif anim_name == "confused" and state == State.CONFUSED:
		print("→ WANDER (confused finished)")
		state = State.WANDER
		_pick_wander_direction() # Pick fresh direction for wander


func _on_los_check() -> void:
	if not player or not player_detected:
		return
	
	var dist: float = global_position.distance_to(player.global_position)
	if dist > sight_range:
		has_los = false
		return
	
	# Raycast
	var dir: Vector3 = (player.global_position - los_ray.global_position).normalized()
	los_ray.target_position = dir * sight_range
	los_ray.force_raycast_update()
	
	has_los = (not los_ray.is_colliding()) or (los_ray.get_collider() == player)
	
	var collider_name: String = "NONE"
	if los_ray.is_colliding():
		var collider: Object = los_ray.get_collider()
		if collider and collider is Node:
			collider_name = (collider as Node).name
	
	print("🔍 LOS | Dist:%.1f | Hit:%s | Visible:%s" % [dist, collider_name, has_los])

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
