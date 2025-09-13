package vspace

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:math/rand"
import "core:os/os2"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

import "input"
import "renderer"
import "world"

import glfw "vendor:glfw"
import vk "vendor:vulkan"

g_context: runtime.Context

g_recompiling_shaders := false
g_should_reload_shaders := false

g_is_capturing_mouse := false

g_renderer_running: bool = false
g_render_mutex: sync.Mutex

g_camera1: renderer.Camera
g_camera2: renderer.Camera
g_read_camera: ^renderer.Camera

main :: proc() {
	context.logger = log.create_console_logger()
	g_context = context
	if !glfw.Init() {
		log.panicf("Failed to initialize glfw")
	}
	defer glfw.Terminate()

	renderer.create(800, 600, "VSpace")
	defer renderer.destroy()

	window := renderer.g_window
	glfw.SetKeyCallback(window, on_input)

	glfw.SetScrollCallback(window, on_scroll)
	glfw.SetInputMode(window, glfw.RAW_MOUSE_MOTION, 1)

	prev_x, prev_y := glfw.GetCursorPos(window)
	stopwatch: time.Stopwatch
	time.stopwatch_start(&stopwatch)
	prev_time := time.stopwatch_duration(stopwatch)

	g_camera1 = input.g_camera
	g_read_camera = &g_camera1
	write_camera := &g_camera2

	g_renderer_running = true
	render_thread := thread.create_and_start(render_thread_func)

	for !glfw.WindowShouldClose(window) {
		glfw.PollEvents()
		if g_should_reload_shaders {
			sync.mutex_lock(&g_render_mutex)
			renderer.recreate_pipeline()
			sync.mutex_unlock(&g_render_mutex)

			g_should_reload_shaders = false
		}

		x, y := glfw.GetCursorPos(window)
		if g_is_capturing_mouse {
			input.mouse_delta(f32(x - prev_x), f32(y - prev_y))
		}
		prev_x, prev_y = x, y

		current_time := time.stopwatch_duration(stopwatch)
		time_delta := time.duration_seconds(current_time - prev_time)
		prev_time = current_time

		input.tick_input(f32(time_delta))

		write_camera^ = input.g_camera
		sync.atomic_store(&g_read_camera, write_camera)
		write_camera = &g_camera2 if write_camera == &g_camera1 else &g_camera1

		time.sleep(time.Millisecond)
	}
	sync.atomic_store(&g_renderer_running, false)
	thread.join(render_thread)
}

render_thread_func :: proc() {
	context = g_context
	frame_index : u32 = 0
	stopwatch: time.Stopwatch
	time.stopwatch_start(&stopwatch)
	prev_time := time.stopwatch_duration(stopwatch)

	for sync.atomic_load(&g_renderer_running) {
		sync.mutex_lock(&g_render_mutex)

		camera := sync.atomic_load(&g_read_camera)
		renderer.render(camera^, frame_index)
		frame_index = (frame_index + 1) % renderer.MAX_FRAMES_IN_FLIGHT

		current_time := time.stopwatch_duration(stopwatch)
		delta := time.duration_milliseconds(current_time - prev_time)
		prev_time = current_time
		if delta > 30 {
			log.infof("Rendering took %.3fms (%.3f fps)", delta, 1000 / delta)
		}

		sync.mutex_unlock(&g_render_mutex)
	}
}

@(private = "file")
on_input :: proc "c" (window: glfw.WindowHandle, key, scancode, action, mods: i32) {
	context = g_context
	if action == glfw.PRESS {
		switch key {
		case glfw.KEY_C:
			{
				recompile_shaders()
			}
		case glfw.KEY_E:
			{
				g_is_capturing_mouse = !g_is_capturing_mouse
				update_cursor()
			}
		case glfw.KEY_R:
			{
				input.reset_position_and_rotation()
			}
		case glfw.KEY_Q:
			{
				pos := input.g_camera.pos
				log.infof("Camera is at %f %f %f", pos.x, pos.y, pos.z)
			}
		}
	}
	input.handle_input(key, action)
}

@(private = "file")
on_scroll :: proc "c" (window: glfw.WindowHandle, xoffset, yoffset: f64) {
	context = g_context
	input.wheel_delta(f32(xoffset), f32(yoffset))
}

@(private = "file")
update_cursor :: proc() {
	if g_is_capturing_mouse {
		glfw.SetInputMode(renderer.g_window, glfw.CURSOR, glfw.CURSOR_DISABLED)
	} else {
		glfw.SetInputMode(renderer.g_window, glfw.CURSOR, glfw.CURSOR_NORMAL)
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
			command     = []string{"bash", "compile.sh"},
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
