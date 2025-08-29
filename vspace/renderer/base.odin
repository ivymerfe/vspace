package renderer

import "base:runtime"
import "core:log"
import "core:slice"
import "core:time"
import glfw "vendor:glfw"
import vk "vendor:vulkan"

g_renderer_context: runtime.Context
g_window: glfw.WindowHandle
g_window_resized := false

g_instance: vk.Instance
g_surface: vk.SurfaceKHR
g_physical_device: vk.PhysicalDevice
g_mem_properties: vk.PhysicalDeviceMemoryProperties
g_deviceName: string
g_device: vk.Device
g_graphics_queue: vk.Queue
g_present_queue: vk.Queue

QueueFamilyIdx :: struct {
	graphics: u32,
	present:  u32,
}

g_queue_family_indexes: QueueFamilyIdx

g_swapchain: vk.SwapchainKHR
g_swapchain_format: vk.SurfaceFormatKHR
g_swapchain_extent: vk.Extent2D
g_swapchain_image_count: u32
g_swapchain_images: []vk.Image
g_swapchain_image_views: []vk.ImageView

g_command_pool: vk.CommandPool

g_command_buffers: [MAX_FRAMES_IN_FLIGHT]vk.CommandBuffer
g_image_available_semaphores: [MAX_FRAMES_IN_FLIGHT]vk.Semaphore
g_render_finished_semaphores: []vk.Semaphore // Per image
g_in_flight_fences: [MAX_FRAMES_IN_FLIGHT]vk.Fence
g_acquire_fences: [MAX_FRAMES_IN_FLIGHT]vk.Fence

g_depth_images: [MAX_FRAMES_IN_FLIGHT]vk.Image
g_depth_image_views: [MAX_FRAMES_IN_FLIGHT]vk.ImageView
g_depth_images_memory: [MAX_FRAMES_IN_FLIGHT]vk.DeviceMemory

create :: proc(width, height: i32, title: cstring) {
	g_renderer_context = context

	glfw.WindowHint(glfw.VISIBLE, glfw.FALSE)
	glfw.WindowHint(glfw.CLIENT_API, glfw.NO_API)
	g_window = glfw.CreateWindow(width, height, title, nil, nil)
	if g_window == nil {
		log.panicf("Failed to create window")
	}
	glfw.SetFramebufferSizeCallback(g_window, proc "c" (_: glfw.WindowHandle, _, _: i32) {
		context = g_renderer_context
		g_window_resized = true
	})
	init_vulkan()
	create_world_renderer()
}

destroy :: proc() {
	vk.DeviceWaitIdle(g_device)
	destroy_world_renderer()
	destroy_vulkan()
	glfw.DestroyWindow(g_window)
}

vk_try :: proc(result: vk.Result, location := #caller_location) {
	if result != .SUCCESS {
		log.panicf("Vulkan failed with result = %v", result, location)
	}
}

@(private)
init_vulkan :: proc() {
	vk_create_instance()

	vk_try(glfw.CreateWindowSurface(g_instance, g_window, nil, &g_surface))

	vk_pick_device()
	vk_create_logical_device()
	vk_create_swapchain()
	vk_create_depth_images()

	cmd_pool_info := vk.CommandPoolCreateInfo {
		sType            = .COMMAND_POOL_CREATE_INFO,
		flags            = {.RESET_COMMAND_BUFFER},
		queueFamilyIndex = g_queue_family_indexes.graphics,
	}
	vk_try(vk.CreateCommandPool(g_device, &cmd_pool_info, nil, &g_command_pool))

	cmd_buffer_info := vk.CommandBufferAllocateInfo {
		sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
		level              = .PRIMARY,
		commandPool        = g_command_pool,
		commandBufferCount = MAX_FRAMES_IN_FLIGHT,
	}
	vk_try(vk.AllocateCommandBuffers(g_device, &cmd_buffer_info, &g_command_buffers[0]))

	g_render_finished_semaphores = make([]vk.Semaphore, g_swapchain_image_count)
	sem_info := vk.SemaphoreCreateInfo {
		sType = .SEMAPHORE_CREATE_INFO,
	}
	fence_info := vk.FenceCreateInfo {
		sType = .FENCE_CREATE_INFO,
		flags = {.SIGNALED},
	}
	for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
		vk_try(vk.CreateSemaphore(g_device, &sem_info, nil, &g_image_available_semaphores[i]))
		vk_try(vk.CreateFence(g_device, &fence_info, nil, &g_in_flight_fences[i]))
		vk_try(vk.CreateFence(g_device, &fence_info, nil, &g_acquire_fences[i]))
	}
	for i in 0 ..< g_swapchain_image_count {
		vk_try(vk.CreateSemaphore(g_device, &sem_info, nil, &g_render_finished_semaphores[i]))
	}

	log.info("Vulkan initialised")
}

