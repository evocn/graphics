upload_context : struct {
    command_pool   : VkCommandPool;
    command_buffer : VkCommandBuffer;
}

init_upload :: () {
    command_pool_create_info := VkCommandPoolCreateInfo.{flags = .RESET_COMMAND_BUFFER, queueFamilyIndex = device_context.queue_family_index};
    result := vkCreateCommandPool(device_context.device, *command_pool_create_info, null, *upload_context.command_pool);
    assert(result == .SUCCESS);

    command_buffer_allocate_info := VkCommandBufferAllocateInfo.{commandPool = upload_context.command_pool, level = .PRIMARY, commandBufferCount = 1};
    result = vkAllocateCommandBuffers(device_context.device, *command_buffer_allocate_info, *upload_context.command_buffer);
    assert(result == .SUCCESS);
    set_debug_name(.COMMAND_BUFFER, upload_context.command_buffer, "upload command buffer");
}

deinit_upload :: () {
    vkDestroyCommandPool(device_context.device, upload_context.command_pool, null);
}

begin_upload :: () {
    begin_info := VkCommandBufferBeginInfo.{flags = .ONE_TIME_SUBMIT};
    result := vkBeginCommandBuffer(upload_context.command_buffer, *begin_info);
    assert(result == .SUCCESS);
}

end_upload :: () {
    result := vkEndCommandBuffer(upload_context.command_buffer);
    assert(result == .SUCCESS);

    submit_info := VkSubmitInfo.{commandBufferCount = 1, pCommandBuffers = *upload_context.command_buffer};
    result = vkQueueSubmit(device_context.queue, 1, *submit_info, VK_NULL_HANDLE);
    assert(result == .SUCCESS);
    vkDeviceWaitIdle(device_context.device);

    heap_reset(*heap_context.scratch);
}
