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

on_input :: proc "c" (window: glfw.WindowHandle, key, scancode, action, mods: i32) {
	context = g_context
	if action == glfw.PRESS {
		if key == glfw.KEY_C {
			recompile_shaders()
		}
	}
}


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