@(private)
destroy_vulkan :: proc() {
	for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
		vk.DestroySemaphore(g_device, g_image_available_semaphores[i], nil)
		vk.DestroyFence(g_device, g_in_flight_fences[i], nil)
		vk.DestroyFence(g_device, g_acquire_fences[i], nil)
	}
	for i in 0 ..< g_swapchain_image_count {
		vk.DestroySemaphore(g_device, g_render_finished_semaphores[i], nil)
	}
	delete(g_render_finished_semaphores)
	vk.DestroyCommandPool(g_device, g_command_pool, nil)

	vk_destroy_depth_images()
	vk_destroy_swapchain()
	vk.DestroyDevice(g_device, nil)
	vk.DestroySurfaceKHR(g_instance, g_surface, nil)
	vk.DestroyInstance(g_instance, nil)
}

render :: proc(camera: Camera, frame_index: u32) {
	fence := g_in_flight_fences[frame_index]

	// t1 := time.now()
	vk_try(vk.WaitForFences(g_device, 1, &fence, true, max(u64)))
	vk_try(vk.ResetFences(g_device, 1, &fence))
	// t2 := time.now()
	// d1 := time.duration_milliseconds(time.diff(t1, t2))

	sem_image_available := g_image_available_semaphores[frame_index]
	fence_acquire := g_acquire_fences[frame_index]

	vk_try(vk.ResetFences(g_device, 1, &fence_acquire))

	image_index: u32
	acquire_result := vk.AcquireNextImageKHR(
		g_device,
		g_swapchain,
		0,
		sem_image_available,
		fence_acquire,
		&image_index,
	)
	#partial switch acquire_result {
	case .ERROR_OUT_OF_DATE_KHR:
		recreate_swapchain()
		return
	case .SUCCESS, .SUBOPTIMAL_KHR:
	case:
		log.panicf("vulkan: acquire next image failure: %v", acquire_result)
	}
	vk_try(vk.WaitForFences(g_device, 1, &fence_acquire, true, max(u64)))

	// t3 := time.now()
	// d2 := time.duration_milliseconds(time.diff(t2, t3))

	// log.infof("\x1b[2J\x1b[HF1: %.4f  F2: %.4f", d1, d2)

	buffer := g_command_buffers[frame_index]

	vk.ResetCommandBuffer(buffer, {})
	record_commands(camera, buffer, frame_index, image_index)

	sem_render_finished := g_render_finished_semaphores[image_index]
	submit_info := vk.SubmitInfo {
		sType                = .SUBMIT_INFO,
		waitSemaphoreCount   = 1,
		pWaitSemaphores      = &sem_image_available,
		pWaitDstStageMask    = &vk.PipelineStageFlags{.COLOR_ATTACHMENT_OUTPUT},
		commandBufferCount   = 1,
		pCommandBuffers      = &buffer,
		signalSemaphoreCount = 1,
		pSignalSemaphores    = &sem_render_finished,
	}
	vk_try(vk.QueueSubmit(g_graphics_queue, 1, &submit_info, fence))

	present_info := vk.PresentInfoKHR {
		sType              = .PRESENT_INFO_KHR,
		waitSemaphoreCount = 1,
		pWaitSemaphores    = &sem_render_finished,
		swapchainCount     = 1,
		pSwapchains        = &g_swapchain,
		pImageIndices      = &image_index,
	}
	present_result := vk.QueuePresentKHR(g_present_queue, &present_info)
	switch {
	case present_result == .ERROR_OUT_OF_DATE_KHR ||
	     present_result == .SUBOPTIMAL_KHR ||
	     g_window_resized:
		g_window_resized = false
		recreate_swapchain()
	case present_result == .SUCCESS:
	case:
		log.panicf("vulkan: present failure: %v", present_result)
	}
}

