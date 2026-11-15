descriptor_context : struct {
    image_stride   : VkDeviceSize;
    sampler_stride : VkDeviceSize;

    resource_heap_offset : VkDeviceSize;
    sampler_heap_offset  : VkDeviceSize;

    bind_resource_heap_info : VkBindHeapInfoEXT;
    bind_sampler_heap_info  : VkBindHeapInfoEXT;

    first_image_id   : u32;
    first_sampler_id : u32;

    image_id_capacity   : u32;
    sampler_id_capacity : u32;

    next_image_id   : u32;
    next_sampler_id : u32;
}

init_descriptor_heaps :: () {

    descriptor_context.image_stride   = device_context.descriptor_heap_properties.imageDescriptorSize;
    descriptor_context.sampler_stride = device_context.descriptor_heap_properties.samplerDescriptorSize;

    resource_heap_size := device_context.descriptor_heap_properties.maxResourceHeapSize;
    sampler_heap_size  := device_context.descriptor_heap_properties.maxSamplerHeapSize;
    assert(resource_heap_size % device_context.descriptor_heap_properties.resourceHeapAlignment == 0);
    assert(sampler_heap_size  % device_context.descriptor_heap_properties.samplerHeapAlignment  == 0);

    descriptor_context.sampler_heap_offset  = heap_allocate(*heap_context.buffer, sampler_heap_size,  device_context.descriptor_heap_properties.samplerHeapAlignment);
    descriptor_context.resource_heap_offset = heap_allocate(*heap_context.buffer, resource_heap_size, device_context.descriptor_heap_properties.resourceHeapAlignment);

    descriptor_context.bind_sampler_heap_info = .{
        heapRange         = .{address = heap_address(*heap_context.buffer, descriptor_context.sampler_heap_offset), size = sampler_heap_size},
        reservedRangeSize = device_context.descriptor_heap_properties.minSamplerHeapReservedRange,
    };
    descriptor_context.bind_resource_heap_info = .{
        heapRange         = .{address = heap_address(*heap_context.buffer, descriptor_context.resource_heap_offset), size = resource_heap_size},
        reservedRangeSize = device_context.descriptor_heap_properties.minResourceHeapReservedRange,
    };

    descriptor_context.first_image_id    = cast(u32, (device_context.descriptor_heap_properties.minResourceHeapReservedRange + descriptor_context.image_stride - 1) / descriptor_context.image_stride);
    descriptor_context.first_sampler_id  = cast(u32, (device_context.descriptor_heap_properties.minSamplerHeapReservedRange + descriptor_context.sampler_stride - 1) / descriptor_context.sampler_stride);

    descriptor_context.image_id_capacity   = cast(u32, resource_heap_size / descriptor_context.image_stride);
    descriptor_context.sampler_id_capacity = cast(u32, sampler_heap_size  / descriptor_context.sampler_stride);

    descriptor_context.next_image_id   = descriptor_context.first_image_id;
    descriptor_context.next_sampler_id = descriptor_context.first_sampler_id;

    log("Descriptor heaps: % image slots (% KiB), % sampler slots (% KiB).",
        descriptor_context.image_id_capacity   - descriptor_context.first_image_id,   resource_heap_size / 1024,
        descriptor_context.sampler_id_capacity - descriptor_context.first_sampler_id, sampler_heap_size  / 1024);
}

bind_descriptor_heaps :: (command_buffer: VkCommandBuffer) {
    vkCmdBindSamplerHeapEXT(command_buffer, *descriptor_context.bind_sampler_heap_info);
    vkCmdBindResourceHeapEXT(command_buffer, *descriptor_context.bind_resource_heap_info);
}

reserve_image_descriptor :: () -> u32 {
    id := descriptor_context.next_image_id;
    assert(id < descriptor_context.image_id_capacity, "Out of image descriptor slots.");
    descriptor_context.next_image_id += 1;
    return id;
}

write_image_descriptor :: (id: u32, type: VkDescriptorType, view_create_info: VkImageViewCreateInfo) {
    view_info := view_create_info;
    image_descriptor_info := VkImageDescriptorInfoEXT.{pView = *view_info, layout = .GENERAL};

    resource_descriptor_info := VkResourceDescriptorInfoEXT.{type = type};
    resource_descriptor_info.data.pImage = *image_descriptor_info;

    destination := VkHostAddressRangeEXT.{
        address = heap_pointer(*heap_context.buffer, descriptor_context.resource_heap_offset + id * descriptor_context.image_stride),
        size    = descriptor_context.image_stride,
    };
    result := vkWriteResourceDescriptorsEXT(device_context.device, 1, *resource_descriptor_info, *destination);
    assert(result == .SUCCESS);
}

create_sampler :: (sampler_create_info: VkSamplerCreateInfo) -> Sampler_Handle {
    id := descriptor_context.next_sampler_id;
    assert(id < descriptor_context.sampler_id_capacity, "Out of sampler descriptor slots.");
    descriptor_context.next_sampler_id += 1;

    info := sampler_create_info;
    destination := VkHostAddressRangeEXT.{
        address = heap_pointer(*heap_context.buffer, descriptor_context.sampler_heap_offset + id * descriptor_context.sampler_stride),
        size    = descriptor_context.sampler_stride,
    };
    result := vkWriteSamplerDescriptorsEXT(device_context.device, 1, *info, *destination);
    assert(result == .SUCCESS);

    return .{id = id};
}
