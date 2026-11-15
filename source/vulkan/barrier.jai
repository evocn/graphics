memory_barrier :: (command_buffer: VkCommandBuffer, src_stage: VkPipelineStageFlags2, src_access: VkAccessFlags2, dst_stage: VkPipelineStageFlags2, dst_access: VkAccessFlags2) {
    barrier := VkMemoryBarrier2.{
        srcStageMask  = src_stage,
        srcAccessMask = src_access,
        dstStageMask  = dst_stage,
        dstAccessMask = dst_access,
    };
    dependency_info := VkDependencyInfo.{memoryBarrierCount = 1, pMemoryBarriers = *barrier};
    vkCmdPipelineBarrier2(command_buffer, *dependency_info);
}

image_barrier :: (image: VkImage, src_stage: VkPipelineStageFlags2, src_access: VkAccessFlags2, dst_stage: VkPipelineStageFlags2, dst_access: VkAccessFlags2, aspect := VkImageAspectFlags.COLOR, old_layout := VkImageLayout.UNDEFINED, new_layout := VkImageLayout.GENERAL) -> VkImageMemoryBarrier2 {
    return .{
        srcStageMask        = src_stage,
        srcAccessMask       = src_access,
        dstStageMask        = dst_stage,
        dstAccessMask       = dst_access,
        oldLayout           = old_layout,
        newLayout           = new_layout,
        srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        image               = image,
        subresourceRange    = .{aspectMask = aspect, levelCount = VK_REMAINING_MIP_LEVELS, layerCount = VK_REMAINING_ARRAY_LAYERS},
    };
}

pipeline_barrier :: (command_buffer: VkCommandBuffer, image_barriers: [] VkImageMemoryBarrier2, memory_barriers: [] VkMemoryBarrier2 = .[]) {
    dependency_info := VkDependencyInfo.{
        memoryBarrierCount      = xx memory_barriers.count,
        pMemoryBarriers         = memory_barriers.data,
        imageMemoryBarrierCount = xx image_barriers.count,
        pImageMemoryBarriers    = image_barriers.data,
    };
    vkCmdPipelineBarrier2(command_buffer, *dependency_info);
}
