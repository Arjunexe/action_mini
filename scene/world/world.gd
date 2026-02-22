extends Node3D

@export var respawn_delay: float = 5.0

var monster_scene: PackedScene = preload("res://scene/actors/monster/monster.tscn")

func _ready() -> void:
	# Connect to the initial monster(s) already in the scene
	_connect_all_monsters()

func _connect_all_monsters() -> void:
	for monster in get_tree().get_nodes_in_group("monster"):
		if not monster.died.is_connected(_on_monster_died):
			monster.died.connect(_on_monster_died)

func _on_monster_died(death_position: Vector3) -> void:
	# Wait before spawning a new one
	await get_tree().create_timer(respawn_delay).timeout
	_spawn_monster(death_position)

func _spawn_monster(near_position: Vector3) -> void:
	var new_monster: CharacterBody3D = monster_scene.instantiate()
	add_child(new_monster)
	# Spawn at a random offset from where the old one died
	var offset := Vector3(randf_range(-8, 8), 3, randf_range(-8, 8))
	new_monster.global_position = near_position + offset
	# Connect the new monster's died signal so it also respawns
	new_monster.died.connect(_on_monster_died)
