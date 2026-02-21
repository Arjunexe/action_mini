extends CharacterBody3D

# ============================================================================
# EXPORTS - Tweak these values in the inspector
# ============================================================================
@export_group("Movement")
@export var move_speed: float = 2.0
@export var sprint_multiplier: float = 2.2
@export var jump_force: float = 2.5
@export var rotation_speed: float = 12.0
@export var jump_delay: float = 0.5 # ← Delay before applying jump force

@export_group("Camera")
@export var mouse_sensitivity: float = 0.003
@export_range(-90, 0) var min_pitch: float = -90
@export_range(0, 90) var max_pitch: float = 30

@export_group("Combat")
@export var combat_cooldown_duration: float = 0.5

# ============================================================================
# NODE REFERENCES
# ============================================================================
@onready var main_character: Node3D = $MainCharacter
@onready var camera_pivot: Node3D = $CameraPivot3d
@onready var spring_arm: SpringArm3D = $CameraPivot3d/SpringArm3D
@onready var animation: AnimationPlayer = $MainCharacter/AnimationPlayer
@onready var interaction_ray: RayCast3D = $CameraPivot3d/SpringArm3D/Camera3D/RayCast3D
@onready var health_bar: ProgressBar = $HUD/ProgressBar
@onready var hitbox_l: Area3D = $MainCharacter/Skeleton3D/HandAttachment_L/HitBox_L
@onready var hitbox_r: Area3D = $MainCharacter/Skeleton3D/HandAttachment_R/HitBox_R
# ============================================================================
# CONSTANTS & VARIABLES
# ============================================================================
var gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")
var combat_moves: Array[String] = ["kick", "punch"]
var has_left_ground: bool = false

# State tracking
var is_attacking: bool = false
var combat_exit_time: float = 0.0
var current_animation: String = ""
var jump_timer: float = -1.0
var is_jumping: bool = false # ← NEW: Track if we're in a jump
var is_dead: bool = false
var health: int = 100

# ============================================================================
# INITIALIZATION
# ============================================================================
func _ready() -> void:
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	if not interaction_ray:
		print("ERROR: RayCast3D node is missing! Please add it to the Camera.")
		return # Stop here if missing
	interaction_ray.add_exception(self )
	# Connect animation finished signal
	if animation:
		animation.animation_finished.connect(_on_animation_finished)
	# Connect hitbox signals
	hitbox_l.area_entered.connect(_on_hitbox_hit)
	hitbox_r.area_entered.connect(_on_hitbox_hit)
	# Disable hitboxes by default — only enable during attacks
	hitbox_l.monitoring = false
	hitbox_r.monitoring = false

# ============================================================================
# INPUT HANDLING
# ============================================================================
func _unhandled_input(event: InputEvent) -> void:
	# Mouse look
	if event is InputEventMouseMotion:
		_handle_camera_rotation(event)

	if event.is_action_pressed("interact"):
		_try_interact()
	
	# Combat inputs (only when not already attacking)
	if not is_attacking:
		if event.is_action_pressed("kick"):
			_do_combat("kick")
		elif event.is_action_pressed("punch"):
			_do_combat("punch")

func _handle_camera_rotation(event: InputEventMouseMotion) -> void:
	# Horizontal rotation (yaw)
	camera_pivot.rotate_y(-event.relative.x * mouse_sensitivity)
	
	# Vertical rotation (pitch) with clamping
	spring_arm.rotate_x(-event.relative.y * mouse_sensitivity)
	spring_arm.rotation.x = clamp(
		spring_arm.rotation.x,
		deg_to_rad(min_pitch),
		deg_to_rad(max_pitch)
	)

# ============================================================================
# COMBAT SYSTEM
# ============================================================================
func _do_combat(anim_name: String) -> void:
	is_attacking = true
	combat_exit_time = 0.0 # Reset stance timer
	hitbox_l.monitoring = true
	hitbox_r.monitoring = true
	_play_anim(anim_name)


func _try_interact() -> void:
	if not interaction_ray.is_colliding():
		return
	var collider: Object = interaction_ray.get_collider()
	if collider.has_method("interact"):
		collider.call("interact")

func _on_animation_finished(anim_name: String) -> void:
	if anim_name in combat_moves:
		is_attacking = false
		current_animation = "" # ← Clear so _update_animations can take over
		hitbox_l.monitoring = false
		hitbox_r.monitoring = false
		# Set cooldown timer (when to exit combat stance)
		combat_exit_time = Time.get_ticks_msec() + (combat_cooldown_duration * 1000.0)
	elif anim_name == "femaleRunJump" or anim_name == "jumpPack":
		is_jumping = false
		has_left_ground = false
		current_animation = ""
		# Snap quickly back to run if still sprinting
		if anim_name == "femaleRunJump" and Input.is_action_pressed("sprint"):
			_play_anim("femaleRun", 0.1)