@(private = "file")
vk_create_instance :: proc() {
	vk.load_proc_addresses_global(rawptr(glfw.GetInstanceProcAddress))
	if vk.CreateInstance == nil {
		log.panicf("Failed to load vulkan function pointers")
	}

	create_info := vk.InstanceCreateInfo {
		sType            = .INSTANCE_CREATE_INFO,
		pApplicationInfo = &vk.ApplicationInfo {
			sType = .APPLICATION_INFO,
			pApplicationName = "VSpace",
			applicationVersion = vk.MAKE_VERSION(1, 0, 0),
			pEngineName = "VSpace",
			engineVersion = vk.MAKE_VERSION(1, 0, 0),
			apiVersion = vk.API_VERSION_1_4,
		},
	}
	extensions := slice.clone_to_dynamic(
		glfw.GetRequiredInstanceExtensions(),
		context.temp_allocator,
	)
	when ENABLE_VALIDATION {
		create_info.ppEnabledLayerNames = raw_data([]cstring{"VK_LAYER_KHRONOS_validation"})
		create_info.enabledLayerCount = 1

		append(&extensions, vk.EXT_DEBUG_UTILS_EXTENSION_NAME)

		// Severity based on logger level.
		severity: vk.DebugUtilsMessageSeverityFlagsEXT
		if context.logger.lowest_level <= .Error {
			severity |= {.ERROR}
		}
		if context.logger.lowest_level <= .Warning {
			severity |= {.WARNING}
		}
		if context.logger.lowest_level <= .Info {
			severity |= {.INFO}
		}
		if context.logger.lowest_level <= .Debug {
			severity |= {.VERBOSE}
		}

		dbg_create_info := vk.DebugUtilsMessengerCreateInfoEXT {
			sType           = .DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
			messageSeverity = severity,
			messageType     = {.GENERAL, .VALIDATION, .PERFORMANCE}, // all of them.
			pfnUserCallback = vk_messenger_callback,
		}
		create_info.pNext = &dbg_create_info
	}
	create_info.enabledExtensionCount = u32(len(extensions))
	create_info.ppEnabledExtensionNames = raw_data(extensions)

	vk_try(vk.CreateInstance(&create_info, nil, &g_instance))
	vk.load_proc_addresses_instance(g_instance)
}

@(private = "file")
vk_messenger_callback :: proc "system" (
	messageSeverity: vk.DebugUtilsMessageSeverityFlagsEXT,
	messageTypes: vk.DebugUtilsMessageTypeFlagsEXT,
	pCallbackData: ^vk.DebugUtilsMessengerCallbackDataEXT,
	pUserData: rawptr,
) -> b32 {
	context = g_renderer_context

	level: log.Level
	if .ERROR in messageSeverity {
		level = .Error
	} else if .WARNING in messageSeverity {
		level = .Warning
	} else if .INFO in messageSeverity {
		level = .Info
	} else {
		level = .Debug
	}

	log.log(level, pCallbackData.pMessage)
	return false
}

@(private = "file")
vk_pick_device :: proc() {
	device_count: u32
	vk_try(vk.EnumeratePhysicalDevices(g_instance, &device_count, nil))
	if device_count == 0 {
		log.panic("No GPU found!")
	}

	devices := make([]vk.PhysicalDevice, device_count, context.temp_allocator)
	vk_try(vk.EnumeratePhysicalDevices(g_instance, &device_count, raw_data(devices)))
	// Pick first
	g_physical_device = devices[0]
	props: vk.PhysicalDeviceProperties
	vk.GetPhysicalDeviceProperties(g_physical_device, &props)
	g_deviceName = bytes_to_string(&props.deviceName)
	vk.GetPhysicalDeviceMemoryProperties(g_physical_device, &g_mem_properties)
	log.infof("Selected device: %s", g_deviceName)
}

