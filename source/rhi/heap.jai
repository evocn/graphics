Heap :: struct {
    name              : string;
    memory            : VkDeviceMemory;
    memory_type_index : u32;
    size              : VkDeviceSize;
    used              : VkDeviceSize;

    buffer  : VkBuffer;
    address : VkDeviceAddress;
    cpu_map : *void;

    on_full : #type (heap: *Heap);
}

buffer_heap        : Heap;
scratch_heap       : Heap;
readback_heap      : Heap;
image_heap         : Heap;
render_target_heap : Heap;

MiB :: 1024 * 1024;

init_heaps :: () {
    init_buffer_heap(*buffer_heap,  "buffer heap",  128 * MiB);
    init_buffer_heap(*scratch_heap, "scratch heap", 64 * MiB);
    init_buffer_heap(*readback_heap, "readback heap", 64 * MiB, .HOST_VISIBLE | .HOST_COHERENT | .HOST_CACHED);

    init_image_heap(*image_heap,         "image heap",         512 * MiB, .R8G8B8A8_UNORM, .SAMPLED | .TRANSFER_DST);
    init_image_heap(*render_target_heap, "render target heap", 256 * MiB, DEPTH_FORMAT,    .DEPTH_STENCIL_ATTACHMENT);
}

deinit_heaps :: () {
    for heap : (*Heap).[*buffer_heap, *scratch_heap, *readback_heap, *image_heap, *render_target_heap] {
        if heap.buffer then vkDestroyBuffer(device, heap.buffer, null);
        vkFreeMemory(device, heap.memory, null);
    }
}

heap_allocate :: (heap: *Heap, size: VkDeviceSize, alignment: VkDeviceSize) -> offset: VkDeviceSize {
    offset := align_up(heap.used, alignment);
    if offset + size > heap.size && heap.on_full {
        heap.on_full(heap);
        offset = align_up(heap.used, alignment);
    }
    assert(offset + size <= heap.size, "The % is out of space: % MiB used of %, % MiB requested.", heap.name, heap.used / MiB, heap.size / MiB, size / MiB);
    heap.used = offset + size;
    return offset;
}

heap_reset :: (heap: *Heap) {
    heap.used = 0;
}

heap_address :: (heap: *Heap, offset: VkDeviceSize) -> VkDeviceAddress {
    assert(heap.address != 0, "The % has no device address.", heap.name);
    return heap.address + offset;
}

heap_pointer :: (heap: *Heap, offset: VkDeviceSize) -> *void {
    assert(heap.cpu_map != null, "The % isn't host-visible.", heap.name);
    return heap.cpu_map + offset;
}

heap_gpu_pointer :: (heap: *Heap, $T: Type, offset: VkDeviceSize) -> Gpu_Pointer(T) {
    return .{address = heap_address(heap, offset)};
}

heap_bind_image :: (heap: *Heap, image: VkImage) {
    memory_requirements : VkMemoryRequirements;
    vkGetImageMemoryRequirements(device, image, *memory_requirements);
    assert((memory_requirements.memoryTypeBits & (1 << heap.memory_type_index)) != 0, "This image can't live in the %.", heap.name);

    offset := heap_allocate(heap, memory_requirements.size, memory_requirements.alignment);
    result := vkBindImageMemory(device, image, heap.memory, offset);
    assert(result == .SUCCESS);
}

#scope_file

init_buffer_heap :: (heap: *Heap, name: string, size: VkDeviceSize, properties := VkMemoryPropertyFlagBits.DEVICE_LOCAL | .HOST_VISIBLE) {
    result : VkResult;

    heap.name = name;
    heap.size = size;

    buffer_create_info := VkBufferCreateInfo.{
        size  = heap.size,
        usage = .DESCRIPTOR_HEAP_EXT | .SHADER_DEVICE_ADDRESS | .INDEX_BUFFER | .TRANSFER_SRC | .TRANSFER_DST | .STORAGE_BUFFER | .ACCELERATION_STRUCTURE_BUILD_INPUT_READ_ONLY_KHR | .ACCELERATION_STRUCTURE_STORAGE_KHR,
    };
    result = vkCreateBuffer(device, *buffer_create_info, null, *heap.buffer);
    assert(result == .SUCCESS);

    memory_requirements : VkMemoryRequirements;
    vkGetBufferMemoryRequirements(device, heap.buffer, *memory_requirements);

    allocate_heap_memory(heap, memory_requirements.size, memory_requirements.memoryTypeBits, properties, device_address = true);

    result = vkBindBufferMemory(device, heap.buffer, heap.memory, 0);
    assert(result == .SUCCESS);

    device_address_info := VkBufferDeviceAddressInfo.{buffer = heap.buffer};
    heap.address = vkGetBufferDeviceAddress(device, *device_address_info);
    assert(heap.address != 0);

    result = vkMapMemory(device, heap.memory, 0, VK_WHOLE_SIZE, 0, *heap.cpu_map);
    assert(result == .SUCCESS);
    assert(heap.cpu_map != null);

    set_debug_name(.BUFFER, heap.buffer, name);
}

init_image_heap :: (heap: *Heap, name: string, size: VkDeviceSize, format: VkFormat, usage: VkImageUsageFlags) {
    heap.name = name;
    heap.size = size;

    image_info := VkImageCreateInfo.{
        imageType   = .e2D,
        format      = format,
        extent      = .{width = 1, height = 1, depth = 1},
        mipLevels   = 1,
        arrayLayers = 1,
        samples     = .e1,
        tiling      = .OPTIMAL,
        usage       = usage,
    };
    requirements_info := VkDeviceImageMemoryRequirements.{pCreateInfo = *image_info};
    memory_requirements : VkMemoryRequirements2;
    vkGetDeviceImageMemoryRequirements(device, *requirements_info, *memory_requirements);

    allocate_heap_memory(heap, size, memory_requirements.memoryRequirements.memoryTypeBits, .DEVICE_LOCAL, device_address = false);
}

allocate_heap_memory :: (heap: *Heap, size: VkDeviceSize, memory_type_bits: u32, properties: VkMemoryPropertyFlagBits, device_address: bool) {
    success, memory_type_index := select_memory_type(memory_properties, memory_type_bits, properties);
    assert(success, "No memory type for the % has %.", heap.name, properties);
    heap.memory_type_index = memory_type_index;

    memory_allocate_flags_info := VkMemoryAllocateFlagsInfo.{flags = .DEVICE_ADDRESS};

    allocate_info := VkMemoryAllocateInfo.{allocationSize = size, memoryTypeIndex = memory_type_index};
    if device_address  allocate_info.pNext = *memory_allocate_flags_info;

    result := vkAllocateMemory(device, *allocate_info, null, *heap.memory);
    assert(result == .SUCCESS, "Unable to allocate % bytes for the %.", size, heap.name);

    set_debug_name(.DEVICE_MEMORY, heap.memory, tprint("% memory", heap.name));
}

select_memory_type :: (memory_properties: VkPhysicalDeviceMemoryProperties, type_bits: u32, required: VkMemoryPropertyFlagBits) -> success: bool, memory_type_index: u32 {
    for i : 0..memory_properties.memoryTypeCount-1 {
        if (type_bits & (1 << i)) == 0 continue;

        if (memory_properties.memoryTypes[i].propertyFlags & required) == required {
            return true, i;
        }
    }
    return false, 0;
}

align_up :: (size : u64, power_of_two_alignment : u64) -> aligned: u64 {
    return (size + (power_of_two_alignment - 1)) & ~(power_of_two_alignment - 1);
}
