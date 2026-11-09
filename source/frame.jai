// Graphics
// Frame

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
}

Push_Data :: struct @Gpu {
    frame      : Gpu_Pointer(Frame_Constants);
    draws      : Gpu_Pointer(Draw_Data);
    materials  : Gpu_Pointer(Material);
    draw_index : u32;
}

Tonemap_Push_Data :: struct @Gpu {
    hdr      : Texture_Handle;
    exposure : float;
}

FRAME_CONSTANTS_STRIDE : VkDeviceSize : 256;
#assert(size_of(Frame_Constants) <= FRAME_CONSTANTS_STRIDE);

init_render :: () {
    result : VkResult;

    frame_constants_offset = heap_allocate(*heaps.buffer, FRAMES_IN_FLIGHT * FRAME_CONSTANTS_STRIDE, 256);

    // Command Buffers
    {
        // Pool
        {
            using command_pool_create_info: VkCommandPoolCreateInfo;
            flags = .RESET_COMMAND_BUFFER;
            queueFamilyIndex = xx physical_device_context.queue_family_indices.graphics;
            result = vkCreateCommandPool(device, *command_pool_create_info, null, *command_pool);
            assert(result == .SUCCESS);
        }

        {
            using command_buffer_allocate_info: VkCommandBufferAllocateInfo;
            commandPool        = command_pool;
            level              = .PRIMARY;
            commandBufferCount = FRAMES_IN_FLIGHT;
            result = vkAllocateCommandBuffers(device, *command_buffer_allocate_info, command_buffers.data);
            assert(result == .SUCCESS);

            for index : 0..FRAMES_IN_FLIGHT-1 {
                set_debug_name(.COMMAND_BUFFER, command_buffers[index], tprint("frame command buffer %", index));
            }
        }
    }

    // Semaphores
    {
        // Render / Present
        {
            using semaphore_create_info: VkSemaphoreCreateInfo;

            fence_create_info : VkFenceCreateInfo;
            fence_create_info.flags = .SIGNALED;

            for image_index : 0..swapchain_context.MAX_SWAPCHAIN_IMAGES-1 {
                vkCreateSemaphore(device, *semaphore_create_info, null, *present_ready_semaphores[image_index]);
                set_debug_name(.SEMAPHORE, present_ready_semaphores[image_index], tprint("present ready semaphore %", image_index));

                vkCreateFence(device, *fence_create_info, null, *present_fences[image_index]);
                set_debug_name(.FENCE, present_fences[image_index], tprint("present fence %", image_index));
            }
            for index : 0..FRAMES_IN_FLIGHT-1 {
                vkCreateSemaphore(device, *semaphore_create_info, null, *image_available_semaphores[index]);
                set_debug_name(.SEMAPHORE, image_available_semaphores[index], tprint("image available semaphore %", index));
            }
        }

        // Timeline
        {
            semaphore_type_create_info : VkSemaphoreTypeCreateInfo;
            {
                using semaphore_type_create_info;
                semaphoreType = .TIMELINE;
                initialValue = 0;
            }

            using timeline_semaphore_create_info: VkSemaphoreCreateInfo;
            pNext = *semaphore_type_create_info;

            vkCreateSemaphore(device, *timeline_semaphore_create_info, null, *timeline_semaphore);
            set_debug_name(.SEMAPHORE, timeline_semaphore, "frame timeline semaphore");
        }
    }

    {
        query_pool_create_info := VkQueryPoolCreateInfo.{
            queryType  = .TIMESTAMP,
            queryCount = FRAMES_IN_FLIGHT * 2,
        };
        result := vkCreateQueryPool(device, *query_pool_create_info, null, *timestamp_pool);
        assert(result == .SUCCESS);
        set_debug_name(.QUERY_POOL, timestamp_pool, "frame timestamp pool");
    }

    shaders         = create_graphics_shaders("material");
    tonemap_shaders = create_graphics_shaders("tonemap");
    depth_shaders   = create_graphics_shaders("material", "material-depth-fragment");
}

