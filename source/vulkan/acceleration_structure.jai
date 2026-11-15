build_tlas :: (instances: [] VkAccelerationStructureInstanceKHR) -> VkAccelerationStructureKHR, VkDeviceAddress {
    instances_size := cast(VkDeviceSize) (instances.count * size_of(VkAccelerationStructureInstanceKHR));
    instances_offset := heap_allocate(*heap_context.scratch, instances_size, 16);
    memcpy(heap_pointer(*heap_context.scratch, instances_offset), instances.data, xx instances_size);

    instance_geometry := VkAccelerationStructureGeometryKHR.{geometryType = .INSTANCES};
    instance_geometry.geometry.instances = .{data.deviceAddress = heap_address(*heap_context.scratch, instances_offset)};

    structure, address := build_acceleration_structure(.TOP_LEVEL, .[instance_geometry], .[cast(u32) instances.count]);
    return structure, address;
}

acceleration_structure_build_barrier :: (dst_stage: VkPipelineStageFlags2, dst_access: VkAccessFlags2) {
    memory_barrier(frame_context.init_command_buffer, .ACCELERATION_STRUCTURE_BUILD_KHR, .ACCELERATION_STRUCTURE_WRITE_KHR, dst_stage, dst_access);
}

build_acceleration_structure :: (type: VkAccelerationStructureTypeKHR, geometries: [] VkAccelerationStructureGeometryKHR, primitive_counts: [] u32) -> VkAccelerationStructureKHR, VkDeviceAddress {
    assert(geometries.count == primitive_counts.count);

    build_geometry_info := VkAccelerationStructureBuildGeometryInfoKHR.{
        type          = type,
        flags         = .PREFER_FAST_TRACE,
        mode          = .BUILD,
        geometryCount = xx geometries.count,
        pGeometries   = geometries.data,
    };

    build_sizes : VkAccelerationStructureBuildSizesInfoKHR;
    vkGetAccelerationStructureBuildSizesKHR(device_context.device, .DEVICE, *build_geometry_info, primitive_counts.data, *build_sizes);

    storage_offset := heap_allocate(*heap_context.buffer, build_sizes.accelerationStructureSize, 256);
    scratch_offset := heap_allocate(*heap_context.scratch, build_sizes.buildScratchSize, device_context.acceleration_structure_properties.minAccelerationStructureScratchOffsetAlignment);

    create_info := VkAccelerationStructureCreateInfo2KHR.{
        addressRange = .{address = heap_address(*heap_context.buffer, storage_offset), size = build_sizes.accelerationStructureSize},
        addressFlags = .STORAGE_BUFFER_USAGE,
        type         = type,
    };
    acceleration_structure : VkAccelerationStructureKHR;
    result := vkCreateAccelerationStructure2KHR(device_context.device, *create_info, null, *acceleration_structure);
    assert(result == .SUCCESS);

    device_address_info := VkAccelerationStructureDeviceAddressInfoKHR.{accelerationStructure = acceleration_structure};
    address := vkGetAccelerationStructureDeviceAddressKHR(device_context.device, *device_address_info);
    assert(address != 0);

    build_geometry_info.dstAccelerationStructure  = acceleration_structure;
    build_geometry_info.scratchData.deviceAddress = heap_address(*heap_context.scratch, scratch_offset);

    build_range_infos := NewArray(primitive_counts.count, VkAccelerationStructureBuildRangeInfoKHR,, temp);
    for primitive_counts  build_range_infos[it_index].primitiveCount = it;
    build_range_info_pointer := build_range_infos.data;
    vkCmdBuildAccelerationStructuresKHR(frame_context.init_command_buffer, 1, *build_geometry_info, xx *build_range_info_pointer);

    return acceleration_structure, address;
}
