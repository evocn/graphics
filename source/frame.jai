FRAMES_IN_FLIGHT :: 2;

frame_index                : u64;
timeline_semaphore         : VkSemaphore;
command_pool               : VkCommandPool;
command_buffers            : [FRAMES_IN_FLIGHT] VkCommandBuffer;
init_command_buffer        : VkCommandBuffer;
image_available_semaphores : [FRAMES_IN_FLIGHT] VkSemaphore;
present_ready_semaphores   : [MAX_SWAPCHAIN_IMAGES] VkSemaphore;
present_fences             : [MAX_SWAPCHAIN_IMAGES] VkFence;

frame_constants_offset : VkDeviceSize;

ambient_write_index      : u32;
previous_view_projection : Matrix4;
previous_camera_position : Vector3;

timestamp_pool : VkQueryPool;
gpu_frame_ms   : float;

material_shaders : [2] VkShaderEXT;
depth_shaders    : [2] VkShaderEXT;
tonemap_shaders  : [2] VkShaderEXT;

screenshot_requested      : bool;
screenshot_captured       : bool;
screenshot_offset         : VkDeviceSize;
screenshot_allocated_size : VkDeviceSize;
screenshot_extent         : VkExtent2D;
screenshot_format         : VkFormat;

DEPTH_FORMAT   : VkFormat : .D32_SFLOAT;
HDR_FORMAT     : VkFormat : .R16G16B16A16_SFLOAT;
AMBIENT_FORMAT : VkFormat : .R16G16B16A16_SFLOAT;

depth_image         : VkImage;
depth_view          : VkImageView;
hdr_image           : VkImage;
hdr_view            : VkImageView;
hdr_texture         : Texture_Handle;
ambient_images      : [2] VkImage;
ambient_views       : [2] VkImageView;
ambient_storages    : [2] Storage_Image_Handle;
ambient_initialized : bool;

create_render_targets :: () {
    create :: (format: VkFormat, usage: VkImageUsageFlags, aspect: VkImageAspectFlags, name: string) -> VkImage, VkImageView, VkImageViewCreateInfo {
        image_create_info := VkImageCreateInfo.{
            imageType   = .e2D,
            format      = format,
            extent      = .{width = swapchain_extent.width, height = swapchain_extent.height, depth = 1},
            mipLevels   = 1,
            arrayLayers = 1,
            samples     = .e1,
            tiling      = .OPTIMAL,
            usage       = usage,
        };
        image : VkImage;
        result := vkCreateImage(device, *image_create_info, null, *image);
        assert(result == .SUCCESS);
        heap_bind_image(*render_target_heap, image);

        view_create_info := VkImageViewCreateInfo.{
            image            = image,
            viewType         = .e2D,
            format           = format,
            subresourceRange = .{aspectMask = aspect, levelCount = 1, layerCount = 1},
        };
        view : VkImageView;
        result = vkCreateImageView(device, *view_create_info, null, *view);
        assert(result == .SUCCESS);

        set_debug_name(.IMAGE,      image, name);
        set_debug_name(.IMAGE_VIEW, view,  name);
        return image, view, view_create_info;
    }

    depth_image, depth_view = create(DEPTH_FORMAT, .DEPTH_STENCIL_ATTACHMENT, .DEPTH, "depth");

    hdr_view_info : VkImageViewCreateInfo;
    hdr_image, hdr_view, hdr_view_info = create(HDR_FORMAT, .COLOR_ATTACHMENT | .SAMPLED, .COLOR, "hdr");
    write_image_descriptor(hdr_texture.id, .SAMPLED_IMAGE, hdr_view_info);

    for 0..1 {
        ambient_view_info : VkImageViewCreateInfo;
        ambient_images[it], ambient_views[it], ambient_view_info = create(AMBIENT_FORMAT, .STORAGE, .COLOR, tprint("ambient %", it));
        write_image_descriptor(ambient_storages[it].id, .STORAGE_IMAGE, ambient_view_info);
    }
    ambient_initialized = false;
}

