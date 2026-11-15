FRAMES_IN_FLIGHT :: 2;

DEPTH_FORMAT : VkFormat : .D32_SFLOAT;
HDR_FORMAT   : VkFormat : .R16G16B16A16_SFLOAT;

frame_context : struct {
    index                      : u64;
    timeline_semaphore         : VkSemaphore;
    command_pool               : VkCommandPool;
    command_buffers            : [FRAMES_IN_FLIGHT] VkCommandBuffer;
    init_command_buffer        : VkCommandBuffer;
    image_available_semaphores : [FRAMES_IN_FLIGHT] VkSemaphore;
    present_ready_semaphores   : [MAX_SWAPCHAIN_IMAGES] VkSemaphore;
    present_fences             : [MAX_SWAPCHAIN_IMAGES] VkFence;

    timestamp_pool : VkQueryPool;
    gpu_ms         : float;

    material_shaders : [2] VkShaderEXT;
    depth_shaders    : [2] VkShaderEXT;
    tonemap_shaders  : [2] VkShaderEXT;

    depth_image : VkImage;
    depth_view  : VkImageView;
    hdr_image   : VkImage;
    hdr_view    : VkImageView;
    hdr_texture : Texture_Handle;
}

create_render_targets :: () {
    create :: (format: VkFormat, usage: VkImageUsageFlags, aspect: VkImageAspectFlags, name: string) -> VkImage, VkImageView, VkImageViewCreateInfo {
        image_create_info := VkImageCreateInfo.{
            imageType   = .e2D,
            format      = format,
            extent      = .{width = swapchain_context.extent.width, height = swapchain_context.extent.height, depth = 1},
            mipLevels   = 1,
            arrayLayers = 1,
            samples     = .e1,
            tiling      = .OPTIMAL,
            usage       = usage,
        };
        image : VkImage;
        result := vkCreateImage(device_context.device, *image_create_info, null, *image);
        assert(result == .SUCCESS);
        heap_bind_image(*heap_context.render_target, image);

        view_create_info := VkImageViewCreateInfo.{
            image            = image,
            viewType         = .e2D,
            format           = format,
            subresourceRange = .{aspectMask = aspect, levelCount = 1, layerCount = 1},
        };
        view : VkImageView;
        result = vkCreateImageView(device_context.device, *view_create_info, null, *view);
        assert(result == .SUCCESS);

        set_debug_name(.IMAGE,      image, name);
        set_debug_name(.IMAGE_VIEW, view,  name);
        return image, view, view_create_info;
    }

    frame_context.depth_image, frame_context.depth_view = create(DEPTH_FORMAT, .DEPTH_STENCIL_ATTACHMENT, .DEPTH, "depth");

    hdr_view_info : VkImageViewCreateInfo;
    frame_context.hdr_image, frame_context.hdr_view, hdr_view_info = create(HDR_FORMAT, .COLOR_ATTACHMENT | .SAMPLED, .COLOR, "hdr");
    write_image_descriptor(frame_context.hdr_texture.id, .SAMPLED_IMAGE, hdr_view_info);
}

destroy_render_targets :: () {
    vkDestroyImageView(device_context.device, frame_context.hdr_view, null);
    vkDestroyImage(device_context.device, frame_context.hdr_image, null);
    vkDestroyImageView(device_context.device, frame_context.depth_view, null);
    vkDestroyImage(device_context.device, frame_context.depth_image, null);
    heap_reset(*heap_context.render_target);
}

recreate_swapchain :: () -> ready: bool {
    capabilities : VkSurfaceCapabilitiesKHR;
    vkGetPhysicalDeviceSurfaceCapabilitiesKHR(device_context.physical_device, device_context.surface, *capabilities);
    if capabilities.currentExtent.width == 0 || capabilities.currentExtent.height == 0  return false;

    vkDeviceWaitIdle(device_context.device);
    result := vkWaitForFences(device_context.device, MAX_SWAPCHAIN_IMAGES, frame_context.present_fences.data, VK_TRUE, U64_MAX);
    assert(result == .SUCCESS);

    destroy_render_targets();
    deinit_swapchain();
    init_swapchain();
    create_render_targets();

    swapchain_context.needs_recreation = false;
    return true;
}

