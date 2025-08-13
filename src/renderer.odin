package vspace

import "core:log"
import "core:math"
import "core:math/linalg"
import "core:math/linalg/glsl"
import "core:mem"
import "core:time"
import vk "vendor:vulkan"

SHADER_FILE :: "shaders/shaders.spv"

MAX_BLOCKS_IN_BUFFER :: 1024
VERTICES_IN_BLOCK :: 36

g_pipeline: vk.Pipeline
g_pipeline_layout: vk.PipelineLayout
g_vertex_buffer: vk.Buffer
g_vertex_buffer_memory: vk.DeviceMemory
g_vertex_buffer_mapped: rawptr

BlockData :: struct {
	pos:   glsl.vec3,
	color: glsl.vec3,
}

SceneConstants :: struct {
	mvp: glsl.mat4,
}

g_scene: SceneConstants
g_cameraPos: glsl.vec3
g_cameraMat: glsl.mat4
g_projMat: glsl.mat4
g_fov: f32 = 45.0
g_world_timer: time.Stopwatch

INPUT :: []BlockData {
	{{0.0, -1.0, -2.0}, {0.4, 0.8, 0.8}},
	{{0.0, -1.0, -3.0}, {0.5, 0.8, 0.8}},
	{{0.0, -2.0, -3.0}, {0.6, 0.8, 0.8}},
	{{1.0, -2.0, -3.0}, {0.1, 0.8, 0.8}},
}

create_renderer :: proc() {
	time.stopwatch_start(&g_world_timer)
	create_pipeline()
	create_resources()
}

destroy_renderer :: proc() {
	destroy_resources()
	destroy_pipeline()
}

update :: proc() {
	{
		angle_xy := math.to_radians(g_yaw)
		c := f32(math.cos(angle_xy))
		s := f32(math.sin(angle_xy))
		movement := [3]f32 {
			c * g_movement_vector[0] - s * g_movement_vector[2],
			g_movement_vector[1],
			s * g_movement_vector[0] + c * g_movement_vector[2],
		}
		g_cameraPos += movement * {g_speed, g_speed, g_speed}
	}
	yaw_rad := f32(math.to_radians(g_yaw))
	pitch_rad := f32(math.to_radians(g_pitch))
	rot_matrix := linalg.matrix4_from_euler_angles_xyz(pitch_rad, yaw_rad, 0)
	g_cameraMat = rot_matrix * linalg.matrix4_translate(-g_cameraPos * {1, -1, 1})
	aspect_ratio := f32(g_swapchain_extent.width) / f32(g_swapchain_extent.height)
	g_projMat = glsl.mat4Perspective(g_fov, aspect_ratio, 0.05, 1000)
	g_scene.mvp = g_projMat * g_cameraMat
}

