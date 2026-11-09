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