destroy_render_targets :: () {
    for 0..1 {
        vkDestroyImageView(device, ambient_views[it], null);
        vkDestroyImage(device, ambient_images[it], null);
    }
    vkDestroyImageView(device, hdr_view, null);
    vkDestroyImage(device, hdr_image, null);
    vkDestroyImageView(device, depth_view, null);
    vkDestroyImage(device, depth_image, null);
    heap_reset(*render_target_heap);
}

recreate_swapchain :: () -> ready: bool {
    capabilities : VkSurfaceCapabilitiesKHR;
    vkGetPhysicalDeviceSurfaceCapabilitiesKHR(physical_device, surface, *capabilities);
    if capabilities.currentExtent.width == 0 || capabilities.currentExtent.height == 0  return false;

    vkDeviceWaitIdle(device);
    result := vkWaitForFences(device, MAX_SWAPCHAIN_IMAGES, present_fences.data, VK_TRUE, U64_MAX);
    assert(result == .SUCCESS);

    destroy_render_targets();
    deinit_swapchain();
    init_swapchain();
    create_render_targets();

    swapchain_needs_recreation = false;
    return true;
}

Frame_Constants :: struct @Gpu {
    view_projection          : Matrix4;
    previous_view_projection : Matrix4;
    tlas_address    : u64;
    light_direction : Vector3;
    sun_intensity   : float;
    time            : float;
    camera_position          : Vector3;
    previous_camera_position : Vector3;
    ambient               : Storage_Image_Handle;
    ambient_history       : Storage_Image_Handle;
    ambient_history_valid : u32;
    frame_number          : u32;
    debug_view            : u32;
}

Debug_View :: enum s32 {
    LIT;
    AMBIENT_OCCLUSION;
    BASE_COLOR;
    NORMALS;
    METALLIC_ROUGHNESS;
    SUN_ONLY;
    AMBIENT_ONLY;
}

DEBUG_VIEW_NAMES :: "Lit\0Ambient occlusion\0Base color\0Normals\0Metallic (R) / roughness (G)\0Sun only\0Ambient only\0\0";

Push_Data :: struct @Gpu {
    frame      : Gpu_Pointer(Frame_Constants);
    draws      : Gpu_Pointer(Draw_Data);
    materials  : Gpu_Pointer(Material);
    draw_index : u32;
}

Tonemap_Push_Data :: struct @Gpu {
    hdr      : Texture_Handle;
    exposure : float;
    raw      : u32;
}

FRAME_CONSTANTS_STRIDE : VkDeviceSize : 256;
#assert(size_of(Frame_Constants) <= FRAME_CONSTANTS_STRIDE);

