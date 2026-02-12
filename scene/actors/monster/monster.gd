extends CharacterBody3D

@export_group("Wander")
@export var movement_speed: float = 1.3
@export var wander_radius: float = 10.0

@export_group("Chase")
@export var chase_speed: float = 2.5
@export var detection_radius: float = 30.0
@export var sight_range: float = 25.0
@export var chase_giveup_time: float = 3.0
@export var los_check_interval: float = 0.3

@onready var nav_agent: NavigationAgent3D = $NavigationAgent3D
@onready var anim_player: AnimationPlayer = $monster/AnimationPlayer
@onready var detection_area: Area3D = $DetectionArea
@onready var los_ray: RayCast3D = $LOSRay
@onready var los_timer: Timer = $LOSCheckTimer

enum State { WANDER, CHASE }

var state: State = State.WANDER
var player: CharacterBody3D
var player_detected: bool = false
var has_los: bool = false
var los_lost_time: float = 0.0


func _ready() -> void:
	# 1. FORCE Player cache (error if missing)
	player = get_tree().get_first_node_in_group("player") as CharacterBody3D
	if not player:
		push_error("🚫 FIX: Player → Inspector → GROUPS → Add 'player'")
		print("💡 Open Player scene → Inspector (right) → GROUPS button → + → 'player'")
		return
	print("✅1 PLAYER FOUND: ", player.name)
	
	# 2. FORCE Ray (ignore self, mask player)
	los_ray.add_exception(self)
	los_ray.collision_mask = 1
	
	# 3. FORCE Timer (no Inspector needed!)
	los_timer.wait_time = los_check_interval
	los_timer.autostart = false
	los_timer.one_shot = false
	print("✅2 TIMER: ", los_timer.wait_time, "s interval")
	
	# 4. FORCE Area3D (monitoring ON, mask Layer 1)
	detection_area.monitoring = true
	detection_area.monitorable = false
	detection_area.collision_mask = 1
	print("✅3 AREA monitoring=TRUE | mask=1 (Layer1)")
	
	# 5. FORCE Sphere radius (overrides Inspector)
	var shape_node: CollisionShape3D = detection_area.get_node("CollisionShape3D") as CollisionShape3D
	if shape_node and shape_node.shape is SphereShape3D:
		(shape_node.shape as SphereShape3D).radius = detection_radius
		print("✅4 SPHERE radius=%.1fm" % detection_radius)
	else:
		push_error("🚫 CollisionShape3D missing under DetectionArea!")
	
	# 6. Connect signals (safe, prints if fail)
	if not detection_area.body_entered.is_connected(_on_body_entered):
		detection_area.body_entered.connect(_on_body_entered)
	if not detection_area.body_exited.is_connected(_on_body_exited):
		detection_area.body_exited.connect(_on_body_exited)
	if not los_timer.timeout.is_connected(_on_los_check):
		los_timer.timeout.connect(_on_los_check)
	print("✅5 SIGNALS connected")


func _physics_process(delta: float) -> void:
	# Nav safety
	if NavigationServer3D.map_get_iteration_id(get_world_3d().get_navigation_map()) == 0:
		return
	
	# **DEBUG PRINT EVERY 60 FRAMES** (1/sec, not spam)
	if Engine.get_process_frames() % 60 == 0:
		print("DEBUG | Detected:%s | LOS:%s | State:%s | Dist:%.1f" % [
			player_detected,
			has_los,
			"CHASE" if state == State.CHASE else "WANDER",
			global_position.distance_to(player.global_position) if player else 999
		])
	
	# State tick (cheap)
	_handle_state_transitions(delta)
	
	# Chase target
	if state == State.CHASE:
		nav_agent.target_position = player.global_position
	
	# Wander target guard
	if nav_agent.is_navigation_finished() and state == State.WANDER:
		_set_random_target()
	
	# Move
	var curr: Vector3 = global_position
	var next: Vector3 = nav_agent.get_next_path_position()
	velocity = (next - curr).normalized() * (chase_speed if state == State.CHASE else movement_speed)
	move_and_slide()
	_update_animation_and_rotation()


func _handle_state_transitions(delta: float) -> void:
	if state == State.WANDER:
		if player_detected:
			print("🧠 → CHASE (proximity)")
			state = State.CHASE
			los_lost_time = 0.0
			los_timer.start()
	elif state == State.CHASE:
		if not player_detected:
			los_lost_time += delta
			if los_lost_time > chase_giveup_time:
				print("🧠 → WANDER (lost)")
				state = State.WANDER
				los_timer.stop()


func _on_body_entered(body: Node3D) -> void:
	print("🎉 ENTERED: ", body.name if body else "null")
	if body == player:
		player_detected = true
		print("👀 PLAYER DETECTED! Timer START")


func _on_body_exited(body: Node3D) -> void:
	print("🚪 EXITED: ", body.name if body else "null")
	if body == player:
		player_detected = false
		print("😴 LOST PLAYER")


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
	if velocity.length() > 0.1:
		if anim_player.has_animation("mutantWalking"):
			anim_player.play("mutantWalking")
		var target: Vector3 = global_position + velocity
		target.y = global_position.y
		look_at(target, Vector3.UP)
	else:
		anim_player.stop()


func _set_random_target() -> void:
	var dir: Vector3 = Vector3(randf_range(-1, 1), 0, randf_range(-1, 1)).normalized()
	var pos: Vector3 = global_position + dir * wander_radius
	var closest: Vector3 = NavigationServer3D.map_get_closest_point(
		get_world_3d().get_navigation_map(), 
		pos
	)
	nav_agent.target_position = closest