@(private = "file")
vk_create_logical_device :: proc() {
	if !find_queue_family_indexes() {
		log.panic("Cannot find device queues: graphics & present")
	}
	graphics_idx := g_queue_family_indexes.graphics
	device_create_info := vk.DeviceCreateInfo {
		sType                   = .DEVICE_CREATE_INFO,
		pNext                   = &vk.PhysicalDeviceFeatures2 {
			sType = .PHYSICAL_DEVICE_FEATURES_2,
			pNext = &vk.PhysicalDeviceVulkan13Features {
				sType = .PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
				pNext = &vk.PhysicalDeviceExtendedDynamicStateFeaturesEXT {
					sType = .PHYSICAL_DEVICE_EXTENDED_DYNAMIC_STATE_FEATURES_EXT,
					extendedDynamicState = true,
				},
				synchronization2 = true,
				dynamicRendering = true,
			},
		},
		pQueueCreateInfos       = &vk.DeviceQueueCreateInfo {
			sType = .DEVICE_QUEUE_CREATE_INFO,
			queueFamilyIndex = graphics_idx,
			queueCount = 1,
			pQueuePriorities = raw_data([]f32{1}),
		},
		queueCreateInfoCount    = 1,
		ppEnabledExtensionNames = raw_data(DEVICE_EXTENSIONS),
		enabledExtensionCount   = u32(len(DEVICE_EXTENSIONS)),
	}
	vk_try(vk.CreateDevice(g_physical_device, &device_create_info, nil, &g_device))
	vk.GetDeviceQueue(g_device, graphics_idx, 0, &g_graphics_queue)
	vk.GetDeviceQueue(g_device, g_queue_family_indexes.present, 0, &g_present_queue)
}

@(private = "file")
find_queue_family_indexes :: proc() -> bool {
	count: u32
	vk.GetPhysicalDeviceQueueFamilyProperties(g_physical_device, &count, nil)

	families := make([]vk.QueueFamilyProperties, count, context.temp_allocator)
	vk.GetPhysicalDeviceQueueFamilyProperties(g_physical_device, &count, raw_data(families))

	graphics_idx := -1
	present_idx := -1
	for family, i in families {
		support_graphics := .GRAPHICS in family.queueFlags
		support_present: b32
		vk_try(
			vk.GetPhysicalDeviceSurfaceSupportKHR(
				g_physical_device,
				u32(i),
				g_surface,
				&support_present,
			),
		)
		if support_graphics {
			graphics_idx = i
		}
		if support_present {
			present_idx = i
		}
		if support_present && support_present {
			break
		}
	}
	if graphics_idx != -1 && present_idx != -1 {
		g_queue_family_indexes.graphics = u32(graphics_idx)
		g_queue_family_indexes.present = u32(present_idx)
		return true
	}
	return false
}

@(private = "file")
vk_create_swapchain :: proc() {
	{
		formats_count: u32
		vk_try(
			vk.GetPhysicalDeviceSurfaceFormatsKHR(
				g_physical_device,
				g_surface,
				&formats_count,
				nil,
			),
		)
		formats := make([]vk.SurfaceFormatKHR, formats_count, context.temp_allocator)
		vk_try(
			vk.GetPhysicalDeviceSurfaceFormatsKHR(
				g_physical_device,
				g_surface,
				&formats_count,
				raw_data(formats),
			),
		)
		present_mode_count: u32
		vk_try(
			vk.GetPhysicalDeviceSurfacePresentModesKHR(
				g_physical_device,
				g_surface,
				&present_mode_count,
				nil,
			),
		)
		present_modes := make([]vk.PresentModeKHR, present_mode_count, context.temp_allocator)
		vk_try(
			vk.GetPhysicalDeviceSurfacePresentModesKHR(
				g_physical_device,
				g_surface,
				&present_mode_count,
				raw_data(present_modes),
			),
		)
		capabilities: vk.SurfaceCapabilitiesKHR
		vk_try(
			vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(
				g_physical_device,
				g_surface,
				&capabilities,
			),
		)

		surface_format := choose_swapchain_surface_format(formats)
		present_mode := choose_swapchain_present_mode(present_modes)
		extent := choose_swapchain_extent(capabilities)
		g_swapchain_format = surface_format
		g_swapchain_extent = extent

		image_count := capabilities.minImageCount + 1
		if capabilities.maxImageCount > 0 {
			image_count = min(image_count, capabilities.maxImageCount)
		}

		create_info := vk.SwapchainCreateInfoKHR {
			sType            = .SWAPCHAIN_CREATE_INFO_KHR,
			surface          = g_surface,
			minImageCount    = image_count,
			imageFormat      = surface_format.format,
			imageColorSpace  = surface_format.colorSpace,
			presentMode      = present_mode,
			imageExtent      = extent,
			imageArrayLayers = 1,
			imageUsage       = {.COLOR_ATTACHMENT},
			preTransform     = capabilities.currentTransform,
			compositeAlpha   = {.OPAQUE},
			clipped          = true,
		}
		if g_queue_family_indexes.graphics != g_queue_family_indexes.present {
			create_info.imageSharingMode = .CONCURRENT
			create_info.queueFamilyIndexCount = 2
			create_info.pQueueFamilyIndices = raw_data(
				[]u32{g_queue_family_indexes.graphics, g_queue_family_indexes.present},
			)
		}
		vk_try(vk.CreateSwapchainKHR(g_device, &create_info, nil, &g_swapchain))
	}

	{
		image_count: u32
		vk_try(vk.GetSwapchainImagesKHR(g_device, g_swapchain, &image_count, nil))
		g_swapchain_image_count = image_count
		g_swapchain_images = make([]vk.Image, image_count)
		vk_try(
			vk.GetSwapchainImagesKHR(
				g_device,
				g_swapchain,
				&image_count,
				raw_data(g_swapchain_images),
			),
		)

		g_swapchain_image_views = make([]vk.ImageView, image_count)
		for image, i in g_swapchain_images {
			create_info := vk.ImageViewCreateInfo {
				sType = .IMAGE_VIEW_CREATE_INFO,
				image = image,
				viewType = .D2,
				format = g_swapchain_format.format,
				subresourceRange = {aspectMask = {.COLOR}, levelCount = 1, layerCount = 1},
			}
			vk_try(vk.CreateImageView(g_device, &create_info, nil, &g_swapchain_image_views[i]))
		}
	}

}