init_render :: () {
    result : VkResult;

    frame_constants_offset = heap_allocate(*buffer_heap, FRAMES_IN_FLIGHT * FRAME_CONSTANTS_STRIDE, 256);

    command_pool_create_info := VkCommandPoolCreateInfo.{flags = .RESET_COMMAND_BUFFER, queueFamilyIndex = queue_family_index};
    result = vkCreateCommandPool(device, *command_pool_create_info, null, *command_pool);
    assert(result == .SUCCESS);

    command_buffer_allocate_info := VkCommandBufferAllocateInfo.{commandPool = command_pool, level = .PRIMARY, commandBufferCount = FRAMES_IN_FLIGHT};
    result = vkAllocateCommandBuffers(device, *command_buffer_allocate_info, command_buffers.data);
    assert(result == .SUCCESS);
    for command_buffers  set_debug_name(.COMMAND_BUFFER, it, tprint("frame command buffer %", it_index));

    command_buffer_allocate_info.commandBufferCount = 1;
    result = vkAllocateCommandBuffers(device, *command_buffer_allocate_info, *init_command_buffer);
    assert(result == .SUCCESS);
    set_debug_name(.COMMAND_BUFFER, init_command_buffer, "init command buffer");

    semaphore_create_info : VkSemaphoreCreateInfo;
    fence_create_info := VkFenceCreateInfo.{flags = .SIGNALED};
    for 0..MAX_SWAPCHAIN_IMAGES-1 {
        vkCreateSemaphore(device, *semaphore_create_info, null, *present_ready_semaphores[it]);
        set_debug_name(.SEMAPHORE, present_ready_semaphores[it], tprint("present ready semaphore %", it));
        vkCreateFence(device, *fence_create_info, null, *present_fences[it]);
        set_debug_name(.FENCE, present_fences[it], tprint("present fence %", it));
    }
    for 0..FRAMES_IN_FLIGHT-1 {
        vkCreateSemaphore(device, *semaphore_create_info, null, *image_available_semaphores[it]);
        set_debug_name(.SEMAPHORE, image_available_semaphores[it], tprint("image available semaphore %", it));
    }

    semaphore_type_create_info := VkSemaphoreTypeCreateInfo.{semaphoreType = .TIMELINE};
    timeline_semaphore_create_info := VkSemaphoreCreateInfo.{pNext = *semaphore_type_create_info};
    vkCreateSemaphore(device, *timeline_semaphore_create_info, null, *timeline_semaphore);
    set_debug_name(.SEMAPHORE, timeline_semaphore, "frame timeline semaphore");

    query_pool_create_info := VkQueryPoolCreateInfo.{queryType = .TIMESTAMP, queryCount = FRAMES_IN_FLIGHT * 2};
    result = vkCreateQueryPool(device, *query_pool_create_info, null, *timestamp_pool);
    assert(result == .SUCCESS);
    set_debug_name(.QUERY_POOL, timestamp_pool, "frame timestamp pool");

    material_shaders = create_graphics_shaders("material");
    tonemap_shaders  = create_graphics_shaders("tonemap");
    depth_shaders    = create_graphics_shaders("material", "depth_fragment_main");

    hdr_texture         = .{id = reserve_image_descriptor()};
    ambient_storages[0] = .{id = reserve_image_descriptor()};
    ambient_storages[1] = .{id = reserve_image_descriptor()};
    create_render_targets();
}

deinit_render :: () {
    destroy_render_targets();
    destroy_graphics_shaders(material_shaders);
    destroy_graphics_shaders(tonemap_shaders);
    destroy_graphics_shaders(depth_shaders);
    result := vkWaitForFences(device, MAX_SWAPCHAIN_IMAGES, present_fences.data, VK_TRUE, U64_MAX);
    assert(result == .SUCCESS);

    for image_index : 0..MAX_SWAPCHAIN_IMAGES-1 {
        vkDestroyFence(device, present_fences[image_index], null);
        vkDestroySemaphore(device, present_ready_semaphores[image_index], null);
    }
    for index : 0..FRAMES_IN_FLIGHT-1 {
        vkDestroySemaphore(device, image_available_semaphores[index], null);
    }
    vkDestroySemaphore(device, timeline_semaphore, null);
    vkDestroyQueryPool(device, timestamp_pool, null);
    vkDestroyCommandPool(device, command_pool, null);
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
    vkCmdSetCullMode(command_buffer,                .BACK);

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

    viewport := VkViewport.{width = xx swapchain_extent.width, height = xx swapchain_extent.height, maxDepth = 1};
    vkCmdSetViewportWithCount(command_buffer, 1, *viewport);

    scissor := VkRect2D.{extent = swapchain_extent};
    vkCmdSetScissorWithCount(command_buffer, 1, *scissor);

    vkCmdSetVertexInputEXT(command_buffer, 0, null, 0, null);
}

record_screenshot_copy :: (command_buffer: VkCommandBuffer, swapchain_image: VkImage) {
    screenshot_requested = false;
    screenshot_extent    = swapchain_extent;
    screenshot_format    = surface_format.format;

    size := cast(VkDeviceSize) (4 * screenshot_extent.width * screenshot_extent.height);
    if size > screenshot_allocated_size {
        screenshot_offset = heap_allocate(*readback_heap, size, 256);
        screenshot_allocated_size = size;
    }

    memory_barrier(command_buffer, .COLOR_ATTACHMENT_OUTPUT, .COLOR_ATTACHMENT_WRITE, .COPY, .TRANSFER_READ);

    region := VkDeviceMemoryImageCopyKHR.{
        addressRange     = .{address = heap_address(*readback_heap, screenshot_offset), size = size},
        addressFlags     = .STORAGE_BUFFER_USAGE,
        imageSubresource = .{aspectMask = .COLOR, layerCount = 1},
        imageLayout      = .GENERAL,
        imageExtent      = .{screenshot_extent.width, screenshot_extent.height, 1},
    };
    copy_info := VkCopyDeviceMemoryImageInfoKHR.{image = swapchain_image, regionCount = 1, pRegions = *region};
    vkCmdCopyImageToMemoryKHR(command_buffer, *copy_info);

    memory_barrier(command_buffer, .COPY, .TRANSFER_WRITE, .HOST, .HOST_READ);

    screenshot_captured = true;
}

