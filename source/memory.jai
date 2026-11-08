// Graphics
// Memory

arena_suballocate :: (size: VkDeviceSize, alignment: VkDeviceSize) -> offset: VkDeviceSize {
    offset := align_up(arena.used, alignment);
    assert(offset + size <= arena.SIZE, "Arena is out of space.");
    arena.used = offset + size;
    return offset;
}

arena_address :: (offset: VkDeviceSize) -> VkDeviceAddress {
    return arena.address + offset;
}

arena_pointer :: (offset: VkDeviceSize) -> *void {
    return arena.cpu_map + offset;
}

init_arena :: () {
    result : VkResult;

    {
        using buffer_create_info : VkBufferCreateInfo;
        size  = arena.SIZE;
        usage = .DESCRIPTOR_HEAP_EXT
              | .SHADER_DEVICE_ADDRESS
              | .VERTEX_BUFFER
              | .INDEX_BUFFER
              | .TRANSFER_SRC
              | .TRANSFER_DST
              | .STORAGE_BUFFER
              | .ACCELERATION_STRUCTURE_BUILD_INPUT_READ_ONLY_KHR
              | .ACCELERATION_STRUCTURE_STORAGE_KHR
        ;

        result = vkCreateBuffer(device, *buffer_create_info, null, *arena.buffer);
        assert(result == .SUCCESS);
    }

    memory_requirements : VkMemoryRequirements;
    vkGetBufferMemoryRequirements(device, arena.buffer, *memory_requirements);

    {
        success, memory_type_index := select_memory_type(physical_device_context.memory_properties, memory_requirements.memoryTypeBits, .DEVICE_LOCAL | .HOST_VISIBLE);
        assert(success);
        assert(memory_type_index != -1);

        memory_allocate_flags_info : VkMemoryAllocateFlagsInfo;
        {
            using memory_allocate_flags_info;
            flags = .DEVICE_ADDRESS;
        }

        using memory_allocate_info : VkMemoryAllocateInfo;
        pNext = *memory_allocate_flags_info;
        allocationSize = memory_requirements.size;
        memoryTypeIndex = xx memory_type_index;

        result = vkAllocateMemory(device, *memory_allocate_info, null, *arena.memory);
        assert(result == .SUCCESS);
    }

    result = vkBindBufferMemory(device, arena.buffer, arena.memory, 0);
    assert(result == .SUCCESS);

    device_address_info := VkBufferDeviceAddressInfo.{buffer = arena.buffer};
    arena.address = vkGetBufferDeviceAddress(device, *device_address_info);
    assert(arena.address != 0);

    result = vkMapMemory(device, arena.memory, 0, VK_WHOLE_SIZE, 0, *arena.cpu_map);
    assert(result == .SUCCESS);
    assert(arena.cpu_map != null);

    set_debug_name(.BUFFER,        arena.buffer, "arena");
    set_debug_name(.DEVICE_MEMORY, arena.memory, "arena memory");
}

deinit_arena :: () {
    vkDestroyBuffer(device, arena.buffer, null);
    vkFreeMemory(device, arena.memory, null);
}

init_descriptor_heap :: () {
    using physical_device_context;

    image_descriptor_stride   = descriptor_heap_properties.imageDescriptorSize;
    sampler_descriptor_stride = descriptor_heap_properties.samplerDescriptorSize;

    resource_heap_size := descriptor_heap_properties.maxResourceHeapSize;
    sampler_heap_size  := descriptor_heap_properties.maxSamplerHeapSize;
    assert(resource_heap_size % descriptor_heap_properties.resourceHeapAlignment == 0);
    assert(sampler_heap_size  % descriptor_heap_properties.samplerHeapAlignment  == 0);

    sampler_heap_offset  = arena_suballocate(sampler_heap_size,  descriptor_heap_properties.samplerHeapAlignment);
    resource_heap_offset = arena_suballocate(resource_heap_size, descriptor_heap_properties.resourceHeapAlignment);

    {
        using bind_sampler_heap_info;
        heapRange = .{
            address = arena_address(sampler_heap_offset),
            size = sampler_heap_size,
        };
        reservedRangeOffset = 0;
        reservedRangeSize = descriptor_heap_properties.minSamplerHeapReservedRange;
    }

    {
        using bind_resource_heap_info;
        heapRange = .{
            address = arena_address(resource_heap_offset),
            size = resource_heap_size,
        };
        reservedRangeOffset = 0;
        reservedRangeSize = descriptor_heap_properties.minResourceHeapReservedRange;
    }

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

take_image_id :: () -> u32 {
    id := next_image_id;
    assert(id < image_id_capacity, "Out of image descriptor slots.");
    next_image_id += 1;
    return id;
}

take_sampler_id :: () -> u32 {
    id := next_sampler_id;
    assert(id < sampler_id_capacity, "Out of sampler descriptor slots.");
    next_sampler_id += 1;
    return id;
}