@(private = "file")
vk_destroy_swapchain :: proc() {
	for image_view in g_swapchain_image_views {
		vk.DestroyImageView(g_device, image_view, nil)
	}
	delete(g_swapchain_image_views)
	delete(g_swapchain_images)
	vk.DestroySwapchainKHR(g_device, g_swapchain, nil)
}

@(private = "file")
vk_create_depth_images :: proc() {
	for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
		g_depth_images[i], g_depth_images_memory[i] = create_2d_image(
			.D32_SFLOAT,
			g_swapchain_extent.width,
			g_swapchain_extent.height,
			{.DEPTH_STENCIL_ATTACHMENT, .TRANSIENT_ATTACHMENT},
			.UNDEFINED,
		)
		view_info := vk.ImageViewCreateInfo {
			sType            = .IMAGE_VIEW_CREATE_INFO,
			image            = g_depth_images[i],
			viewType         = .D2,
			format           = .D32_SFLOAT,
			subresourceRange = {{.DEPTH}, 0, 1, 0, 1},
		}
		vk_try(vk.CreateImageView(g_device, &view_info, nil, &g_depth_image_views[i]))
	}
}

@(private = "file")
vk_destroy_depth_images :: proc() {
	for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
		vk.DestroyImageView(g_device, g_depth_image_views[i], nil)
		vk.DestroyImage(g_device, g_depth_images[i], nil)
		vk.FreeMemory(g_device, g_depth_images_memory[i], nil)
	}
}

recreate_swapchain :: proc() {
	w, h := glfw.GetFramebufferSize(g_window)
	if w == 0 || h == 0 {
		return
	}
	vk.DeviceWaitIdle(g_device)
	vk_destroy_depth_images()
	vk_destroy_swapchain()
	vk_create_swapchain()
	vk_create_depth_images()
}

@(private = "file")
choose_swapchain_surface_format :: proc(formats: []vk.SurfaceFormatKHR) -> vk.SurfaceFormatKHR {
	for format in formats {
		if format.format == .B8G8R8A8_SRGB && format.colorSpace == .SRGB_NONLINEAR {
			return format
		}
	}
	return formats[0]
}

@(private = "file")
choose_swapchain_present_mode :: proc(modes: []vk.PresentModeKHR) -> vk.PresentModeKHR {
	// for mode in modes {
	// 	if mode == .MAILBOX {
	// 		return .MAILBOX
	// 	}
	// }
	return .FIFO
}

@(private = "file")
choose_swapchain_extent :: proc(capabilities: vk.SurfaceCapabilitiesKHR) -> vk.Extent2D {
	if capabilities.currentExtent.width != max(u32) {
		return capabilities.currentExtent
	}

	width, height := glfw.GetFramebufferSize(g_window)
	return (vk.Extent2D {
				width = clamp(
					u32(width),
					capabilities.minImageExtent.width,
					capabilities.maxImageExtent.width,
				),
				height = clamp(
					u32(height),
					capabilities.minImageExtent.height,
					capabilities.maxImageExtent.height,
				),
			})
}
