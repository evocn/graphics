build_blas :: (command_buffer: VkCommandBuffer, vertex_address: VkDeviceAddress, vertex_count: u32) -> VkAccelerationStructureKHR, VkDeviceAddress {
    triangle_geometry : VkAccelerationStructureGeometryKHR;
    {
        using triangle_geometry;
        geometryType = .TRIANGLES;
        geometry.triangles = .{
            vertexFormat = .R32G32B32_SFLOAT,
            vertexData.deviceAddress = vertex_address,
            vertexStride = size_of(Vertex),
            maxVertex = vertex_count - 1,
            indexType = .NONE_KHR,
        };
        flags = .OPAQUE;
    }

    blas, address := build_acceleration_structure(command_buffer, .BOTTOM_LEVEL, *triangle_geometry, vertex_count / 3);
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

    tlas, address := build_acceleration_structure(command_buffer, .TOP_LEVEL, *instance_geometry, xx instances.count);
    return tlas, address;
}

acceleration_structure_build_barrier :: (command_buffer: VkCommandBuffer, dst_stage: VkPipelineStageFlags2, dst_access: VkAccessFlags2) {
    memory_barrier : VkMemoryBarrier2;
    {
        using memory_barrier;
        srcStageMask  = .ACCELERATION_STRUCTURE_BUILD_KHR;
        srcAccessMask = .ACCELERATION_STRUCTURE_WRITE_KHR;
        dstStageMask  = dst_stage;
        dstAccessMask = dst_access;
    }
    dependency_info : VkDependencyInfo;
    {
        using dependency_info;
        memoryBarrierCount = 1;
        pMemoryBarriers    = *memory_barrier;
    }
    vkCmdPipelineBarrier2(command_buffer, *dependency_info);
}

build_acceleration_structure :: (command_buffer: VkCommandBuffer, type: VkAccelerationStructureTypeKHR, geometry: *VkAccelerationStructureGeometryKHR, primitive_count: u32) -> VkAccelerationStructureKHR, VkDeviceAddress {
    result : VkResult;

    build_geometry_info : VkAccelerationStructureBuildGeometryInfoKHR;
    {
        build_geometry_info.type = type;
        build_geometry_info.flags = .PREFER_FAST_TRACE;
        build_geometry_info.mode = .BUILD;
        build_geometry_info.geometryCount = 1;
        build_geometry_info.pGeometries = geometry;
    }

    build_sizes : VkAccelerationStructureBuildSizesInfoKHR;
    max_primitive_count := primitive_count;
    vkGetAccelerationStructureBuildSizesKHR(device, .DEVICE, *build_geometry_info, *max_primitive_count, *build_sizes);

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

    build_range_info := VkAccelerationStructureBuildRangeInfoKHR.{primitiveCount = primitive_count};
    build_range_info_pointer := *build_range_info;
    vkCmdBuildAccelerationStructuresKHR(command_buffer, 1, *build_geometry_info, xx *build_range_info_pointer);

    return acceleration_structure, address;
}
