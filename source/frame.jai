// Graphics
// Frame

Frame_Constants :: struct {
    view_projection : Matrix4;
    tlas_address    : u64;
    light_direction : Vector3;
    time            : float;
}

FRAME_CONSTANTS_STRIDE : VkDeviceSize : 256;
#assert(size_of(Frame_Constants) <= FRAME_CONSTANTS_STRIDE);

init_render :: () {
    result : VkResult;

    frame_constants_offset = arena_suballocate(FRAMES_IN_FLIGHT * FRAME_CONSTANTS_STRIDE, 256);

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

    // Shaders
    {
        // Read spirv from file
        spirv : [2] string;
        {
            read_shader_file :: (name: string) -> spirv: string
            {
                shader_file_path := tprint("%/%", compiled_shaders_directory, tprint("%.spv", name));

                spirv, success := read_entire_file(shader_file_path);
                assert(success, "Unable to read shader file %", shader_file_path);

                return spirv;
            }
            spirv[0] = read_shader_file("material-vertex");
            spirv[1] = read_shader_file("material-fragment");
        }

        // Shader Object Create Infos
        {
            shader_create_infos : [2] VkShaderCreateInfoEXT;

            {
                using shader_create_infos[0];
                flags = .LINK_STAGE | .DESCRIPTOR_HEAP;

                stage       = .VERTEX;
                nextStage   = .FRAGMENT;

                codeType    = .SPIRV;
                codeSize    = xx spirv[0].count;
                pCode       = spirv[0].data;

                pName       = "main";

                pushConstantRangeCount = 0;
                pPushConstantRanges = null;
                pSpecializationInfo = null;
            }

            {
                using shader_create_infos[1];
                flags = .LINK_STAGE | .DESCRIPTOR_HEAP;

                stage       = .FRAGMENT;
                nextStage   = 0;

                codeType    = .SPIRV;
                codeSize    = xx spirv[1].count;
                pCode       = spirv[1].data;

                pName       = "main";

                pushConstantRangeCount = 0;
                pPushConstantRanges = null;
                pSpecializationInfo = null;
            }

            result = vkCreateShadersEXT(device,
                shader_create_infos.count, shader_create_infos.data,
                null,
                shaders.data
            );
            assert(result == .SUCCESS);

            set_debug_name(.SHADER_EXT, shaders[0], "material vertex");
            set_debug_name(.SHADER_EXT, shaders[1], "material fragment");
        }
    }
}

deinit_render :: () {
    for shader : shaders {
        vkDestroyShaderEXT(device, shader, null);
    }
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
    vkDestroyCommandPool(device, command_pool, null);
}

bind_descriptor_heaps :: (command_buffer : VkCommandBuffer) {
    vkCmdBindSamplerHeapEXT(command_buffer, *bind_sampler_heap_info);
    vkCmdBindResourceHeapEXT(command_buffer, *bind_resource_heap_info);
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

        {
            image_memory_barriers : [2] VkImageMemoryBarrier2;
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

            // The depth image is shared by all frames in flight; this barrier also orders
            // this frame's depth work after the previous frame's. Contents are discarded.
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
            imageView = swapchain_context.views[image_index];
            imageLayout = .GENERAL;
            loadOp = .CLEAR;
            storeOp = .STORE;
            clearValue.color.float32_ = .[.1, .1, .12, 1];
        }

        depth_attachment : VkRenderingAttachmentInfoKHR;
        {
            using depth_attachment;
            imageView = swapchain_context.depth_view;
            imageLayout = .GENERAL;
            loadOp = .CLEAR;
            storeOp = .DONT_CARE; // Depth is never read after the rendering scope.
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

        // Bind Shaders
        {
            stages := VkShaderStageFlagBits.[
                .VERTEX,
                .FRAGMENT,
            ];

            vkCmdBindShadersEXT(
                command_buffers[index],
                stages.count, stages.data, shaders.data
            );
        }

        // Push Descriptor Data
        {
            frame_constants_slot := frame_constants_offset + index * FRAME_CONSTANTS_STRIDE;

            aspect := cast(float) swapchain_context.extent.width / cast(float) swapchain_context.extent.height;

            frame_constants := cast(*Frame_Constants) arena_pointer(frame_constants_slot);
            frame_constants.view_projection = camera_view_projection(aspect);
            frame_constants.tlas_address    = tlas_address;
            frame_constants.light_direction = unit_vector(Vector3.{0.3, 1.0, 0.2});
            frame_constants.time            = cast(float) seconds_since_init();

            Push_Data :: struct {
                frame      : VkDeviceAddress;
                draws      : VkDeviceAddress;
                draw_index : u32;
            }

            push_data := Push_Data.{
                frame      = arena_address(frame_constants_slot),
                draws      = arena_address(draw_data_offset),
                draw_index = 0,
            };

            push_data_info : VkPushDataInfoEXT;
            {
                using push_data_info;
                offset = 0;
                data = .{
                    address = *push_data,
                    size    = size_of(Push_Data),
                };
            }

            vkCmdPushDataEXT(command_buffers[index], *push_data_info);
        }


        vkCmdDraw(
            command_buffers[index],
            vertexCount = xx vertices.count,
            instanceCount = 1,
            firstVertex = 0,
            firstInstance = 0
        );

        render_imgui(command_buffers[index], index);

        vkCmdEndRendering(command_buffers[index]);

        {
            image_memory_barrier : VkImageMemoryBarrier2;
            {
                using image_memory_barrier;
                srcStageMask        = .COLOR_ATTACHMENT_OUTPUT;
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