record_commands :: proc(cmd_buffer: vk.CommandBuffer, frame_index, image_index: u32) {
	begin_info := vk.CommandBufferBeginInfo {
		sType = .COMMAND_BUFFER_BEGIN_INFO,
	}
	vk.BeginCommandBuffer(cmd_buffer, &begin_info)

	current_image := g_swapchain_images[image_index]
	transition_image_layout(
		cmd_buffer,
		current_image,
		.UNDEFINED,
		.COLOR_ATTACHMENT_OPTIMAL,
		{},
		{.COLOR_ATTACHMENT_WRITE},
		{.TOP_OF_PIPE},
		{.COLOR_ATTACHMENT_OUTPUT},
		{.COLOR}
	)
	transition_image_layout(
		cmd_buffer,
		g_depth_images[frame_index],
		.UNDEFINED,
		.DEPTH_ATTACHMENT_OPTIMAL,
		{},
		{.DEPTH_STENCIL_ATTACHMENT_WRITE},
		{.TOP_OF_PIPE},
		{.EARLY_FRAGMENT_TESTS},
		{.DEPTH}
	)
	clear_color := vk.ClearValue {
		color = {float32 = [4]f32{0.1, 0.1, 0.1, 1.}},
	}
	color_attachment := vk.RenderingAttachmentInfo {
		sType       = .RENDERING_ATTACHMENT_INFO,
		imageView   = g_swapchain_image_views[image_index],
		imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
		loadOp      = .CLEAR,
		storeOp     = .STORE,
		clearValue  = clear_color,
	}
	clear_depth := vk.ClearValue {
		depthStencil = {1.0, 0},
	}
	depth_attachment := vk.RenderingAttachmentInfo {
		sType       = .RENDERING_ATTACHMENT_INFO,
		imageView   = g_depth_image_views[frame_index],
		imageLayout = .DEPTH_ATTACHMENT_OPTIMAL,
		loadOp      = .CLEAR,
		storeOp     = .DONT_CARE,
		clearValue  = clear_depth,
	}
	rendering_info := vk.RenderingInfo {
		sType = .RENDERING_INFO,
		renderArea = {offset = {0, 0}, extent = g_swapchain_extent},
		layerCount = 1,
		colorAttachmentCount = 1,
		pColorAttachments = &color_attachment,
		pDepthAttachment = &depth_attachment,
	}
	vk.CmdBeginRendering(cmd_buffer, &rendering_info)
	vk.CmdBindPipeline(cmd_buffer, .GRAPHICS, g_pipeline)
	vk.CmdSetViewport(
		cmd_buffer,
		0,
		1,
		&vk.Viewport {
			x = 0,
			y = 0,
			width = auto_cast g_swapchain_extent.width,
			height = auto_cast g_swapchain_extent.height,
			minDepth = 0,
			maxDepth = 1,
		},
	)
	vk.CmdSetScissor(cmd_buffer, 0, 1, &vk.Rect2D{offset = {0, 0}, extent = g_swapchain_extent})
	vk.CmdBindVertexBuffers(cmd_buffer, 0, 1, &g_vertex_buffer, raw_data([]vk.DeviceSize{0}))
	vk.CmdPushConstants(
		cmd_buffer,
		g_pipeline_layout,
		{.VERTEX},
		0,
		size_of(SceneConstants),
		&g_scene,
	)
	vk.CmdDraw(cmd_buffer, VERTICES_IN_BLOCK, u32(len(INPUT)), 0, 0)
	vk.CmdEndRendering(cmd_buffer)
	transition_image_layout(
		cmd_buffer,
		current_image,
		.COLOR_ATTACHMENT_OPTIMAL,
		.PRESENT_SRC_KHR,
		{.COLOR_ATTACHMENT_WRITE},
		{},
		{.COLOR_ATTACHMENT_OUTPUT},
		{.BOTTOM_OF_PIPE},
		{.COLOR}
	)
	vk.EndCommandBuffer(cmd_buffer)
}

@(private = "file")
create_resources :: proc() {
	buffer_info := vk.BufferCreateInfo {
		sType       = .BUFFER_CREATE_INFO,
		size        = size_of(BlockData) * MAX_BLOCKS_IN_BUFFER,
		sharingMode = .EXCLUSIVE,
		usage       = {.VERTEX_BUFFER},
	}
	vk_try(vk.CreateBuffer(g_device, &buffer_info, nil, &g_vertex_buffer))
	memory_requirements: vk.MemoryRequirements
	vk.GetBufferMemoryRequirements(g_device, g_vertex_buffer, &memory_requirements)
	g_vertex_buffer_memory = try_allocate(memory_requirements, {.HOST_VISIBLE, .HOST_COHERENT})
	vk_try(vk.BindBufferMemory(g_device, g_vertex_buffer, g_vertex_buffer_memory, 0))
	vk_try(
		vk.MapMemory(
			g_device,
			g_vertex_buffer_memory,
			0,
			buffer_info.size,
			{},
			&g_vertex_buffer_mapped,
		),
	)
	mem.copy(g_vertex_buffer_mapped, raw_data(INPUT), len(INPUT) * size_of(BlockData))
	log.info("Created renderer resources")
}

@(private = "file")
destroy_resources :: proc() {
	vk.DestroyBuffer(g_device, g_vertex_buffer, nil)
	vk.FreeMemory(g_device, g_vertex_buffer_memory, nil)
}

recreate_pipeline :: proc() {
	destroy_pipeline()
	create_pipeline()
}