deinit_render :: () {
    destroy_graphics_shaders(shaders);
    destroy_graphics_shaders(tonemap_shaders);
    destroy_graphics_shaders(depth_shaders);
    result := vkWaitForFences(device, swapchain_context.MAX_SWAPCHAIN_IMAGES, present_fences.data, VK_TRUE, u64_max);
    assert(result == .SUCCESS);

    for image_index : 0..swapchain_context.MAX_SWAPCHAIN_IMAGES-1 {
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

    color_blend_enables : [1] VkBool32;
    {
        color_blend_enables[0] = VK_FALSE;
    }

    vkCmdSetColorBlendEnableEXT(command_buffer,
        firstAttachment = 0,
        attachmentCount = color_blend_enables.count,
        pColorBlendEnables = color_blend_enables.data,
    );

    color_write_masks : [1] VkColorComponentFlags;
    {
        color_write_masks[0] = .R | .G | .B | .A;
    }
    vkCmdSetColorWriteMaskEXT(command_buffer,
        firstAttachment = 0,
        attachmentCount = color_write_masks.count,
        pColorWriteMasks = color_write_masks.data
    );

    vkCmdSetRasterizationSamplesEXT(command_buffer, .e1);
    sample_mask : VkSampleMask = 1;
    vkCmdSetSampleMaskEXT(command_buffer, .e1, *sample_mask);


    {
        viewports : [1] VkViewport;
        {
            {
                using viewports[0];
                x = 0;                    
                y = 0;
                width       = xx swapchain_context.extent.width;
                height      = xx swapchain_context.extent.height;
                minDepth = 0;
                maxDepth = 1;
            }
        }
        vkCmdSetViewportWithCount(command_buffer, viewports.count, viewports.data);
    }

    {
        scissors : [1] VkRect2D;
        {
            {
                using scissors[0];
                offset = .{0, 0};
                extent = swapchain_context.extent;
            }
        }
        vkCmdSetScissorWithCount(command_buffer, scissors.count, scissors.data);
    }

    vkCmdSetVertexInputEXT(command_buffer, 0, null, 0, null);
}

record_screenshot_copy :: (command_buffer: VkCommandBuffer, swapchain_image: VkImage, subresource_range: VkImageSubresourceRange) {
    screenshot.requested = false;
    screenshot.extent    = swapchain_context.extent;
    screenshot.format    = swapchain_context.surface_format.format;

    size := cast(VkDeviceSize) (4 * screenshot.extent.width * screenshot.extent.height);
    screenshot.offset = heap_allocate(*heaps.scratch, size, 256);

    {
        image_memory_barrier : VkImageMemoryBarrier2;
        {
            using image_memory_barrier;
            srcStageMask        = .COLOR_ATTACHMENT_OUTPUT;
            srcAccessMask       = .COLOR_ATTACHMENT_WRITE;
            dstStageMask        = .COPY;
            dstAccessMask       = .TRANSFER_READ;
            oldLayout           = .GENERAL;
            newLayout           = .GENERAL;
            srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
            dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
            image               = swapchain_image;
            subresourceRange    = subresource_range;
        }

        dependency_info : VkDependencyInfo;
        {
            using dependency_info;
            imageMemoryBarrierCount = 1;
            pImageMemoryBarriers    = *image_memory_barrier;
        }

        vkCmdPipelineBarrier2(command_buffer, *dependency_info);
    }

    {
        region : VkDeviceMemoryImageCopyKHR;
        {
            using region;
            addressRange = .{
                address = heap_address(*heaps.scratch, screenshot.offset),
                size    = size,
            };
            addressFlags = .STORAGE_BUFFER_USAGE;
            imageSubresource = .{
                aspectMask = .COLOR,
                layerCount = 1,
            };
            imageLayout = .GENERAL;
            imageExtent = .{screenshot.extent.width, screenshot.extent.height, 1};
        }

        using copy_info : VkCopyDeviceMemoryImageInfoKHR;
        image = swapchain_image;
        regionCount = 1;
        pRegions = *region;

        vkCmdCopyImageToMemoryKHR(command_buffer, *copy_info);
    }

    {
        memory_barrier : VkMemoryBarrier2;
        {
            using memory_barrier;
            srcStageMask  = .COPY;
            srcAccessMask = .TRANSFER_WRITE;
            dstStageMask  = .HOST;
            dstAccessMask = .HOST_READ;
        }

        dependency_info : VkDependencyInfo;
        {
            using dependency_info;
            memoryBarrierCount = 1;
            pMemoryBarriers    = *memory_barrier;
        }

        vkCmdPipelineBarrier2(command_buffer, *dependency_info);
    }

    screenshot.captured = true;
}

save_screenshot :: () {
    using screenshot;

    Layout :: enum { RGBA8; BGRA8; A2B10G10R10; }
    layout : Layout;
    if format == {
        case .R8G8B8A8_UNORM;           #through;
        case .R8G8B8A8_SRGB;            layout = .RGBA8;
        case .B8G8R8A8_UNORM;           #through;
        case .B8G8R8A8_SRGB;            layout = .BGRA8;
        case .A2B10G10R10_UNORM_PACK32; layout = .A2B10G10R10;
        case;
            log_error("Can't save a screenshot of swapchain format %.", format);
            return;
    }

    pixel_count := extent.width * extent.height;
    pixels := cast(*u32) alloc(4 * pixel_count);
    defer free(pixels);
    memcpy(pixels, heap_pointer(*heaps.scratch, offset), 4 * pixel_count);

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

    directory :: "bin/screenshots";
    make_directory_if_it_does_not_exist(directory);

    time := to_calendar(current_time_consensus(), .LOCAL);
    path := tprint("%/%-%-%_%-%-%.png", directory,
        time.year,
        formatInt(time.month_starting_at_0 + 1,       minimum_digits = 2),
        formatInt(time.day_of_month_starting_at_0 + 1, minimum_digits = 2),
        formatInt(time.hour,   minimum_digits = 2),
        formatInt(time.minute, minimum_digits = 2),
        formatInt(time.second, minimum_digits = 2));

    written := stbi_write_png(temp_c_string(path), xx extent.width, xx extent.height, 4, pixels, xx (4 * extent.width));
    assert(written != 0, "Unable to write screenshot %", path);

    log("Saved screenshot to %.", path);
}

u64_min, u64_max :: #run get_integer_range(u64);

draw_frame :: () {
    result : VkResult;

    frame_index += 1;
    index := frame_index % FRAMES_IN_FLIGHT;

    wait_value : u64 = ifx frame_index > FRAMES_IN_FLIGHT then frame_index - FRAMES_IN_FLIGHT else 0;
    {
        using semaphore_wait_info : VkSemaphoreWaitInfo;

        semaphoreCount = 1;
        pSemaphores = *timeline_semaphore;
        pValues = *wait_value;

        result = vkWaitSemaphores(device, *semaphore_wait_info, u64_max);
        assert(result == .SUCCESS);
    }

    if frame_index > FRAMES_IN_FLIGHT {
        timestamps : [2] u64;
        result = vkGetQueryPoolResults(device, timestamp_pool, xx (index * 2), 2, size_of(type_of(timestamps)), timestamps.data, size_of(u64), .e64);
        assert(result == .SUCCESS);

        period := physical_device_context.properties2.properties.limits.timestampPeriod;
        gpu_frame_ms = cast(float) (timestamps[1] - timestamps[0]) * period / 1_000_000.0;
    }

    image_index: u32;
    result = vkAcquireNextImageKHR(device, swapchain_context.swapchain, u64_max, image_available_semaphores[index], VK_NULL_HANDLE, *image_index);
    if result == .ERROR_OUT_OF_DATE_KHR {
        frame_index -= 1;
        swapchain_context.needs_recreation = true;
        return;
    }
    if result == .SUBOPTIMAL_KHR {
        swapchain_context.needs_recreation = true;
    }
    else {
        assert(result == .SUCCESS, "vkAcquireNextImageKHR failed: %", result);
    }

    result = vkWaitForFences(device, 1, *present_fences[image_index], VK_TRUE, u64_max);
    assert(result == .SUCCESS);
    result = vkResetFences(device, 1, *present_fences[image_index]);
    assert(result == .SUCCESS);

    {
        using begin_info: VkCommandBufferBeginInfo;
        flags = .ONE_TIME_SUBMIT;
        result = vkBeginCommandBuffer(command_buffers[index], *begin_info);
        assert(result == .SUCCESS);
    }

    vkCmdResetQueryPool(command_buffers[index], timestamp_pool, xx (index * 2), 2);
    vkCmdWriteTimestamp2(command_buffers[index], .NONE, timestamp_pool, xx (index * 2));

    {
        swapchain_image_subresource_range : VkImageSubresourceRange;
        {
            using swapchain_image_subresource_range;
            aspectMask     = .COLOR;
            baseMipLevel   = 0;
            levelCount     = VK_REMAINING_MIP_LEVELS;
            baseArrayLayer = 0;
            layerCount     = VK_REMAINING_ARRAY_LAYERS;
        }

        ambient_history_valid := swapchain_context.ambient_initialized;
        swapchain_context.ambient_initialized = true;

        {
            image_memory_barriers : [5] VkImageMemoryBarrier2;
            image_memory_barriers[3] = .{
                srcStageMask        = .FRAGMENT_SHADER,
                srcAccessMask       = .SHADER_STORAGE_WRITE,
                dstStageMask        = .FRAGMENT_SHADER,
                dstAccessMask       = .SHADER_STORAGE_READ,
                oldLayout           = ifx ambient_history_valid then VkImageLayout.GENERAL else .UNDEFINED,
                newLayout           = .GENERAL,
                srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
                dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
                image               = swapchain_context.ambient_images[1 - ambient_write_index],
                subresourceRange    = swapchain_image_subresource_range,
            };
            image_memory_barriers[4] = .{
                srcStageMask        = .FRAGMENT_SHADER,
                srcAccessMask       = .NONE,
                dstStageMask        = .FRAGMENT_SHADER,
                dstAccessMask       = .SHADER_STORAGE_WRITE,
                oldLayout           = .UNDEFINED,
                newLayout           = .GENERAL,
                srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
                dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
                image               = swapchain_context.ambient_images[ambient_write_index],
                subresourceRange    = swapchain_image_subresource_range,
            };
            {
                using image_memory_barriers[0];
                srcStageMask        = .COLOR_ATTACHMENT_OUTPUT;
                srcAccessMask       = .NONE;
                dstStageMask        = .COLOR_ATTACHMENT_OUTPUT;
                dstAccessMask       = .COLOR_ATTACHMENT_WRITE;
                oldLayout           = .UNDEFINED;
                newLayout           = .GENERAL;
                srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
                dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
                image               = swapchain_context.images[image_index];
                subresourceRange    = swapchain_image_subresource_range;
            }

            {
                using image_memory_barriers[1];
                srcStageMask        = .EARLY_FRAGMENT_TESTS | .LATE_FRAGMENT_TESTS;
                srcAccessMask       = .NONE;
                dstStageMask        = .EARLY_FRAGMENT_TESTS | .LATE_FRAGMENT_TESTS;
                dstAccessMask       = .DEPTH_STENCIL_ATTACHMENT_READ | .DEPTH_STENCIL_ATTACHMENT_WRITE;
                oldLayout           = .UNDEFINED;
                newLayout           = .GENERAL;
                srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
                dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
                image               = swapchain_context.depth_image;
                subresourceRange    = swapchain_image_subresource_range;
                subresourceRange.aspectMask = .DEPTH;
            }

            image_memory_barriers[2] = .{
                srcStageMask        = .FRAGMENT_SHADER,
                srcAccessMask       = .NONE,
                dstStageMask        = .COLOR_ATTACHMENT_OUTPUT,
                dstAccessMask       = .COLOR_ATTACHMENT_WRITE,
                oldLayout           = .UNDEFINED,
                newLayout           = .GENERAL,
                srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
                dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
                image               = swapchain_context.hdr_image,
                subresourceRange    = swapchain_image_subresource_range,
            };

            dependency_info : VkDependencyInfo;
            {
                using dependency_info;
                imageMemoryBarrierCount = image_memory_barriers.count;
                pImageMemoryBarriers    = image_memory_barriers.data;
            }

            vkCmdPipelineBarrier2(command_buffers[index], *dependency_info);
        }

        color_attachment : VkRenderingAttachmentInfoKHR;
        {
            using color_attachment;
            imageView = swapchain_context.hdr_view;
            imageLayout = .GENERAL;
            loadOp = .CLEAR;
            storeOp = .STORE;
            clearValue.color.float32_ = xx srgb(0.1, 0.1, 0.12).component;
        }

        depth_attachment : VkRenderingAttachmentInfoKHR;
        {
            using depth_attachment;
            imageView = swapchain_context.depth_view;
            imageLayout = .GENERAL;
            loadOp = .CLEAR;
            storeOp = .DONT_CARE;
            clearValue.depthStencil = .{depth = 1, stencil = 0};
        }

        {
            using rendering_info : VkRenderingInfo;
            renderArea = VkRect2D.{
                offset = .{0, 0},
                extent = swapchain_context.extent,
            };
            layerCount = 1;
            viewMask = 0;
            colorAttachmentCount = 1;
            pColorAttachments = *color_attachment;
            pDepthAttachment = *depth_attachment;
            pStencilAttachment = null;

            vkCmdBeginRendering(command_buffers[index], *rendering_info);
        }

        // Set up my dynamic state
        bind_descriptor_heaps(command_buffers[index]);
        set_draw_state(command_buffers[index]);

        {
            frame_constants_slot := frame_constants_offset + index * FRAME_CONSTANTS_STRIDE;

            aspect := cast(float) swapchain_context.extent.width / cast(float) swapchain_context.extent.height;

            frame_constants := cast(*Frame_Constants) heap_pointer(*heaps.buffer, frame_constants_slot);
            frame_constants.view_projection = camera_view_projection(aspect);
            frame_constants.tlas_address    = tlas_address;
            frame_constants.light_direction = world_state.light_direction;
            frame_constants.sun_intensity   = world_state.sun_intensity;
            frame_constants.time            = cast(float) seconds_since_init();
            frame_constants.camera_position = camera.position;

            frame_constants.previous_view_projection = previous_view_projection;
            frame_constants.previous_camera_position = previous_camera_position;
            previous_view_projection = frame_constants.view_projection;
            previous_camera_position = frame_constants.camera_position;

            frame_constants.ambient               = swapchain_context.ambient_storages[ambient_write_index];
            frame_constants.ambient_history       = swapchain_context.ambient_storages[1 - ambient_write_index];
            frame_constants.ambient_history_valid = xx ambient_history_valid;
            frame_constants.frame_number          = cast(u32) frame_index;
            ambient_write_index = 1 - ambient_write_index;

            push_data := Push_Data.{
                frame      = heap_gpu_pointer(*heaps.buffer, Frame_Constants, frame_constants_slot),
                draws      = heap_gpu_pointer(*heaps.buffer, Draw_Data, draw_data_offset),
                materials  = heap_gpu_pointer(*heaps.buffer, Material, materials_offset),
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
        draw_instances(command_buffers[index]);

        all_components := VkColorComponentFlags.R | .G | .B | .A;
        vkCmdSetColorWriteMaskEXT(command_buffers[index], 0, 1, *all_components);
        vkCmdSetDepthWriteEnable(command_buffers[index], VK_FALSE);
        vkCmdSetDepthCompareOp(command_buffers[index], .EQUAL);
        bind_graphics_shaders(command_buffers[index], shaders);
        draw_instances(command_buffers[index]);

        vkCmdEndRendering(command_buffers[index]);

        {
            hdr_barrier := VkImageMemoryBarrier2.{
                srcStageMask        = .COLOR_ATTACHMENT_OUTPUT,
                srcAccessMask       = .COLOR_ATTACHMENT_WRITE,
                dstStageMask        = .FRAGMENT_SHADER,
                dstAccessMask       = .SHADER_SAMPLED_READ,
                oldLayout           = .GENERAL,
                newLayout           = .GENERAL,
                srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
                dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
                image               = swapchain_context.hdr_image,
                subresourceRange    = swapchain_image_subresource_range,
            };
            dependency_info := VkDependencyInfo.{imageMemoryBarrierCount = 1, pImageMemoryBarriers = *hdr_barrier};
            vkCmdPipelineBarrier2(command_buffers[index], *dependency_info);
        }

        {
            swapchain_attachment := VkRenderingAttachmentInfoKHR.{
                imageView   = swapchain_context.views[image_index],
                imageLayout = .GENERAL,
                loadOp      = .DONT_CARE,
                storeOp     = .STORE,
            };
            rendering_info := VkRenderingInfo.{
                renderArea           = .{extent = swapchain_context.extent},
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
                hdr      = swapchain_context.hdr_texture,
                exposure = world_state.exposure,
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

        if screenshot.requested {
            record_screenshot_copy(command_buffers[index], swapchain_context.images[image_index], swapchain_image_subresource_range);
        }

        {
            image_memory_barrier : VkImageMemoryBarrier2;
            {
                using image_memory_barrier;
                srcStageMask        = .COLOR_ATTACHMENT_OUTPUT | .COPY;
                srcAccessMask       = .COLOR_ATTACHMENT_WRITE;
                dstStageMask        = .NONE;
                dstAccessMask       = .NONE;
                oldLayout           = .GENERAL;
                newLayout           = .PRESENT_SRC_KHR;
                srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
                dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
                image               = swapchain_context.images[image_index];
                subresourceRange    = swapchain_image_subresource_range;
            }

            dependency_info : VkDependencyInfo;
            {
                using dependency_info;
                imageMemoryBarrierCount = 1;
                pImageMemoryBarriers    = *image_memory_barrier;
            }

            vkCmdPipelineBarrier2(command_buffers[index], *dependency_info);
        }
    }

    vkCmdWriteTimestamp2(command_buffers[index], .ALL_COMMANDS, timestamp_pool, xx (index * 2 + 1));

    result = vkEndCommandBuffer(command_buffers[index]);
    assert(result == .SUCCESS);

    {
        // Wait at the Color Attachment Output stage so the GPU can do vertex work before the image is fully acquired.
        wait_image_info : VkSemaphoreSubmitInfo;
        {
            using wait_image_info;
            semaphore = image_available_semaphores[index];
            value = 0; // binary.
            stageMask = .COLOR_ATTACHMENT_OUTPUT;
        }

        // Signal this when all commands, including the layout transition to PRESENT_SRC, finish.
        signal_present_info : VkSemaphoreSubmitInfo;
        {
            using signal_present_info;
            semaphore = present_ready_semaphores[image_index];
            value = 0; // binary.
            stageMask = .ALL_COMMANDS;
        }

        // Signal the timeline when all commands have finished.
        signal_timeline_info : VkSemaphoreSubmitInfo;
        {
            using signal_timeline_info;
            semaphore = timeline_semaphore;
            value = frame_index;
            stageMask = .ALL_COMMANDS;
        };

        signal_infos := VkSemaphoreSubmitInfo.[signal_present_info, signal_timeline_info];

        command_buffer_info : VkCommandBufferSubmitInfo;
        {
            using command_buffer_info;
            commandBuffer = command_buffers[index];
        }

        submit_info_2: VkSubmitInfo2;
        {
            using submit_info_2;
            waitSemaphoreInfoCount = 1;
            pWaitSemaphoreInfos = *wait_image_info;
            commandBufferInfoCount = 1;
            pCommandBufferInfos = *command_buffer_info;
            signalSemaphoreInfoCount = 2;
            pSignalSemaphoreInfos = signal_infos.data;
        }

        result = vkQueueSubmit2(queue, 1, *submit_info_2, VK_NULL_HANDLE);
        assert(result == .SUCCESS);
    }

    {
        using present_info: VkPresentInfoKHR;
        waitSemaphoreCount = 1;
        pWaitSemaphores    = *present_ready_semaphores[image_index];
        swapchainCount     = 1;
        pSwapchains        = *swapchain_context.swapchain;
        pImageIndices      = *image_index;

        present_fence_info : VkSwapchainPresentFenceInfoKHR;
        present_fence_info.swapchainCount = 1;
        present_fence_info.pFences        = *present_fences[image_index];
        pNext = *present_fence_info;

        result = vkQueuePresentKHR(queue, *present_info);
        if result == .ERROR_OUT_OF_DATE_KHR || result == .SUBOPTIMAL_KHR {
            swapchain_context.needs_recreation = true;
        }
        else {
            assert(result == .SUCCESS, "vkQueuePresentKHR failed: %", result);
        }
    }
}

draw_instances :: (command_buffer: VkCommandBuffer) {
    culling_back_faces := true;
    for instances {
        mesh := meshes[it.mesh_index];
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
                address = heap_address(*heaps.buffer, mesh.index_offset),
                size    = cast(VkDeviceSize) mesh.index_count * size_of(u32),
            },
            addressFlags = .STORAGE_BUFFER_USAGE,
            indexType    = .UINT32,
        };
        vkCmdBindIndexBuffer3KHR(command_buffer, *index_buffer_info);

        vkCmdDrawIndexed(command_buffer, indexCount = mesh.index_count, instanceCount = 1, firstIndex = 0, vertexOffset = 0, firstInstance = 0);
    }
    if !culling_back_faces  vkCmdSetCullMode(command_buffer, .BACK);
}
