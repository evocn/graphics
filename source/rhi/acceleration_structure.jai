Blas_Geometry :: struct {
    vertex_address   : VkDeviceAddress;
    vertex_stride    : VkDeviceSize;
    vertex_count     : u32;
    index_address    : VkDeviceAddress;
    index_count      : u32;
    transform_address: VkDeviceAddress;
    opaque           : bool;
}

build_blas ::(command_buffer: VkCommandBuffer, inputs: [] Blas_Geometry) -> VkAccelerationStructureKHR, VkDeviceAddress {
    geometries := NewArray(inputs.count, VkAccelerationStructureGeometryKHR,, temp);
    primitive_counts := NewArray(inputs.count, u32,, temp);
    for inputs {
        geometry := *geometries[it_index];
        geometry.geometryType = .TRIANGLES;
        if it.opaque  geometry.flags = .OPAQUE;
        geometry.geometry.triangles = .{
            vertexFormat = .R32G32B32_SFLOAT,
            vertexData.deviceAddress = it.vertex_address,
            vertexStride = it.vertex_stride,
            maxVertex = it.vertex_count - 1,
            indexType = .UINT32,
            indexData.deviceAddress = it.index_address,
            transformData.deviceAddress = it.transform_address,
        };
        primitive_counts[it_index] = it.index_count / 3;
    }

    blas, address := build_acceleration_structure(command_buffer, .BOTTOM_LEVEL, geometries, primitive_counts);
    return blas, address;
}

build_tlas :: (command_buffer: VkCommandBuffer, instances: [] VkAccelerationStructureInstanceKHR) -> VkAccelerationStructureKHR, VkDeviceAddress {
    instances_size := cast(VkDeviceSize) (instances.count * size_of(VkAccelerationStructureInstanceKHR));
    instances_offset := heap_allocate(*heaps.scratch, instances_size, 16);
    memcpy(heap_pointer(*heaps.scratch, instances_offset), instances.data, xx instances_size);

    instance_geometry : VkAccelerationStructureGeometryKHR;
    {
        using instance_geometry;
        geometryType = .INSTANCES;
        geometry.instances = .{
            arrayOfPointers = VK_FALSE,
            data.deviceAddress = heap_address(*heaps.scratch, instances_offset),
        };
    }

    tlas, address := build_acceleration_structure(command_buffer, .TOP_LEVEL, .[instance_geometry], .[cast(u32) instances.count]);
    return tlas, address;
}

acceleration_structure_build_barrier :: (command_buffer: VkCommandBuffer, dst_stage: VkPipelineStageFlags2, dst_access: VkAccessFlags2) {
    memory_barrier(command_buffer, .ACCELERATION_STRUCTURE_BUILD_KHR, .ACCELERATION_STRUCTURE_WRITE_KHR, dst_stage, dst_access);
}

build_acceleration_structure :: (command_buffer: VkCommandBuffer, type: VkAccelerationStructureTypeKHR, geometries: [] VkAccelerationStructureGeometryKHR, primitive_counts: [] u32) -> VkAccelerationStructureKHR, VkDeviceAddress {
    result : VkResult;
    assert(geometries.count == primitive_counts.count);

    build_geometry_info : VkAccelerationStructureBuildGeometryInfoKHR;
    {
        build_geometry_info.type = type;
        build_geometry_info.flags = .PREFER_FAST_TRACE;
        build_geometry_info.mode = .BUILD;
        build_geometry_info.geometryCount = xx geometries.count;
        build_geometry_info.pGeometries = geometries.data;
    }

    build_sizes : VkAccelerationStructureBuildSizesInfoKHR;
    vkGetAccelerationStructureBuildSizesKHR(device, .DEVICE, *build_geometry_info, primitive_counts.data, *build_sizes);

    storage_offset := heap_allocate(*heaps.buffer, build_sizes.accelerationStructureSize, 256);
    scratch_offset := heap_allocate(*heaps.scratch,
        build_sizes.buildScratchSize,
        physical_device_context.acceleration_structure_properties.minAccelerationStructureScratchOffsetAlignment
    );

    acceleration_structure : VkAccelerationStructureKHR;
    {
        create_info : VkAccelerationStructureCreateInfo2KHR;
        {
            create_info.createFlags = 0;
            create_info.addressRange = .{
                address = heap_address(*heaps.buffer, storage_offset),
                size = build_sizes.accelerationStructureSize,
            };
            create_info.addressFlags = .STORAGE_BUFFER_USAGE;
            create_info.type = type;
        }

        result = vkCreateAccelerationStructure2KHR(device, *create_info, null, *acceleration_structure);
        assert(result == .SUCCESS);
    }

    address : VkDeviceAddress;
    {
        using device_address_info : VkAccelerationStructureDeviceAddressInfoKHR;
        accelerationStructure = acceleration_structure;
        address = vkGetAccelerationStructureDeviceAddressKHR(device, *device_address_info);
    }
    assert(address != 0);

    build_geometry_info.dstAccelerationStructure  = acceleration_structure;
    build_geometry_info.scratchData.deviceAddress = heap_address(*heaps.scratch, scratch_offset);

    build_range_infos := NewArray(primitive_counts.count, VkAccelerationStructureBuildRangeInfoKHR,, temp);
    for primitive_counts  build_range_infos[it_index].primitiveCount = it;
    build_range_info_pointer := build_range_infos.data;
    vkCmdBuildAccelerationStructuresKHR(command_buffer, 1, *build_geometry_info, xx *build_range_info_pointer);

    return acceleration_structure, address;
}
