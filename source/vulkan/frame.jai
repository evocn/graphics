FRAMES_IN_FLIGHT :: 2;

frame_context : struct {
    index                      : u64;
    timeline_semaphore         : VkSemaphore;
    command_pool               : VkCommandPool;
    command_buffers            : [FRAMES_IN_FLIGHT] VkCommandBuffer;
    image_available_semaphores : [FRAMES_IN_FLIGHT] VkSemaphore;
    present_ready_semaphores   : [MAX_SWAPCHAIN_IMAGES] VkSemaphore;
    present_fences             : [MAX_SWAPCHAIN_IMAGES] VkFence;

    timestamp_pool : VkQueryPool;
    gpu_ms         : float;
}

Frame :: struct {
    slot            : u64;
    command_buffer  : VkCommandBuffer;
    heap            : *Heap;
    image_index     : u32;
    swapchain_image : VkImage;
    swapchain_view  : VkImageView;
}

init_frames :: () {
    result : VkResult;

    command_pool_create_info := VkCommandPoolCreateInfo.{flags = .RESET_COMMAND_BUFFER, queueFamilyIndex = device_context.queue_family_index};
    result = vkCreateCommandPool(device_context.device, *command_pool_create_info, null, *frame_context.command_pool);
    assert(result == .SUCCESS);

    command_buffer_allocate_info := VkCommandBufferAllocateInfo.{commandPool = frame_context.command_pool, level = .PRIMARY, commandBufferCount = FRAMES_IN_FLIGHT};
    result = vkAllocateCommandBuffers(device_context.device, *command_buffer_allocate_info, frame_context.command_buffers.data);
    assert(result == .SUCCESS);
    for frame_context.command_buffers  set_debug_name(.COMMAND_BUFFER, it, tprint("frame command buffer %", it_index));

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
}

deinit_frames :: () {
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

recreate_swapchain :: () -> ready: bool {
    capabilities : VkSurfaceCapabilitiesKHR;
    vkGetPhysicalDeviceSurfaceCapabilitiesKHR(device_context.physical_device, device_context.surface, *capabilities);
    if capabilities.currentExtent.width == 0 || capabilities.currentExtent.height == 0  return false;

    vkDeviceWaitIdle(device_context.device);
    result := vkWaitForFences(device_context.device, MAX_SWAPCHAIN_IMAGES, frame_context.present_fences.data, VK_TRUE, U64_MAX);
    assert(result == .SUCCESS);

    deinit_swapchain();
    init_swapchain();

    swapchain_context.needs_recreation = false;
    return true;
}

begin_frame :: () -> Frame, acquired: bool {
    result : VkResult;
    frame : Frame;

    frame_context.index += 1;
    frame.slot = frame_context.index % FRAMES_IN_FLIGHT;
    frame.command_buffer = frame_context.command_buffers[frame.slot];

    wait_value : u64 = ifx frame_context.index > FRAMES_IN_FLIGHT then frame_context.index - FRAMES_IN_FLIGHT else 0;
    semaphore_wait_info := VkSemaphoreWaitInfo.{semaphoreCount = 1, pSemaphores = *frame_context.timeline_semaphore, pValues = *wait_value};
    result = vkWaitSemaphores(device_context.device, *semaphore_wait_info, U64_MAX);
    assert(result == .SUCCESS);

    frame.heap = *heap_context.frames[frame.slot];
    heap_reset(frame.heap);

    if frame_context.index > FRAMES_IN_FLIGHT {
        timestamps : [2] u64;
        result = vkGetQueryPoolResults(device_context.device, frame_context.timestamp_pool, xx (frame.slot * 2), 2, size_of(type_of(timestamps)), timestamps.data, size_of(u64), .e64);
        assert(result == .SUCCESS);

        period := device_context.limits.timestampPeriod;
        frame_context.gpu_ms = cast(float) (timestamps[1] - timestamps[0]) * period / 1_000_000.0;
    }

    result = vkAcquireNextImageKHR(device_context.device, swapchain_context.swapchain, U64_MAX, frame_context.image_available_semaphores[frame.slot], VK_NULL_HANDLE, *frame.image_index);
    if result == .ERROR_OUT_OF_DATE_KHR {
        frame_context.index -= 1;
        swapchain_context.needs_recreation = true;
        return frame, false;
    }
    if result == .SUBOPTIMAL_KHR {
        swapchain_context.needs_recreation = true;
    }
    else {
        assert(result == .SUCCESS, "vkAcquireNextImageKHR failed: %", result);
    }
    frame.swapchain_image = swapchain_context.images[frame.image_index];
    frame.swapchain_view  = swapchain_context.views[frame.image_index];

    result = vkWaitForFences(device_context.device, 1, *frame_context.present_fences[frame.image_index], VK_TRUE, U64_MAX);
    assert(result == .SUCCESS);
    result = vkResetFences(device_context.device, 1, *frame_context.present_fences[frame.image_index]);
    assert(result == .SUCCESS);

    begin_info := VkCommandBufferBeginInfo.{flags = .ONE_TIME_SUBMIT};
    result = vkBeginCommandBuffer(frame.command_buffer, *begin_info);
    assert(result == .SUCCESS);

    vkCmdResetQueryPool(frame.command_buffer, frame_context.timestamp_pool, xx (frame.slot * 2), 2);
    vkCmdWriteTimestamp2(frame.command_buffer, .NONE, frame_context.timestamp_pool, xx (frame.slot * 2));

    pipeline_barrier(frame.command_buffer, .[image_barrier(frame.swapchain_image, .COLOR_ATTACHMENT_OUTPUT, .NONE, .COLOR_ATTACHMENT_OUTPUT, .COLOR_ATTACHMENT_WRITE)]);

    return frame, true;
}

end_frame :: (frame: Frame) {
    result : VkResult;

    pipeline_barrier(frame.command_buffer, .[image_barrier(frame.swapchain_image, .COLOR_ATTACHMENT_OUTPUT | .COPY, .COLOR_ATTACHMENT_WRITE, .NONE, .NONE, old_layout = .GENERAL, new_layout = .PRESENT_SRC_KHR)]);

    vkCmdWriteTimestamp2(frame.command_buffer, .ALL_COMMANDS, frame_context.timestamp_pool, xx (frame.slot * 2 + 1));

    result = vkEndCommandBuffer(frame.command_buffer);
    assert(result == .SUCCESS);

    wait_info := VkSemaphoreSubmitInfo.{semaphore = frame_context.image_available_semaphores[frame.slot], stageMask = .COLOR_ATTACHMENT_OUTPUT};
    signal_infos := VkSemaphoreSubmitInfo.[
        .{semaphore = frame_context.present_ready_semaphores[frame.image_index], stageMask = .ALL_COMMANDS},
        .{semaphore = frame_context.timeline_semaphore, value = frame_context.index, stageMask = .ALL_COMMANDS},
    ];
    command_buffer_info := VkCommandBufferSubmitInfo.{commandBuffer = frame.command_buffer};
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

    image_index := frame.image_index;
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