save_screenshot :: () {
    pixels := read_screenshot_pixels();
    if !pixels return;
    defer free(pixels);

    path := timestamped_png_path("bin/screenshots");
    written := stbi_write_png(temp_c_string(path), xx screenshot_extent.width, xx screenshot_extent.height, 4, pixels, xx (4 * screenshot_extent.width));
    assert(written != 0, "Unable to write screenshot %", path);

    log("Saved screenshot to %.", path);
}

timestamped_png_path :: (directory: string) -> string {
    make_directory_if_it_does_not_exist(directory);

    time := to_calendar(current_time_consensus(), .LOCAL);
    return tprint("%/%-%-%_%-%-%.png", directory,
        time.year,
        formatInt(time.month_starting_at_0 + 1,       minimum_digits = 2),
        formatInt(time.day_of_month_starting_at_0 + 1, minimum_digits = 2),
        formatInt(time.hour,   minimum_digits = 2),
        formatInt(time.minute, minimum_digits = 2),
        formatInt(time.second, minimum_digits = 2));
}

read_screenshot_pixels :: () -> *u32 {
    Layout :: enum { RGBA8; BGRA8; A2B10G10R10; }
    layout : Layout;
    if screenshot_format == {
        case .R8G8B8A8_UNORM;           #through;
        case .R8G8B8A8_SRGB;            layout = .RGBA8;
        case .B8G8R8A8_UNORM;           #through;
        case .B8G8R8A8_SRGB;            layout = .BGRA8;
        case .A2B10G10R10_UNORM_PACK32; layout = .A2B10G10R10;
        case;
            log_error("Can't read a screenshot of swapchain format %.", screenshot_format);
            return null;
    }

    pixel_count := screenshot_extent.width * screenshot_extent.height;
    pixels := cast(*u32) alloc(4 * pixel_count);
    memcpy(pixels, heap_pointer(*readback_heap, screenshot_offset), 4 * pixel_count);

    for i : 0..pixel_count-1 {
        p := pixels[i];
        r, g, b : u32;
        if layout == {
            case .RGBA8;
                r = p & 0xFF;          g = (p >> 8) & 0xFF;            b = (p >> 16) & 0xFF;
            case .BGRA8;
                r = (p >> 16) & 0xFF;  g = (p >> 8) & 0xFF;            b = p & 0xFF;
            case .A2B10G10R10;
                r = (p & 0x3FF) >> 2;  g = ((p >> 10) & 0x3FF) >> 2;   b = ((p >> 20) & 0x3FF) >> 2;
        }
        pixels[i] = r | (g << 8) | (b << 16) | 0xFF00_0000;
    }

    return pixels;
}

