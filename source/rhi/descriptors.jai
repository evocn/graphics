image_descriptor_stride   : VkDeviceSize;
sampler_descriptor_stride : VkDeviceSize;

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

init_descriptor_heaps :: () {

    image_descriptor_stride   = descriptor_heap_properties.imageDescriptorSize;
    sampler_descriptor_stride = descriptor_heap_properties.samplerDescriptorSize;

    resource_heap_size := descriptor_heap_properties.maxResourceHeapSize;
    sampler_heap_size  := descriptor_heap_properties.maxSamplerHeapSize;
    assert(resource_heap_size % descriptor_heap_properties.resourceHeapAlignment == 0);
    assert(sampler_heap_size  % descriptor_heap_properties.samplerHeapAlignment  == 0);

    sampler_heap_offset  = heap_allocate(*buffer_heap, sampler_heap_size,  descriptor_heap_properties.samplerHeapAlignment);
    resource_heap_offset = heap_allocate(*buffer_heap, resource_heap_size, descriptor_heap_properties.resourceHeapAlignment);

    bind_sampler_heap_info = .{
        heapRange         = .{address = heap_address(*buffer_heap, sampler_heap_offset), size = sampler_heap_size},
        reservedRangeSize = descriptor_heap_properties.minSamplerHeapReservedRange,
    };
    bind_resource_heap_info = .{
        heapRange         = .{address = heap_address(*buffer_heap, resource_heap_offset), size = resource_heap_size},
        reservedRangeSize = descriptor_heap_properties.minResourceHeapReservedRange,
    };

    first_image_id    = cast(u32, (descriptor_heap_properties.minResourceHeapReservedRange + image_descriptor_stride - 1) / image_descriptor_stride);
    first_sampler_id  = cast(u32, (descriptor_heap_properties.minSamplerHeapReservedRange + sampler_descriptor_stride - 1) / sampler_descriptor_stride);

    image_id_capacity   = cast(u32, resource_heap_size / image_descriptor_stride);
    sampler_id_capacity = cast(u32, sampler_heap_size  / sampler_descriptor_stride);

    next_image_id   = first_image_id;
    next_sampler_id = first_sampler_id;

    log("Descriptor heaps: % image slots (% KiB), % sampler slots (% KiB).",
        image_id_capacity   - first_image_id,   resource_heap_size / 1024,
        sampler_id_capacity - first_sampler_id, sampler_heap_size  / 1024);
}

bind_descriptor_heaps :: (command_buffer: VkCommandBuffer) {
    vkCmdBindSamplerHeapEXT(command_buffer, *bind_sampler_heap_info);
    vkCmdBindResourceHeapEXT(command_buffer, *bind_resource_heap_info);
}

reserve_image_descriptor :: () -> u32 {
    id := next_image_id;
    assert(id < image_id_capacity, "Out of image descriptor slots.");
    next_image_id += 1;
    return id;
}

write_image_descriptor :: (id: u32, type: VkDescriptorType, view_create_info: VkImageViewCreateInfo) {
    view_info := view_create_info;
    image_descriptor_info := VkImageDescriptorInfoEXT.{pView = *view_info, layout = .GENERAL};

    resource_descriptor_info := VkResourceDescriptorInfoEXT.{type = type};
    resource_descriptor_info.data.pImage = *image_descriptor_info;

    destination := VkHostAddressRangeEXT.{
        address = heap_pointer(*buffer_heap, resource_heap_offset + id * image_descriptor_stride),
        size    = image_descriptor_stride,
    };
    result := vkWriteResourceDescriptorsEXT(device, 1, *resource_descriptor_info, *destination);
    assert(result == .SUCCESS);
}

create_sampler :: (sampler_create_info: VkSamplerCreateInfo) -> Sampler_Handle {
    id := next_sampler_id;
    assert(id < sampler_id_capacity, "Out of sampler descriptor slots.");
    next_sampler_id += 1;

    info := sampler_create_info;
    destination := VkHostAddressRangeEXT.{
        address = heap_pointer(*buffer_heap, sampler_heap_offset + id * sampler_descriptor_stride),
        size    = sampler_descriptor_stride,
    };
    result := vkWriteSamplerDescriptorsEXT(device, 1, *info, *destination);
    assert(result == .SUCCESS);

    return .{id = id};
}
