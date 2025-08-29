package input

import "../renderer"
import "core:math"
import "core:log"
import glfw "vendor:glfw"

InputSettings :: struct {
	sensitivity_x: f32,
	sensitivity_y: f32,
	camera_speed:  f32,
	key_forward:   i32,
	key_backwards: i32,
	key_right:     i32,
	key_left:      i32,
	key_up:        i32,
	key_down:      i32,
}

g_input_settings := InputSettings {
	sensitivity_x = 0.1,
	sensitivity_y = 0.08,
	camera_speed  = 6,
	key_forward   = glfw.KEY_W,
	key_backwards = glfw.KEY_S,
	key_right     = glfw.KEY_D,
	key_left      = glfw.KEY_A,
	key_up        = glfw.KEY_SPACE,
	key_down      = glfw.KEY_LEFT_SHIFT,
}

g_camera := renderer.Camera {
	fov   = 45,
	pos   = {0, 0, 0},
	yaw   = 0,
	pitch = 0,
}

InputState :: struct {
	forward:  f32,
	sideways: f32,
	up:       f32,
	yawr:     f32,
}

g_input_state := InputState{}

mouse_delta :: proc(dx, dy: f32) {
	g_camera.yaw += dx * g_input_settings.sensitivity_x
	g_camera.pitch = clamp(g_camera.pitch - dy * g_input_settings.sensitivity_y, -90.0, 90.0)
}

wheel_delta :: proc(x_offset, y_offset: f32) {
	g_input_settings.camera_speed = max(0, g_input_settings.camera_speed + 0.3 * y_offset)
}

set_movement :: proc(forward, sideways, up: f32) {
	g_input_state.forward = forward
	g_input_state.sideways = sideways
	g_input_state.up = up
}

add_movement :: proc(forward, sideways, up: f32) {
	g_input_state.forward += forward
	g_input_state.sideways += sideways
	g_input_state.up += up
}

handle_input :: proc(key, action: i32) {
	if action == glfw.REPEAT {
		return
	}
	factor: f32 = 1 if action == glfw.PRESS else -1
	forward: f32 =
		1 if key == g_input_settings.key_forward else -1 if key == g_input_settings.key_backwards else 0
	sideways: f32 =
		1 if key == g_input_settings.key_right else -1 if key == g_input_settings.key_left else 0
	up: f32 =
		1 if key == g_input_settings.key_up else -1 if key == g_input_settings.key_down else 0
	
	g_input_state.yawr += factor if key == glfw.KEY_RIGHT else -factor if key == glfw.KEY_LEFT else 0
	add_movement(forward * factor, sideways * factor, up * factor)
}

reset_position_and_rotation :: proc() {
	g_camera.pos = {0, 0, 0}
	g_camera.yaw = 0
	g_camera.pitch = 0
}

tick_input :: proc(time_delta: f32) {
	move_x := g_input_state.sideways * g_input_settings.camera_speed * time_delta
	move_y := g_input_state.up * g_input_settings.camera_speed * time_delta
	move_z := g_input_state.forward * g_input_settings.camera_speed * time_delta
	move_z *= -1

	yaw := math.to_radians(g_camera.yaw)
	c := math.cos(yaw)
	s := math.sin(yaw)

	move_x, move_z = move_x * c - move_z * s, move_x * s + move_z * c
	g_camera.pos += {move_x, move_y, move_z}
	g_camera.yaw += g_input_state.yawr * 1
}