draw_frame :: () {
    result : VkResult;

    frame_index += 1;
    index := frame_index % FRAMES_IN_FLIGHT;

    wait_value : u64 = ifx frame_index > FRAMES_IN_FLIGHT then frame_index - FRAMES_IN_FLIGHT else 0;
    semaphore_wait_info := VkSemaphoreWaitInfo.{semaphoreCount = 1, pSemaphores = *timeline_semaphore, pValues = *wait_value};
    result = vkWaitSemaphores(device, *semaphore_wait_info, U64_MAX);
    assert(result == .SUCCESS);

    if frame_index > FRAMES_IN_FLIGHT {
        timestamps : [2] u64;
        result = vkGetQueryPoolResults(device, timestamp_pool, xx (index * 2), 2, size_of(type_of(timestamps)), timestamps.data, size_of(u64), .e64);
        assert(result == .SUCCESS);

        period := device_limits.timestampPeriod;
        gpu_frame_ms = cast(float) (timestamps[1] - timestamps[0]) * period / 1_000_000.0;
    }

    image_index: u32;
    result = vkAcquireNextImageKHR(device, swapchain, U64_MAX, image_available_semaphores[index], VK_NULL_HANDLE, *image_index);
    if result == .ERROR_OUT_OF_DATE_KHR {
        frame_index -= 1;
        swapchain_needs_recreation = true;
        return;
    }
    if result == .SUBOPTIMAL_KHR {
        swapchain_needs_recreation = true;
    }
    else {
        assert(result == .SUCCESS, "vkAcquireNextImageKHR failed: %", result);
    }

    result = vkWaitForFences(device, 1, *present_fences[image_index], VK_TRUE, U64_MAX);
    assert(result == .SUCCESS);
    result = vkResetFences(device, 1, *present_fences[image_index]);
    assert(result == .SUCCESS);

    begin_info := VkCommandBufferBeginInfo.{flags = .ONE_TIME_SUBMIT};
    result = vkBeginCommandBuffer(command_buffers[index], *begin_info);
    assert(result == .SUCCESS);

    vkCmdResetQueryPool(command_buffers[index], timestamp_pool, xx (index * 2), 2);
    vkCmdWriteTimestamp2(command_buffers[index], .NONE, timestamp_pool, xx (index * 2));

    {
        ambient_history_valid := ambient_initialized;
        ambient_initialized = true;

        {
            image_barriers := VkImageMemoryBarrier2.[
                image_barrier(swapchain_images[image_index], .COLOR_ATTACHMENT_OUTPUT, .NONE, .COLOR_ATTACHMENT_OUTPUT, .COLOR_ATTACHMENT_WRITE),
                image_barrier(depth_image, .EARLY_FRAGMENT_TESTS | .LATE_FRAGMENT_TESTS, .NONE, .EARLY_FRAGMENT_TESTS | .LATE_FRAGMENT_TESTS, .DEPTH_STENCIL_ATTACHMENT_READ | .DEPTH_STENCIL_ATTACHMENT_WRITE, aspect = .DEPTH),
                image_barrier(hdr_image, .FRAGMENT_SHADER, .NONE, .COLOR_ATTACHMENT_OUTPUT, .COLOR_ATTACHMENT_WRITE),
                image_barrier(ambient_images[ambient_write_index], .FRAGMENT_SHADER, .NONE, .FRAGMENT_SHADER, .SHADER_STORAGE_WRITE),
                image_barrier(ambient_images[1 - ambient_write_index], .FRAGMENT_SHADER, .NONE, .FRAGMENT_SHADER, .SHADER_STORAGE_READ),
            ];
            barriers : [] VkImageMemoryBarrier2 = image_barriers;
            if ambient_history_valid  barriers.count -= 1;

            history_barrier := VkMemoryBarrier2.{
                srcStageMask  = .FRAGMENT_SHADER,
                srcAccessMask = .SHADER_STORAGE_WRITE,
                dstStageMask  = .FRAGMENT_SHADER,
                dstAccessMask = .SHADER_STORAGE_READ,
            };
            pipeline_barrier(command_buffers[index], barriers, .[history_barrier]);
        }

        color_attachment := VkRenderingAttachmentInfoKHR.{imageView = hdr_view, imageLayout = .GENERAL, loadOp = .CLEAR, storeOp = .STORE};
        color_attachment.clearValue.color.float32_ = xx srgb(0.1, 0.1, 0.12).component;

        depth_attachment := VkRenderingAttachmentInfoKHR.{imageView = depth_view, imageLayout = .GENERAL, loadOp = .CLEAR, storeOp = .DONT_CARE};
        depth_attachment.clearValue.depthStencil = .{depth = 1};

        rendering_info := VkRenderingInfo.{
            renderArea           = .{extent = swapchain_extent},
            layerCount           = 1,
            colorAttachmentCount = 1,
            pColorAttachments    = *color_attachment,
            pDepthAttachment     = *depth_attachment,
        };
        vkCmdBeginRendering(command_buffers[index], *rendering_info);

        bind_descriptor_heaps(command_buffers[index]);
        set_draw_state(command_buffers[index]);

        {
            frame_constants_slot := frame_constants_offset + index * FRAME_CONSTANTS_STRIDE;

            aspect := cast(float) swapchain_extent.width / cast(float) swapchain_extent.height;

            frame_constants := cast(*Frame_Constants) heap_pointer(*buffer_heap, frame_constants_slot);
            frame_constants.view_projection = camera_view_projection(aspect);
            frame_constants.tlas_address    = tlas_address;
            frame_constants.light_direction = light_direction;
            frame_constants.sun_intensity   = sun_intensity;
            frame_constants.time            = cast(float) seconds_since_init();
            frame_constants.camera_position = camera_position;

            frame_constants.previous_view_projection = previous_view_projection;
            frame_constants.previous_camera_position = previous_camera_position;
            previous_view_projection = frame_constants.view_projection;
            previous_camera_position = frame_constants.camera_position;

            frame_constants.ambient               = ambient_storages[ambient_write_index];
            frame_constants.ambient_history       = ambient_storages[1 - ambient_write_index];
            frame_constants.ambient_history_valid = xx ambient_history_valid;
            frame_constants.frame_number          = cast(u32) frame_index;
            frame_constants.debug_view            = cast(u32) debug_view;
            ambient_write_index = 1 - ambient_write_index;

            push_data := Push_Data.{
                frame      = heap_gpu_pointer(*buffer_heap, Frame_Constants, frame_constants_slot),
                draws      = heap_gpu_pointer(*buffer_heap, Draw_Data, draws_offset),
                materials  = heap_gpu_pointer(*buffer_heap, Material, materials_offset),
            };

            push_data_info := VkPushDataInfoEXT.{
                offset = 0,
                data   = .{address = *push_data, size = size_of(Push_Data)},
            };
            vkCmdPushDataEXT(command_buffers[index], *push_data_info);
        }

        no_components : VkColorComponentFlags;
        vkCmdSetColorWriteMaskEXT(command_buffers[index], 0, 1, *no_components);
        bind_graphics_shaders(command_buffers[index], depth_shaders);
        draw_scene(command_buffers[index]);

        all_components := VkColorComponentFlags.R | .G | .B | .A;
        vkCmdSetColorWriteMaskEXT(command_buffers[index], 0, 1, *all_components);
        vkCmdSetDepthWriteEnable(command_buffers[index], VK_FALSE);
        vkCmdSetDepthCompareOp(command_buffers[index], .EQUAL);
        bind_graphics_shaders(command_buffers[index], material_shaders);
        draw_scene(command_buffers[index]);

        vkCmdEndRendering(command_buffers[index]);

        memory_barrier(command_buffers[index], .COLOR_ATTACHMENT_OUTPUT, .COLOR_ATTACHMENT_WRITE, .FRAGMENT_SHADER, .SHADER_SAMPLED_READ);

        {
            swapchain_attachment := VkRenderingAttachmentInfoKHR.{
                imageView   = swapchain_views[image_index],
                imageLayout = .GENERAL,
                loadOp      = .DONT_CARE,
                storeOp     = .STORE,
            };
            rendering_info := VkRenderingInfo.{
                renderArea           = .{extent = swapchain_extent},
                layerCount           = 1,
                colorAttachmentCount = 1,
                pColorAttachments    = *swapchain_attachment,
            };
            vkCmdBeginRendering(command_buffers[index], *rendering_info);
        }

        {
            vkCmdSetDepthTestEnable(command_buffers[index],  VK_FALSE);
            vkCmdSetDepthWriteEnable(command_buffers[index], VK_FALSE);
            vkCmdSetCullMode(command_buffers[index], .NONE);
            bind_graphics_shaders(command_buffers[index], tonemap_shaders);

            push_data := Tonemap_Push_Data.{
                hdr      = hdr_texture,
                exposure = exposure,
                raw      = xx (debug_view != .LIT),
            };
            push_data_info := VkPushDataInfoEXT.{
                offset = 0,
                data   = .{address = *push_data, size = size_of(Tonemap_Push_Data)},
            };
            vkCmdPushDataEXT(command_buffers[index], *push_data_info);

            vkCmdDraw(command_buffers[index], vertexCount = 3, instanceCount = 1, firstVertex = 0, firstInstance = 0);
        }

        render_imgui(command_buffers[index], index);

        vkCmdEndRendering(command_buffers[index]);

        if screenshot_requested {
            record_screenshot_copy(command_buffers[index], swapchain_images[image_index]);
        }

        pipeline_barrier(command_buffers[index], .[image_barrier(swapchain_images[image_index], .COLOR_ATTACHMENT_OUTPUT | .COPY, .COLOR_ATTACHMENT_WRITE, .NONE, .NONE, old_layout = .GENERAL, new_layout = .PRESENT_SRC_KHR)]);
    }

    vkCmdWriteTimestamp2(command_buffers[index], .ALL_COMMANDS, timestamp_pool, xx (index * 2 + 1));

    result = vkEndCommandBuffer(command_buffers[index]);
    assert(result == .SUCCESS);

    wait_info := VkSemaphoreSubmitInfo.{semaphore = image_available_semaphores[index], stageMask = .COLOR_ATTACHMENT_OUTPUT};
    signal_infos := VkSemaphoreSubmitInfo.[
        .{semaphore = present_ready_semaphores[image_index], stageMask = .ALL_COMMANDS},
        .{semaphore = timeline_semaphore, value = frame_index, stageMask = .ALL_COMMANDS},
    ];
    command_buffer_info := VkCommandBufferSubmitInfo.{commandBuffer = command_buffers[index]};
    submit_info := VkSubmitInfo2.{
        waitSemaphoreInfoCount   = 1,
        pWaitSemaphoreInfos      = *wait_info,
        commandBufferInfoCount   = 1,
        pCommandBufferInfos      = *command_buffer_info,
        signalSemaphoreInfoCount = signal_infos.count,
        pSignalSemaphoreInfos    = signal_infos.data,
    };
    result = vkQueueSubmit2(queue, 1, *submit_info, VK_NULL_HANDLE);
    assert(result == .SUCCESS);

    present_fence_info := VkSwapchainPresentFenceInfoKHR.{swapchainCount = 1, pFences = *present_fences[image_index]};
    present_info := VkPresentInfoKHR.{
        pNext              = *present_fence_info,
        waitSemaphoreCount = 1,
        pWaitSemaphores    = *present_ready_semaphores[image_index],
        swapchainCount     = 1,
        pSwapchains        = *swapchain,
        pImageIndices      = *image_index,
    };
    result = vkQueuePresentKHR(queue, *present_info);
    if result == .ERROR_OUT_OF_DATE_KHR || result == .SUBOPTIMAL_KHR {
        swapchain_needs_recreation = true;
    } else {
        assert(result == .SUCCESS, "vkQueuePresentKHR failed: %", result);
    }
}