@(private = "file")
create_pipeline :: proc() {
	push_constant_ranges := []vk.PushConstantRange {
		{stageFlags = {.VERTEX}, offset = 0, size = size_of(SceneConstants)},
	}
	layout_info := vk.PipelineLayoutCreateInfo {
		sType                  = .PIPELINE_LAYOUT_CREATE_INFO,
		pushConstantRangeCount = 1,
		pPushConstantRanges    = raw_data(push_constant_ranges),
	}
	vk_try(vk.CreatePipelineLayout(g_device, &layout_info, nil, &g_pipeline_layout))

	dynamic_states := []vk.DynamicState{.VIEWPORT, .SCISSOR}
	dynamic_state := vk.PipelineDynamicStateCreateInfo {
		sType             = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
		dynamicStateCount = 2,
		pDynamicStates    = raw_data(dynamic_states),
	}
	vertex_bindings := []vk.VertexInputBindingDescription {
		{binding = 0, stride = size_of(BlockData), inputRate = .INSTANCE},
	}
	attribute_descriptions := []vk.VertexInputAttributeDescription {
		{0, 0, .R32G32B32_SFLOAT, u32(offset_of(BlockData, pos))},
		{1, 0, .R32G32B32_SFLOAT, u32(offset_of(BlockData, color))},
	}
	vertex_input_info := vk.PipelineVertexInputStateCreateInfo {
		sType                           = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
		vertexBindingDescriptionCount   = u32(len(vertex_bindings)),
		pVertexBindingDescriptions      = raw_data(vertex_bindings),
		vertexAttributeDescriptionCount = u32(len(attribute_descriptions)),
		pVertexAttributeDescriptions    = raw_data(attribute_descriptions),
	}
	input_assembly := vk.PipelineInputAssemblyStateCreateInfo {
		sType    = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
		topology = .TRIANGLE_LIST,
	}
	viewport_state := vk.PipelineViewportStateCreateInfo {
		sType         = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
		viewportCount = 1,
		scissorCount  = 1,
	}
	rasterizer := vk.PipelineRasterizationStateCreateInfo {
		sType       = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
		polygonMode = .FILL,
		lineWidth   = 1,
		cullMode    = {.BACK},
		frontFace   = .CLOCKWISE,
	}
	multisampling := vk.PipelineMultisampleStateCreateInfo {
		sType                = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
		rasterizationSamples = {._1},
		minSampleShading     = 1,
	}
	color_blend_attachment := vk.PipelineColorBlendAttachmentState {
		colorWriteMask = {.R, .G, .B, .A},
	}
	color_blending := vk.PipelineColorBlendStateCreateInfo {
		sType           = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
		attachmentCount = 1,
		pAttachments    = &color_blend_attachment,
	}
	depth_stencil_state := vk.PipelineDepthStencilStateCreateInfo {
		sType            = .PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
		depthTestEnable  = true,
		depthWriteEnable = true,
		depthCompareOp   = .LESS,
	}

	module, success := load_shaders_from_file(SHADER_FILE)
	if !success {
		log.panicf("Failed to load shaders, check if file exists")
	}
	vertex_shader_info := vk.PipelineShaderStageCreateInfo {
		sType  = .PIPELINE_SHADER_STAGE_CREATE_INFO,
		stage  = {.VERTEX},
		module = module,
		pName  = "vsMain",
	}
	pixel_shader_info := vk.PipelineShaderStageCreateInfo {
		sType  = .PIPELINE_SHADER_STAGE_CREATE_INFO,
		stage  = {.FRAGMENT},
		module = module,
		pName  = "psMain",
	}
	shader_stages := []vk.PipelineShaderStageCreateInfo{vertex_shader_info, pixel_shader_info}
	pipeline_rendering_info := vk.PipelineRenderingCreateInfo {
		sType                   = .PIPELINE_RENDERING_CREATE_INFO,
		colorAttachmentCount    = 1,
		pColorAttachmentFormats = &g_swapchain_format.format,
		depthAttachmentFormat   = .D32_SFLOAT,
		stencilAttachmentFormat = .UNDEFINED,
	}
	pipeline_info := vk.GraphicsPipelineCreateInfo {
		sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
		pNext               = &pipeline_rendering_info,
		stageCount          = 2,
		pStages             = raw_data(shader_stages),
		pVertexInputState   = &vertex_input_info,
		pInputAssemblyState = &input_assembly,
		pViewportState      = &viewport_state,
		pRasterizationState = &rasterizer,
		pMultisampleState   = &multisampling,
		pColorBlendState    = &color_blending,
		pDynamicState       = &dynamic_state,
		pDepthStencilState  = &depth_stencil_state,
		layout              = g_pipeline_layout,
		subpass             = 0,
		basePipelineIndex   = -1,
	}
	vk_try(vk.CreateGraphicsPipelines(g_device, 0, 1, &pipeline_info, nil, &g_pipeline))

	vk.DestroyShaderModule(g_device, module, nil)
}

@(private = "file")
destroy_pipeline :: proc() {
	vk.DestroyPipelineLayout(g_device, g_pipeline_layout, nil)
	vk.DestroyPipeline(g_device, g_pipeline, nil)
}