Frame_Constants :: struct @Gpu {
    view_projection : Matrix4;
    tlas_address    : u64;
    light_direction : Vector3;
    sun_intensity   : float;
    camera_position : Vector3;
    debug_view      : u32;
}

Debug_View :: enum s32 {
    LIT;
    BASE_COLOR;
    NORMALS;
    METALLIC_ROUGHNESS;
    SUN_ONLY;
    AMBIENT_ONLY;
}

DEBUG_VIEW_NAMES :: "Lit\0Base color\0Normals\0Metallic (R) / roughness (G)\0Sun only\0Ambient only\0\0";

Push_Data :: struct @Gpu {
    frame      : Gpu_Pointer(Frame_Constants);
    draws      : Gpu_Pointer(Draw_Data);
    materials  : Gpu_Pointer(Material);
}

Tonemap_Push_Data :: struct @Gpu {
    hdr      : Texture_Handle;
    exposure : float;
    raw      : u32;
}

init_render :: () {
    result : VkResult;

    command_pool_create_info := VkCommandPoolCreateInfo.{flags = .RESET_COMMAND_BUFFER, queueFamilyIndex = device_context.queue_family_index};
    result = vkCreateCommandPool(device_context.device, *command_pool_create_info, null, *frame_context.command_pool);
    assert(result == .SUCCESS);

    command_buffer_allocate_info := VkCommandBufferAllocateInfo.{commandPool = frame_context.command_pool, level = .PRIMARY, commandBufferCount = FRAMES_IN_FLIGHT};
    result = vkAllocateCommandBuffers(device_context.device, *command_buffer_allocate_info, frame_context.command_buffers.data);
    assert(result == .SUCCESS);
    for frame_context.command_buffers  set_debug_name(.COMMAND_BUFFER, it, tprint("frame command buffer %", it_index));

    command_buffer_allocate_info.commandBufferCount = 1;
    result = vkAllocateCommandBuffers(device_context.device, *command_buffer_allocate_info, *frame_context.init_command_buffer);
    assert(result == .SUCCESS);
    set_debug_name(.COMMAND_BUFFER, frame_context.init_command_buffer, "init command buffer");

    semaphore_create_info : VkSemaphoreCreateInfo;
    fence_create_info := VkFenceCreateInfo.{flags = .SIGNALED};
    for 0..MAX_SWAPCHAIN_IMAGES-1 {
        vkCreateSemaphore(device_context.device, *semaphore_create_info, null, *frame_context.present_ready_semaphores[it]);
        set_debug_name(.SEMAPHORE, frame_context.present_ready_semaphores[it], tprint("present ready semaphore %", it));
        vkCreateFence(device_context.device, *fence_create_info, null, *frame_context.present_fences[it]);
        set_debug_name(.FENCE, frame_context.present_fences[it], tprint("present fence %", it));
    }
    for 0..FRAMES_IN_FLIGHT-1 {
        vkCreateSemaphore(device_context.device, *semaphore_create_info, null, *frame_context.image_available_semaphores[it]);
        set_debug_name(.SEMAPHORE, frame_context.image_available_semaphores[it], tprint("image available semaphore %", it));
    }

    semaphore_type_create_info := VkSemaphoreTypeCreateInfo.{semaphoreType = .TIMELINE};
    timeline_semaphore_create_info := VkSemaphoreCreateInfo.{pNext = *semaphore_type_create_info};
    vkCreateSemaphore(device_context.device, *timeline_semaphore_create_info, null, *frame_context.timeline_semaphore);
    set_debug_name(.SEMAPHORE, frame_context.timeline_semaphore, "frame timeline semaphore");

    query_pool_create_info := VkQueryPoolCreateInfo.{queryType = .TIMESTAMP, queryCount = FRAMES_IN_FLIGHT * 2};
    result = vkCreateQueryPool(device_context.device, *query_pool_create_info, null, *frame_context.timestamp_pool);
    assert(result == .SUCCESS);
    set_debug_name(.QUERY_POOL, frame_context.timestamp_pool, "frame timestamp pool");

    frame_context.material_shaders = create_graphics_shaders("material");
    frame_context.tonemap_shaders  = create_graphics_shaders("tonemap");
    frame_context.depth_shaders    = create_graphics_shaders("material", "depth_fragment_main");

    frame_context.hdr_texture = .{id = reserve_image_descriptor()};
    create_render_targets();
}

