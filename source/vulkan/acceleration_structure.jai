Acceleration_Structure :: struct {
    handle              : VkAccelerationStructureKHR;
    address             : VkDeviceAddress;
    type                : VkAccelerationStructureTypeKHR;
    flags               : VkBuildAccelerationStructureFlagsKHR;
    build_scratch_size  : VkDeviceSize;
    update_scratch_size : VkDeviceSize;
}

create_acceleration_structure :: (type: VkAccelerationStructureTypeKHR, flags: VkBuildAccelerationStructureFlagsKHR, geometries: [] VkAccelerationStructureGeometryKHR, primitive_counts: [] u32) -> Acceleration_Structure {
    assert(geometries.count == primitive_counts.count);

    build_geometry_info := VkAccelerationStructureBuildGeometryInfoKHR.{
        type          = type,
        flags         = flags,
        mode          = .BUILD,
        geometryCount = xx geometries.count,
        pGeometries   = geometries.data,
    };

    build_sizes : VkAccelerationStructureBuildSizesInfoKHR;
    vkGetAccelerationStructureBuildSizesKHR(device_context.device, .DEVICE, *build_geometry_info, primitive_counts.data, *build_sizes);

    storage_offset := heap_allocate(*heap_context.buffer, build_sizes.accelerationStructureSize, 256);

    create_info := VkAccelerationStructureCreateInfo2KHR.{
        addressRange = .{address = heap_address(*heap_context.buffer, storage_offset), size = build_sizes.accelerationStructureSize},
        addressFlags = .STORAGE_BUFFER_USAGE,
        type         = type,
    };
    structure := Acceleration_Structure.{
        type                = type,
        flags               = flags,
        build_scratch_size  = build_sizes.buildScratchSize,
        update_scratch_size = build_sizes.updateScratchSize,
    };
    result := vkCreateAccelerationStructure2KHR(device_context.device, *create_info, null, *structure.handle);
    assert(result == .SUCCESS);

    device_address_info := VkAccelerationStructureDeviceAddressInfoKHR.{accelerationStructure = structure.handle};
    structure.address = vkGetAccelerationStructureDeviceAddressKHR(device_context.device, *device_address_info);
    assert(structure.address != 0);

    return structure;
}

destroy_acceleration_structure :: (structure: Acceleration_Structure) {
    vkDestroyAccelerationStructureKHR(device_context.device, structure.handle, null);
}

record_acceleration_structure_build :: (command_buffer: VkCommandBuffer, structure: Acceleration_Structure, mode: VkBuildAccelerationStructureModeKHR, geometries: [] VkAccelerationStructureGeometryKHR, primitive_counts: [] u32, scratch_heap: *Heap) {
    assert(geometries.count == primitive_counts.count);
    assert(mode == .BUILD || (structure.flags & .ALLOW_UPDATE));

    scratch_size := ifx mode == .UPDATE then structure.update_scratch_size else structure.build_scratch_size;
    scratch_offset := heap_allocate(scratch_heap, scratch_size, device_context.acceleration_structure_properties.minAccelerationStructureScratchOffsetAlignment);

    build_geometry_info := VkAccelerationStructureBuildGeometryInfoKHR.{
        type                     = structure.type,
        flags                    = structure.flags,
        mode                     = mode,
        dstAccelerationStructure = structure.handle,
        geometryCount            = xx geometries.count,
        pGeometries              = geometries.data,
        scratchData.deviceAddress = heap_address(scratch_heap, scratch_offset),
    };
    if mode == .UPDATE  build_geometry_info.srcAccelerationStructure = structure.handle;

    build_range_infos := NewArray(primitive_counts.count, VkAccelerationStructureBuildRangeInfoKHR,, temp);
    for primitive_counts  build_range_infos[it_index].primitiveCount = it;
    build_range_info_pointer := build_range_infos.data;
    vkCmdBuildAccelerationStructuresKHR(command_buffer, 1, *build_geometry_info, xx *build_range_info_pointer);
}

instance_geometry :: (instances_address: VkDeviceAddress) -> VkAccelerationStructureGeometryKHR {
    geometry := VkAccelerationStructureGeometryKHR.{geometryType = .INSTANCES};
    geometry.geometry.instances = .{data.deviceAddress = instances_address};
    return geometry;
}