draw_scene :: (command_buffer: VkCommandBuffer) {
    culling_back_faces := true;
    for draws {
        double_sided := materials[it.material_index].double_sided != 0;
        if double_sided == culling_back_faces {
            culling_back_faces = !double_sided;
            vkCmdSetCullMode(command_buffer, ifx culling_back_faces then .BACK else .NONE);
        }

        draw_index := cast(u32) it_index;
        push_data_info := VkPushDataInfoEXT.{
            offset = offset_of(Push_Data, "draw_index"),
            data   = .{address = *draw_index, size = size_of(u32)},
        };
        vkCmdPushDataEXT(command_buffer, *push_data_info);

        index_buffer_info := VkBindIndexBuffer3InfoKHR.{
            addressRange = .{
                address = it.indices.address,
                size    = cast(VkDeviceSize) it.index_count * size_of(u32),
            },
            addressFlags = .STORAGE_BUFFER_USAGE,
            indexType    = .UINT32,
        };
        vkCmdBindIndexBuffer3KHR(command_buffer, *index_buffer_info);

        vkCmdDrawIndexed(command_buffer, indexCount = it.index_count, instanceCount = 1, firstIndex = 0, vertexOffset = 0, firstInstance = 0);
    }
    if !culling_back_faces  vkCmdSetCullMode(command_buffer, .BACK);
}