deinit_render :: () {
    destroy_render_targets();
    destroy_graphics_shaders(frame_context.material_shaders);
    destroy_graphics_shaders(frame_context.tonemap_shaders);
    destroy_graphics_shaders(frame_context.depth_shaders);
    result := vkWaitForFences(device_context.device, MAX_SWAPCHAIN_IMAGES, frame_context.present_fences.data, VK_TRUE, U64_MAX);
    assert(result == .SUCCESS);

    for image_index : 0..MAX_SWAPCHAIN_IMAGES-1 {
        vkDestroyFence(device_context.device, frame_context.present_fences[image_index], null);
        vkDestroySemaphore(device_context.device, frame_context.present_ready_semaphores[image_index], null);
    }
    for index : 0..FRAMES_IN_FLIGHT-1 {
        vkDestroySemaphore(device_context.device, frame_context.image_available_semaphores[index], null);
    }
    vkDestroySemaphore(device_context.device, frame_context.timeline_semaphore, null);
    vkDestroyQueryPool(device_context.device, frame_context.timestamp_pool, null);
    vkDestroyCommandPool(device_context.device, frame_context.command_pool, null);
}

set_draw_state :: (command_buffer: VkCommandBuffer) {
    vkCmdSetRasterizerDiscardEnable(command_buffer, VK_FALSE);
    vkCmdSetPrimitiveRestartEnable(command_buffer,  VK_FALSE);

    vkCmdSetPrimitiveTopology(command_buffer,       .TRIANGLE_LIST);

    vkCmdSetDepthTestEnable(command_buffer,         VK_TRUE);
    vkCmdSetDepthWriteEnable(command_buffer,        VK_TRUE);
    vkCmdSetDepthCompareOp(command_buffer,          .LESS);
    vkCmdSetDepthBiasEnable(command_buffer,         VK_FALSE);
    vkCmdSetDepthBoundsTestEnable(command_buffer,   VK_FALSE);
    vkCmdSetDepthClampEnableEXT(command_buffer,     VK_FALSE);

    vkCmdSetStencilTestEnable(command_buffer,       VK_FALSE);

    vkCmdSetPolygonModeEXT(command_buffer,          .FILL);
    vkCmdSetFrontFace(command_buffer,               .CLOCKWISE);
    vkCmdSetCullMode(command_buffer,                .NONE);

    vkCmdSetAlphaToOneEnableEXT(command_buffer,     VK_FALSE);
    vkCmdSetAlphaToCoverageEnableEXT(command_buffer,VK_FALSE);
    vkCmdSetLogicOpEnableEXT(command_buffer,        VK_FALSE);

    color_blend_enable : VkBool32 = VK_FALSE;
    vkCmdSetColorBlendEnableEXT(command_buffer, 0, 1, *color_blend_enable);

    color_write_mask := VkColorComponentFlags.R | .G | .B | .A;
    vkCmdSetColorWriteMaskEXT(command_buffer, 0, 1, *color_write_mask);

    vkCmdSetRasterizationSamplesEXT(command_buffer, .e1);
    sample_mask : VkSampleMask = 1;
    vkCmdSetSampleMaskEXT(command_buffer, .e1, *sample_mask);

    viewport := VkViewport.{width = xx swapchain_context.extent.width, height = xx swapchain_context.extent.height, maxDepth = 1};
    vkCmdSetViewportWithCount(command_buffer, 1, *viewport);

    scissor := VkRect2D.{extent = swapchain_context.extent};
    vkCmdSetScissorWithCount(command_buffer, 1, *scissor);

    vkCmdSetVertexInputEXT(command_buffer, 0, null, 0, null);
}

