package vspace

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:strings"
import "core:slice"
import "core:thread"
import "core:os/os2"
import glfw "vendor:glfw"
import vk "vendor:vulkan"

g_context: runtime.Context
g_window: glfw.WindowHandle
g_window_resized := false

g_recompiling_shaders := false
g_should_reload_shaders := false

g_movement_vector := [3]f32{0, 0, 0}
g_speed : f32 = 0.1
g_is_capturing_mouse := false
g_sensitivity_x := 0.1
g_sensitivity_y := 0.08
g_yaw := 0.0
g_pitch := 0.0

main :: proc() {
	context.logger = log.create_console_logger()
	g_context = context
	if !glfw.Init() {
		log.panicf("Failed to initialize glfw")
	}
	defer glfw.Terminate()

	window_shown := false
	glfw.WindowHint(glfw.VISIBLE, glfw.FALSE)
	glfw.WindowHint(glfw.CLIENT_API, glfw.NO_API)
	g_window = glfw.CreateWindow(800, 600, "VSpace experimental", nil, nil)
	defer glfw.DestroyWindow(g_window)
	if g_window == nil {
		log.panicf("Failed to create window")
	}

	glfw.SetKeyCallback(g_window, on_input)
	g_last_cursor_x, g_last_cursor_y = glfw.GetCursorPos(g_window)
	glfw.SetCursorPosCallback(g_window, on_cursor_pos)
	glfw.SetScrollCallback(g_window, on_scroll)
	glfw.SetInputMode(g_window, glfw.RAW_MOUSE_MOTION, 1)
	init_vulkan()
	defer destroy_vulkan()

	create_renderer()
	defer destroy_renderer()

	glfw.SetFramebufferSizeCallback(g_window, proc "c" (_: glfw.WindowHandle, _, _: i32) {
		context = g_context
		g_window_resized = true
	})

	frame_index: u32 = 0
	for !glfw.WindowShouldClose(g_window) {
		glfw.PollEvents()
		update()
		w, h := glfw.GetFramebufferSize(g_window)
		if window_shown && (w == 0 || h == 0) {
			glfw.WaitEvents()
			continue
		}
		if g_should_reload_shaders {
			vk.QueueWaitIdle(g_graphics_queue)
			recreate_pipeline()
			g_should_reload_shaders = false
		}
		render(frame_index)
		frame_index = (frame_index + 1) % MAX_FRAMES_IN_FLIGHT
		if !window_shown {
			window_shown = true
			glfw.ShowWindow(g_window)
		}
	}
	vk.DeviceWaitIdle(g_device)
}

@(private = "file")
on_input :: proc "c" (window: glfw.WindowHandle, key, scancode, action, mods: i32) {
	context = g_context
	if action == glfw.PRESS {
		switch key {
			case glfw.KEY_C: {
				recompile_shaders()
			}
			case glfw.KEY_E: {
				g_is_capturing_mouse = !g_is_capturing_mouse
				update_cursor()
			}
			case glfw.KEY_R: {
				g_cameraPos = {0,0,0}
				g_yaw = 0
				g_pitch = 0
			}
			case glfw.KEY_Q: {
				log.infof("Camera is at %f %f %f", g_cameraPos.x, g_cameraPos.y, g_cameraPos.z)
			}
		}
	}
	if action == glfw.REPEAT {
		return
	}
	factor : f32 = 1 if action == glfw.PRESS else -1
	switch key {
		case glfw.KEY_W: {
			g_movement_vector[2] -= factor
		}
		case glfw.KEY_S: {
			g_movement_vector[2] += factor
		}
		case glfw.KEY_D: {
			g_movement_vector[0] += factor
		}
		case glfw.KEY_A: {
			g_movement_vector[0] -= factor
		}
		case glfw.KEY_SPACE: {
			g_movement_vector[1] += factor
		}
		case glfw.KEY_LEFT_SHIFT: {
			g_movement_vector[1] -= factor
		}
	}
}

@(private = "file")
g_last_cursor_x := 0.0

@(private = "file")
g_last_cursor_y := 0.0

@(private = "file")
on_cursor_pos :: proc "c" (window: glfw.WindowHandle, x, y: f64) {
	context = g_context
	if g_is_capturing_mouse {
		dx, dy := x - g_last_cursor_x, y - g_last_cursor_y
		g_yaw += dx * g_sensitivity_x
		g_pitch = clamp(g_pitch - dy * g_sensitivity_y, -90.0, 90.0)
	}
	g_last_cursor_x, g_last_cursor_y = x, y
}

@(private="file")
on_scroll :: proc "c" (window: glfw.WindowHandle, xoffset, yoffset: f64) {
	g_speed = max(0, g_speed + f32(0.005*yoffset));
}

@(private = "file")
update_cursor :: proc() {
	if g_is_capturing_mouse {
		glfw.SetInputMode(g_window, glfw.CURSOR, glfw.CURSOR_DISABLED)
	} else {
		glfw.SetInputMode(g_window, glfw.CURSOR, glfw.CURSOR_NORMAL)
	}
}

@(private = "file")
recompile_shaders :: proc() {
	if g_recompiling_shaders {
		return
	}
	log.info("Recompiling shaders")
	g_recompiling_shaders = true

	call_compiler_thread :: proc() {
		context = g_context
		desc := os2.Process_Desc {
			working_dir = "shaders",
			command = []string{
				"cmd.exe",
				"/c compile_shaders.bat"
			}
		}
		state, stdout, stderr, err := os2.process_exec(desc, g_context.allocator)
		log.info(strings.truncate_to_byte(string(stdout), 0))
		log.info(strings.truncate_to_byte(string(stderr), 0))
		log.infof("Compiler exited with code %d", state.exit_code)
		g_recompiling_shaders = false
		if state.exit_code == 0 {
			g_should_reload_shaders = true
		}
	}
	thread.create_and_start(call_compiler_thread)
}