func _on_health_changed(new_health: int) -> void:
	health = new_health
	health_bar.value = health

func _on_hitbox_hit(area: Area3D) -> void:
	# area is the hurtbox we hit — get the scene root (Player/Monster)
	var target: Node3D = area.get_owner()
	if target and target.has_method("take_damage"):
		target.take_damage(25)

func take_damage(amount: int) -> void:
	_on_health_changed(health - amount)
	if health <= 0 and not is_dead:
		is_dead = true
		print("Player died!")
		_play_anim("dyingPlayer", 0.0)
		# Wait 3 seconds, then restart
		var tween: Tween = create_tween()
		tween.tween_interval(3)
		tween.tween_callback(get_tree().reload_current_scene)

# ============================================================================
# PHYSICS & MOVEMENT
# ============================================================================
func _physics_process(delta: float) -> void:
	if is_dead:
		return
	_apply_gravity(delta)
	_handle_jump(delta) # ← Now takes delta
	_handle_movement(delta)
	_update_animations()
	
	move_and_slide()

func _apply_gravity(delta: float) -> void:
	if not is_on_floor():
		velocity.y -= gravity * delta

func _handle_jump(_delta: float) -> void:
	# Start jump
	if Input.is_action_just_pressed("jump") and is_on_floor() and not is_jumping:
		if Input.is_action_pressed("sprint"):
			_play_anim("femaleRunJump", 0.0)
		else:
			_play_anim("jumpPack", 0.0)
		is_jumping = true
		has_left_ground = false # Reset flag
	
	# Track if we left the ground
	if is_jumping and not is_on_floor():
		has_left_ground = true
	
	# Only reset after we've been airborne AND landed
	if is_jumping and is_on_floor() and has_left_ground:
		is_jumping = false
	
	# Safety: if marked as jumping but the jump animation stopped (e.g. blocked by collision), reset
	if is_jumping and is_on_floor() and animation.current_animation != "jumpPack" and animation.current_animation != "femaleRunJump":
		is_jumping = false
		has_left_ground = false
		current_animation = ""

func apply_jump_force() -> void:
	print("JUMP FORCE APPLIED!") # ← Add this debug line
	velocity.y = jump_force

func _handle_movement(delta: float) -> void:
	# Get input direction
	var input_dir := Input.get_vector("move_left", "move_right", "move_forward", "move_backward")
	
	# Convert to world space direction (relative to camera)
	var direction: Vector3 = (camera_pivot.transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()
	if direction:
		# Determine speed (sprint modifier)
		var current_speed := move_speed
		if Input.is_action_pressed("sprint"):
			current_speed *= sprint_multiplier
		
		# Apply movement
		velocity.x = direction.x * current_speed
		velocity.z = direction.z * current_speed
		
		# Smooth character rotation to face movement direction
		var target_angle := atan2(velocity.x, velocity.z)
		main_character.rotation.y = lerp_angle(
			main_character.rotation.y,
			target_angle,
			rotation_speed * delta
		)
	else:
		# Decelerate to stop
		velocity.x = move_toward(velocity.x, 0, move_speed)
		velocity.z = move_toward(velocity.z, 0, move_speed)

# ============================================================================
# ANIMATION SYSTEM
# ============================================================================
func _update_animations() -> void:
	# Don't override death animation
	if is_dead:
		return
	# Don't override combat animations
	if is_attacking:
		return
	
	# Don't interrupt jump (windup OR airborne)
	if jump_timer > 0 or is_jumping: # ← NEW: Don't touch animation during entire jump
		return
	
	# Priority 1: Airborne (shouldn't reach here during jump anymore)
	if not is_on_floor():
		_play_anim("jumpPack")
		return
	
	# Priority 2: Moving on ground
	var horizontal_velocity := Vector2(velocity.x, velocity.z)
	if horizontal_velocity.length() > 0.1:
		if Input.is_action_pressed("sprint"):
			_play_anim("femaleRun")
		else:
			_play_anim("walking")
		return
	
	# Priority 3: Idle (combat stance or neutral)
	if Time.get_ticks_msec() < combat_exit_time:
		_play_anim("combatIdle")
	else:
		_play_anim("justStanding")

func _play_anim(anim_name: String, blend: float = 0.4) -> void:
	# Only skip if same animation AND it's still actually playing
	if current_animation == anim_name and animation.is_playing():
		return
	
	if animation and animation.has_animation(anim_name):
		animation.play(anim_name, blend)
		current_animation = anim_name
