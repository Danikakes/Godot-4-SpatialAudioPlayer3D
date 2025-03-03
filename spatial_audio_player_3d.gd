#@tool #Eventually will work in editor.
@icon("icon.svg")
extends AudioStreamPlayer3D
class_name SpatialAudioPlayer3D
## GD Script Addon based on [url=https://www.youtube.com/watch?v=mHokBQyB_08&ab_channel=Blekoh]Blekoh's Video[/url]
## [br][b]Important Parameters:[/b][br]
## - [param volume_db]: On init, this value is edited consistently to increase immersion. Changing this field will do nothing.[br]
## - [param max_db]: Use this field to edit the max loudness of the stream.[br]
## - [param unit_size]: The size of the area that the audio is heard at higher volume.[br]
## - [param max_distance]: The max distance the audio can be heard, if the [param max_raycast_distance] is lower, this may break immersion depending on your use case. [br]
## - [param attenuation_model]: The model used to attenuate audio, This is overwritten based on [param is_ambient].[br]
## - [param panning_strength]: The focal length of the point the stream is being projected from. This is overwritten based on [param is_ambient].

## Collision Layers to ricochet sound.
@export_flags_3d_physics var collision_mask := 1
## If Room Size Reverb is enabled. When true, room size will be calculated and reverb will be applied.
@export var room_size_reverb := true
## If Attenuation is enabled. When true, the audio player will base the lowpass cutoff on the location of the camera/target.
@export var audio_attenuation := true
## When set to true, the sound will span over the unit size evenly. Otherwise, the sound will be focused to a point.
@export var is_ambient := false
## Max distance that raycasts will interact with objects to determine effect values.[br]Differs from [param max_distance]. This is specific to effects applied, not max distance heard.
@export_range(0, 4096, 0.01 ,"suffix:m") var max_raycast_distance : float = 30.00
## Max amount of reverb wetness applied to audio stream.
@export_range(0, 1, .01) var max_reverb_wetness : float = 0.5
## Lowpass cutoff when players are standing behind a collider. Higher number represents a thinner wall.
@export_custom(PROPERTY_HINT_NONE, "suffix:Hz") var wall_lowpass_cutoff_amount : int = 600
## The max value of lowpass applied to the audio player when the target has no collision shape blocking.
@export_custom(PROPERTY_HINT_NONE, "suffix:Hz") var wall_lowpass_cutoff_max : int = 2000
## Frequency in which distance, bounce, wetness and reverb for the target environment are updated in seconds.[br]
## If the node does not move much, this can be longer to preserve performance.
@export_range(.01, 1, .01, "suffix:s") var environment_update_frequency : float = 0.2
## Frequency in which lowpass cutoff for the camera is updated in seconds.[br]
## If the camera is attached to a player, this should be short to preserve imemrsive integrety.
@export_range(.01, 1, .01, "suffix:s") var camera_update_frequency : float = 0.2

## Prefix applied to generated Audio Bus
@export var AudioBusPrefix := "SpatialAudioBus"
# Tracking Variables
var _raycasts := []
var _distances := [0,0,0,0,0,0,0,0,0,0,0]

## The instance of a [RayCast3D] that targets the player for Attenuation
var Target_Raycast : RayCast3D = null
# Setup Helper Dict, {NAME:[DEFAULT_TARGET, DEFAULT_ROTATION]}
@onready var _ray_setup_helper := {
	#Used to determine room size
	"Left": [Vector3(1,0,0), Vector3(0,0,0)], 
	"Right": [Vector3(-1,0,0), Vector3(0,0,0)], 
	"Forward": [Vector3(0,0,1), Vector3(0,0,0)], 
	"ForwardLeft": [Vector3(0,0,1), Vector3(0,45,0)], 
	"ForwardRight": [Vector3(0,0,1), Vector3(0,-45,0)], 
	"Backward": [Vector3(0,0,-1), Vector3(0,45,0)], 
	"BackwardLeft": [Vector3(0,0,-1), Vector3(0,-45,0)], 
	"BackwardRight": [Vector3(0,0,-1), Vector3(0,0,0)], 
	"Up": [Vector3(0,1,0), Vector3(0,0,0)], 
	"Down": [Vector3(0,-1,0), Vector3(0,0,0)],
	#Used to determine effects based on target listener's position
	"Target": [Vector3(0,0,1), Vector3(0,0,0)] 
	}
var _last_update_time := 0.0
var _should_update_dist := true
var _current_raycast_idx := 1
var _setup_complete := false
# Bus Variables
var _bus_name : String
var _bus_idx : int = -1

# Effects Variables
var _reverb_effect : AudioEffectReverb
var _lowpass_filter: AudioEffectLowPassFilter

# Target Parameters
@export_group("Advanced")
var _target_lowpass_cutoff : float = 20000
var _target_reverb_room_size : float = 0.0
var _target_reverb_wetness : float = 0.0
var _target_volume_db : float = 0.0
## Starting volume of the [SpatialAudioPlayer3D] until the raycasts find the player.
@export_range(-80, 80, 0.1, "suffix:dB") var minimum_volume_db : float = -80
## Speed in which effects are lerped to their target values. Higher is quicker.
@export_range(10.0, 25.0, 0.1) var lerp_speed : float = 15.0
## Default the Target will be the active camera. When set, the calculated target is overwritten.[br][b]Example Usage:[/b] If a third person player model needs to be the target listner instead of the camera
@export var custom_listener_target : Node3D
@export_category("Future Features")
##@experimental 
## Use reflections to locate the player and apply effects based on their found position.[br][b]NOT YET IMPLEMENTED[/b]
@export var use_reflections := false
##@experimental 
## Maximum number of reflections to attempt to find the player.[b]NOT YET IMPLEMENTED[/b]
@export_range(1,25,1) var max_reflections := 2