draw_frame :: () {
    result : VkResult;

    frame_context.index += 1;
    index := frame_context.index % FRAMES_IN_FLIGHT;

    wait_value : u64 = ifx frame_context.index > FRAMES_IN_FLIGHT then frame_context.index - FRAMES_IN_FLIGHT else 0;
    semaphore_wait_info := VkSemaphoreWaitInfo.{semaphoreCount = 1, pSemaphores = *frame_context.timeline_semaphore, pValues = *wait_value};
    result = vkWaitSemaphores(device_context.device, *semaphore_wait_info, U64_MAX);
    assert(result == .SUCCESS);

    frame_heap := *heap_context.frames[index];
    heap_reset(frame_heap);

    if frame_context.index > FRAMES_IN_FLIGHT {
        timestamps : [2] u64;
        result = vkGetQueryPoolResults(device_context.device, frame_context.timestamp_pool, xx (index * 2), 2, size_of(type_of(timestamps)), timestamps.data, size_of(u64), .e64);
        assert(result == .SUCCESS);

        period := device_context.limits.timestampPeriod;
        frame_context.gpu_ms = cast(float) (timestamps[1] - timestamps[0]) * period / 1_000_000.0;
    }

    image_index: u32;
    result = vkAcquireNextImageKHR(device_context.device, swapchain_context.swapchain, U64_MAX, frame_context.image_available_semaphores[index], VK_NULL_HANDLE, *image_index);
    if result == .ERROR_OUT_OF_DATE_KHR {
        frame_context.index -= 1;
        swapchain_context.needs_recreation = true;
        return;
    }
    if result == .SUBOPTIMAL_KHR {
        swapchain_context.needs_recreation = true;
    }
    else {
        assert(result == .SUCCESS, "vkAcquireNextImageKHR failed: %", result);
    }

    result = vkWaitForFences(device_context.device, 1, *frame_context.present_fences[image_index], VK_TRUE, U64_MAX);
    assert(result == .SUCCESS);
    result = vkResetFences(device_context.device, 1, *frame_context.present_fences[image_index]);
    assert(result == .SUCCESS);

    begin_info := VkCommandBufferBeginInfo.{flags = .ONE_TIME_SUBMIT};
    result = vkBeginCommandBuffer(frame_context.command_buffers[index], *begin_info);
    assert(result == .SUCCESS);

    vkCmdResetQueryPool(frame_context.command_buffers[index], frame_context.timestamp_pool, xx (index * 2), 2);
    vkCmdWriteTimestamp2(frame_context.command_buffers[index], .NONE, frame_context.timestamp_pool, xx (index * 2));

    pipeline_barrier(frame_context.command_buffers[index], .[
        image_barrier(swapchain_context.images[image_index], .COLOR_ATTACHMENT_OUTPUT, .NONE, .COLOR_ATTACHMENT_OUTPUT, .COLOR_ATTACHMENT_WRITE),
        image_barrier(frame_context.depth_image, .EARLY_FRAGMENT_TESTS | .LATE_FRAGMENT_TESTS, .NONE, .EARLY_FRAGMENT_TESTS | .LATE_FRAGMENT_TESTS, .DEPTH_STENCIL_ATTACHMENT_READ | .DEPTH_STENCIL_ATTACHMENT_WRITE, aspect = .DEPTH),
        image_barrier(frame_context.hdr_image, .FRAGMENT_SHADER, .NONE, .COLOR_ATTACHMENT_OUTPUT, .COLOR_ATTACHMENT_WRITE),
    ]);

    color_attachment := VkRenderingAttachmentInfoKHR.{imageView = frame_context.hdr_view, imageLayout = .GENERAL, loadOp = .CLEAR, storeOp = .STORE};
    color_attachment.clearValue.color.float32_ = xx srgb(0.1, 0.1, 0.12).component;

    depth_attachment := VkRenderingAttachmentInfoKHR.{imageView = frame_context.depth_view, imageLayout = .GENERAL, loadOp = .CLEAR, storeOp = .DONT_CARE};
    depth_attachment.clearValue.depthStencil = .{depth = 1};

    rendering_info := VkRenderingInfo.{
        renderArea           = .{extent = swapchain_context.extent},
        layerCount           = 1,
        colorAttachmentCount = 1,
        pColorAttachments    = *color_attachment,
        pDepthAttachment     = *depth_attachment,
    };
    vkCmdBeginRendering(frame_context.command_buffers[index], *rendering_info);

    bind_descriptor_heaps(frame_context.command_buffers[index]);
    set_draw_state(frame_context.command_buffers[index]);

    frame_constants_offset := heap_allocate(frame_heap, size_of(Frame_Constants), 256);
    aspect := cast(float) swapchain_context.extent.width / cast(float) swapchain_context.extent.height;

    frame_constants := cast(*Frame_Constants) heap_pointer(frame_heap, frame_constants_offset);
    frame_constants.view_projection = camera_view_projection(aspect);
    frame_constants.tlas_address    = scene_context.tlas_address;
    frame_constants.light_direction = main_context.light_direction;
    frame_constants.sun_intensity   = main_context.sun_intensity;
    frame_constants.camera_position = camera_context.position;
    frame_constants.debug_view      = cast(u32) main_context.debug_view;

    push_data := Push_Data.{
        frame     = heap_gpu_pointer(frame_heap, Frame_Constants, frame_constants_offset),
        draws     = heap_gpu_pointer(*heap_context.buffer, Draw_Data, scene_context.draws_offset),
        materials = heap_gpu_pointer(*heap_context.buffer, Material, scene_context.materials_offset),
    };

    push_data_info := VkPushDataInfoEXT.{data = .{address = *push_data, size = size_of(Push_Data)}};
    vkCmdPushDataEXT(frame_context.command_buffers[index], *push_data_info);

    index_buffer_info := VkBindIndexBuffer3InfoKHR.{
        addressRange = .{address = heap_context.buffer.address, size = heap_context.buffer.size},
        addressFlags = .STORAGE_BUFFER_USAGE,
        indexType    = .UINT32,
    };
    vkCmdBindIndexBuffer3KHR(frame_context.command_buffers[index], *index_buffer_info);

    draw_info := VkDrawIndirect2InfoKHR.{
        addressRange = .{
            address = heap_address(*heap_context.buffer, scene_context.draw_commands_offset),
            size    = xx (scene_context.draws.count * size_of(VkDrawIndexedIndirectCommand)),
            stride  = size_of(VkDrawIndexedIndirectCommand),
        },
        addressFlags = .STORAGE_BUFFER_USAGE,
        drawCount    = xx scene_context.draws.count,
    };

    no_components : VkColorComponentFlags;
    vkCmdSetColorWriteMaskEXT(frame_context.command_buffers[index], 0, 1, *no_components);
    bind_graphics_shaders(frame_context.command_buffers[index], frame_context.depth_shaders);
    vkCmdDrawIndexedIndirect2KHR(frame_context.command_buffers[index], *draw_info);

    all_components := VkColorComponentFlags.R | .G | .B | .A;
    vkCmdSetColorWriteMaskEXT(frame_context.command_buffers[index], 0, 1, *all_components);
    vkCmdSetDepthWriteEnable(frame_context.command_buffers[index], VK_FALSE);
    vkCmdSetDepthCompareOp(frame_context.command_buffers[index], .EQUAL);
    bind_graphics_shaders(frame_context.command_buffers[index], frame_context.material_shaders);
    vkCmdDrawIndexedIndirect2KHR(frame_context.command_buffers[index], *draw_info);

    vkCmdEndRendering(frame_context.command_buffers[index]);

    memory_barrier(frame_context.command_buffers[index], .COLOR_ATTACHMENT_OUTPUT, .COLOR_ATTACHMENT_WRITE, .FRAGMENT_SHADER, .SHADER_SAMPLED_READ);

    swapchain_attachment := VkRenderingAttachmentInfoKHR.{
        imageView   = swapchain_context.views[image_index],
        imageLayout = .GENERAL,
        loadOp      = .DONT_CARE,
        storeOp     = .STORE,
    };
    tonemap_rendering_info := VkRenderingInfo.{
        renderArea           = .{extent = swapchain_context.extent},
        layerCount           = 1,
        colorAttachmentCount = 1,
        pColorAttachments    = *swapchain_attachment,
    };
    vkCmdBeginRendering(frame_context.command_buffers[index], *tonemap_rendering_info);

    vkCmdSetDepthTestEnable(frame_context.command_buffers[index],  VK_FALSE);
    vkCmdSetDepthWriteEnable(frame_context.command_buffers[index], VK_FALSE);
    bind_graphics_shaders(frame_context.command_buffers[index], frame_context.tonemap_shaders);

    tonemap_push_data := Tonemap_Push_Data.{hdr = frame_context.hdr_texture, exposure = main_context.exposure, raw = xx (main_context.debug_view != .LIT)};
    tonemap_push_data_info := VkPushDataInfoEXT.{data = .{address = *tonemap_push_data, size = size_of(Tonemap_Push_Data)}};
    vkCmdPushDataEXT(frame_context.command_buffers[index], *tonemap_push_data_info);

    vkCmdDraw(frame_context.command_buffers[index], vertexCount = 3, instanceCount = 1, firstVertex = 0, firstInstance = 0);

    render_imgui(frame_context.command_buffers[index], frame_heap);

    vkCmdEndRendering(frame_context.command_buffers[index]);

    if screenshot_context.requested {
        record_screenshot_copy(frame_context.command_buffers[index], swapchain_context.images[image_index]);
    }

    pipeline_barrier(frame_context.command_buffers[index], .[image_barrier(swapchain_context.images[image_index], .COLOR_ATTACHMENT_OUTPUT | .COPY, .COLOR_ATTACHMENT_WRITE, .NONE, .NONE, old_layout = .GENERAL, new_layout = .PRESENT_SRC_KHR)]);

    vkCmdWriteTimestamp2(frame_context.command_buffers[index], .ALL_COMMANDS, frame_context.timestamp_pool, xx (index * 2 + 1));

    result = vkEndCommandBuffer(frame_context.command_buffers[index]);
    assert(result == .SUCCESS);

    wait_info := VkSemaphoreSubmitInfo.{semaphore = frame_context.image_available_semaphores[index], stageMask = .COLOR_ATTACHMENT_OUTPUT};
    signal_infos := VkSemaphoreSubmitInfo.[
        .{semaphore = frame_context.present_ready_semaphores[image_index], stageMask = .ALL_COMMANDS},
        .{semaphore = frame_context.timeline_semaphore, value = frame_context.index, stageMask = .ALL_COMMANDS},
    ];
    command_buffer_info := VkCommandBufferSubmitInfo.{commandBuffer = frame_context.command_buffers[index]};
    submit_info := VkSubmitInfo2.{
        waitSemaphoreInfoCount   = 1,
        pWaitSemaphoreInfos      = *wait_info,
        commandBufferInfoCount   = 1,
        pCommandBufferInfos      = *command_buffer_info,
        signalSemaphoreInfoCount = signal_infos.count,
        pSignalSemaphoreInfos    = signal_infos.data,
    };
    result = vkQueueSubmit2(device_context.queue, 1, *submit_info, VK_NULL_HANDLE);
    assert(result == .SUCCESS);

    present_fence_info := VkSwapchainPresentFenceInfoKHR.{swapchainCount = 1, pFences = *frame_context.present_fences[image_index]};
    present_info := VkPresentInfoKHR.{
        pNext              = *present_fence_info,
        waitSemaphoreCount = 1,
        pWaitSemaphores    = *frame_context.present_ready_semaphores[image_index],
        swapchainCount     = 1,
        pSwapchains        = *swapchain_context.swapchain,
        pImageIndices      = *image_index,
    };
    result = vkQueuePresentKHR(device_context.queue, *present_info);
    if result == .ERROR_OUT_OF_DATE_KHR || result == .SUBOPTIMAL_KHR {
        swapchain_context.needs_recreation = true;
    } else {
        assert(result == .SUCCESS, "vkQueuePresentKHR failed: %", result);
    }
}
