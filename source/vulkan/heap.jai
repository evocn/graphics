Heap :: struct {
    name              : string;
    memory            : VkDeviceMemory;
    memory_type_index : u32;
    size              : VkDeviceSize;
    used              : VkDeviceSize;

    buffer  : VkBuffer;
    address : VkDeviceAddress;
    cpu_map : *void;
}

heap_context : struct {
    buffer        : Heap;
    scratch       : Heap;
    readback      : Heap;
    image         : Heap;
    render_target : Heap;
    frames        : [FRAMES_IN_FLIGHT] Heap;
}

MiB :: 1024 * 1024;

init_heaps :: () {
    init_buffer_heap(*heap_context.buffer,  "buffer heap",  128 * MiB);
    init_buffer_heap(*heap_context.scratch, "scratch heap", 512 * MiB);
    init_buffer_heap(*heap_context.readback, "readback heap", 64 * MiB, .HOST_VISIBLE | .HOST_COHERENT | .HOST_CACHED);
    for * heap_context.frames  init_buffer_heap(it, sprint("frame heap %", it_index), 8 * MiB);

    init_image_heap(*heap_context.image,         "image heap",         512 * MiB, .R8G8B8A8_UNORM, .SAMPLED | .TRANSFER_DST);
    init_image_heap(*heap_context.render_target, "render target heap", 256 * MiB, DEPTH_FORMAT,    .DEPTH_STENCIL_ATTACHMENT);
}

deinit_heaps :: () {
    destroy :: (heap: Heap) {
        if heap.buffer  vkDestroyBuffer(device_context.device, heap.buffer, null);
        vkFreeMemory(device_context.device, heap.memory, null);
    }
    destroy(heap_context.buffer);
    destroy(heap_context.scratch);
    destroy(heap_context.readback);
    destroy(heap_context.image);
    destroy(heap_context.render_target);
    for heap_context.frames  destroy(it);
}

heap_allocate :: (heap: *Heap, size: VkDeviceSize, alignment: VkDeviceSize) -> offset: VkDeviceSize {
    offset := align_up(heap.used, alignment);
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
    vkGetImageMemoryRequirements(device_context.device, image, *memory_requirements);
    assert((memory_requirements.memoryTypeBits & (1 << heap.memory_type_index)) != 0, "This image can't live in the %.", heap.name);

    offset := heap_allocate(heap, memory_requirements.size, memory_requirements.alignment);
    result := vkBindImageMemory(device_context.device, image, heap.memory, offset);
    assert(result == .SUCCESS);
}

#scope_file

init_buffer_heap :: (heap: *Heap, name: string, size: VkDeviceSize, properties := VkMemoryPropertyFlagBits.DEVICE_LOCAL | .HOST_VISIBLE) {
    result : VkResult;

    heap.name = name;
    heap.size = size;

    buffer_create_info := VkBufferCreateInfo.{
        size  = heap.size,
        usage = .DESCRIPTOR_HEAP_EXT | .SHADER_DEVICE_ADDRESS | .INDEX_BUFFER | .INDIRECT_BUFFER | .TRANSFER_SRC | .TRANSFER_DST | .STORAGE_BUFFER | .ACCELERATION_STRUCTURE_BUILD_INPUT_READ_ONLY_KHR | .ACCELERATION_STRUCTURE_STORAGE_KHR,
    };
    result = vkCreateBuffer(device_context.device, *buffer_create_info, null, *heap.buffer);
    assert(result == .SUCCESS);

    memory_requirements : VkMemoryRequirements;
    vkGetBufferMemoryRequirements(device_context.device, heap.buffer, *memory_requirements);

    allocate_heap_memory(heap, memory_requirements.size, memory_requirements.memoryTypeBits, properties, device_address = true);

    result = vkBindBufferMemory(device_context.device, heap.buffer, heap.memory, 0);
    assert(result == .SUCCESS);

    device_address_info := VkBufferDeviceAddressInfo.{buffer = heap.buffer};
    heap.address = vkGetBufferDeviceAddress(device_context.device, *device_address_info);
    assert(heap.address != 0);

    result = vkMapMemory(device_context.device, heap.memory, 0, VK_WHOLE_SIZE, 0, *heap.cpu_map);
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
    vkGetDeviceImageMemoryRequirements(device_context.device, *requirements_info, *memory_requirements);

    allocate_heap_memory(heap, size, memory_requirements.memoryRequirements.memoryTypeBits, .DEVICE_LOCAL, device_address = false);
}

allocate_heap_memory :: (heap: *Heap, size: VkDeviceSize, memory_type_bits: u32, properties: VkMemoryPropertyFlagBits, device_address: bool) {
    success, memory_type_index := select_memory_type(device_context.memory_properties, memory_type_bits, properties);
    assert(success, "No memory type for the % has %.", heap.name, properties);
    heap.memory_type_index = memory_type_index;

    memory_allocate_flags_info := VkMemoryAllocateFlagsInfo.{flags = .DEVICE_ADDRESS};

    allocate_info := VkMemoryAllocateInfo.{allocationSize = size, memoryTypeIndex = memory_type_index};
    if device_address  allocate_info.pNext = *memory_allocate_flags_info;

    result := vkAllocateMemory(device_context.device, *allocate_info, null, *heap.memory);
    assert(result == .SUCCESS, "Unable to allocate % bytes for the %.", size, heap.name);

    set_debug_name(.DEVICE_MEMORY, heap.memory, tprint("% memory", heap.name));
}

select_memory_type :: (properties: VkPhysicalDeviceMemoryProperties, type_bits: u32, required: VkMemoryPropertyFlagBits) -> success: bool, memory_type_index: u32 {
    for i : 0..properties.memoryTypeCount-1 {
        if (type_bits & (1 << i)) == 0 continue;

        if (properties.memoryTypes[i].propertyFlags & required) == required {
            return true, i;
        }
    }
    return false, 0;
}

align_up :: (size : u64, power_of_two_alignment : u64) -> aligned: u64 {
    return (size + (power_of_two_alignment - 1)) & ~(power_of_two_alignment - 1);
}
