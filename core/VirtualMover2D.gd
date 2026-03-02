## Reusable node that moves a visual element vertically through the virtual space,
## automatically hiding it while it passes through bezel gaps.
## Attach child visual nodes (Sprite2D, Line2D, etc.) to this node.
## Depends on: VirtualSpace

class_name VirtualMover2D
extends Node2D

@export var speed_px_per_sec: float = 200.0
@export var wrap_at_bottom: bool = true

var virtual_y: float = 0.0
var virtual_space: VirtualSpace = null

func _ready() -> void:
	if virtual_space == null:
		# Create a default one from config
		virtual_space = VirtualSpace.new()

func _process(delta: float) -> void:
	virtual_y += speed_px_per_sec * delta

	# Wrap around when past virtual bottom
	if wrap_at_bottom and virtual_y > virtual_space.virtual_height():
		virtual_y = fmod(virtual_y, virtual_space.virtual_height())

	var result := virtual_space.virtual_to_real(virtual_y)

	if result.visible:
		position.y = result.real_y
		show()
	else:
		hide()

func set_virtual_space(vs: VirtualSpace) -> void:
	virtual_space = vs