func _ready() -> void:
	# Dynamically create audio bus to control effects
	if is_ambient:
		attenuation_model = ATTENUATION_DISABLED
		panning_strength = 0
	else:
		attenuation_model = ATTENUATION_LOGARITHMIC
		panning_strength = 1.5
	_bus_idx  = AudioServer.bus_count
	_bus_name = AudioBusPrefix + "#" + str(_bus_idx)
	AudioServer.add_bus(_bus_idx)
	AudioServer.set_bus_name(_bus_idx, _bus_name)
	AudioServer.set_bus_send(_bus_idx, bus)
	self.bus = _bus_name
	
	
	# Add Effects to new audio bus
	AudioServer.add_bus_effect(_bus_idx, AudioEffectReverb.new(), 0)
	_reverb_effect = AudioServer.get_bus_effect(_bus_idx, 0)
	AudioServer.add_bus_effect(_bus_idx, AudioEffectLowPassFilter.new(), 1)
	_lowpass_filter = AudioServer.get_bus_effect(_bus_idx, 1)
	
	_target_volume_db = volume_db
	volume_db = minimum_volume_db
	
	# Setup Raycasts
	for i in _ray_setup_helper:
		var r = RayCast3D.new()
		r.name = i
		r.target_position.x = _ray_setup_helper[i][0].x * max_raycast_distance
		r.target_position.y = _ray_setup_helper[i][0].y * max_raycast_distance
		r.target_position.z = _ray_setup_helper[i][0].z * max_raycast_distance
		r.rotation_degrees = _ray_setup_helper[i][1]
		r.collision_mask = collision_mask
		_raycasts.append(r)
		if i == "Target":
			Target_Raycast = r
		add_child(r)
		
	_setup_complete = true
	
func _exit_tree() -> void:
	var idx = AudioServer.get_bus_index(_bus_name)
	if idx >= 0:
		AudioServer.remove_bus(idx)

func _physics_process(delta: float) -> void:
	if !_setup_complete:
		return
	_last_update_time += delta
	#Raycast Optimization, only check every update frequency
	if _should_update_dist and _last_update_time > environment_update_frequency:
		_on_raycast_distance_update(_raycasts[_current_raycast_idx], _current_raycast_idx)
		_current_raycast_idx += 1
		if _current_raycast_idx >= _distances.size():
			_current_raycast_idx = 0
			_should_update_dist = false
	if _last_update_time > camera_update_frequency:
		var _target = custom_listener_target if custom_listener_target != null else get_viewport().get_camera_3d()
		if _target != null:
			_on_spatial_audio_update(_target)
		_should_update_dist = true
		_last_update_time = 0.0
	_lerp_parameters(delta)

func _lerp_parameters(delta):
	volume_db = lerp(volume_db, _target_volume_db, delta)
	_lowpass_filter.cutoff_hz = lerp(_lowpass_filter.cutoff_hz, _target_lowpass_cutoff, delta * lerp_speed)
	_reverb_effect.wet = lerp(_reverb_effect.wet, _target_reverb_wetness * max_reverb_wetness, delta * lerp_speed)
	_reverb_effect.room_size = lerp(_reverb_effect.room_size, _target_reverb_room_size, delta * lerp_speed)

func _on_raycast_distance_update(ray: RayCast3D, idx:int):
	ray.force_raycast_update()
	var c  = ray.get_collider()
	if c != null:
		_distances[idx] = self.global_position.distance_to(ray.get_collision_point())
	else:
		_distances[idx] = 0
	ray.enabled = false

func _on_spatial_audio_update(p: Node3D):
	_on_reverb_update(p)
	_on_lowpass_filter_update(p)

func _on_reverb_update(_p : Node3D):
	if _reverb_effect != null:
		var room_size := 0.0
		var wetness := 1.0
		if room_size_reverb:
			for d in _distances:
				if d >= 0:
					room_size += (d/max_raycast_distance)/ (float(_distances.size()))
					room_size = min(room_size, 1.0)
				else:
					wetness -= 1.0 / float(_distances.size())
					wetness = max(wetness, 0.0)
		_target_reverb_wetness = wetness
		_target_reverb_room_size = room_size

func _on_lowpass_filter_update(_p: Node3D):
	if _lowpass_filter != null and Target_Raycast != null:
		# Force raycast to stop at player to avoid unintended collisions
		var player_to_target_distance = _p.global_position.distance_to(self.global_position)
		# Clamp the raycast so it doesnt go farther than the max distance
		clamp(player_to_target_distance, 0, max_raycast_distance)
		Target_Raycast.target_position = (_p.global_position - self.global_position).normalized() * player_to_target_distance
		var c = Target_Raycast.get_collider()
		var lp_cutoff = wall_lowpass_cutoff_max
		if c != null and audio_attenuation:
			var dist = self.global_position.distance_to(Target_Raycast.get_collision_point())
			var dist_to_player = self.global_position.distance_to(_p.global_position)
			var wall_to_player_ratio = dist / max(dist_to_player, 0.001)
			if dist < dist_to_player: 
				lp_cutoff = wall_lowpass_cutoff_amount * wall_to_player_ratio
		_target_lowpass_cutoff = lp_cutoff
	
