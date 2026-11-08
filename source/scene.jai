// Graphics
// Scene

Vertex :: struct {
    position    : Vector3;
    color       : Vector3;
    uv          : Vector2;
}

vertices := Vertex.[
    // Ground plane at y = +1 (+Y is down), facing up toward the camera.
    .{position = .{-15.0,  1.0,  15.0}, color = .{0.5, 0.5, 0.5}, uv = .{0.0, 0.0}},
    .{position = .{ 15.0,  1.0, -15.0}, color = .{0.5, 0.5, 0.5}, uv = .{6.0, 6.0}},
    .{position = .{-15.0,  1.0, -15.0}, color = .{0.5, 0.5, 0.5}, uv = .{0.0, 6.0}},

    .{position = .{-15.0,  1.0,  15.0}, color = .{0.5, 0.5, 0.5}, uv = .{0.0, 0.0}},
    .{position = .{ 15.0,  1.0,  15.0}, color = .{0.5, 0.5, 0.5}, uv = .{6.0, 0.0}},
    .{position = .{ 15.0,  1.0, -15.0}, color = .{0.5, 0.5, 0.5}, uv = .{6.0, 6.0}},
];

Draw_Data :: struct {
    vertices : VkDeviceAddress;
    texture  : [2] u32;
    sampler  : [2] u32;
}

init_data :: () {
    result : VkResult;

    white_pixel : u32 = 0xFFFFFFFF;
    texture = create_texture(command_buffers[0], *white_pixel, 1, 1, "white texture");

    sampler_id : u32;
    {
        sampler_create_info : VkSamplerCreateInfo;
        {
            using sampler_create_info;
            magFilter    = .NEAREST;
            minFilter    = .NEAREST;
            mipmapMode   = .NEAREST;
            addressModeU = .REPEAT;
            addressModeV = .REPEAT;
            addressModeW = .REPEAT;
            maxLod       = VK_LOD_CLAMP_NONE;
            borderColor  = .INT_OPAQUE_BLACK;
        }

        sampler_id = create_sampler(sampler_create_info);
    }

    // Vertex data lives in the arena and is bound by address.
    {
        vertex_size   = size_of(type_of(vertices));
        vertex_offset = arena_suballocate(vertex_size, 256);

        memcpy(arena_pointer(vertex_offset), *vertices, xx vertex_size);
    }

    {
        draw_data_offset = arena_suballocate(size_of(Draw_Data), 256);

        texture_id := texture.id;
        draw_data := cast(*Draw_Data) arena_pointer(draw_data_offset);
        {
            using draw_data;
            vertices = arena_address(vertex_offset);
            texture  = .[texture_id, 0];
            sampler  = .[sampler_id, 0];
        }
    }

    // Acceleration Structures
    {
        // BLAS
        blas_address : VkDeviceAddress;
        {
            acceleration_structure_geometry : VkAccelerationStructureGeometryKHR;
            {
                using acceleration_structure_geometry;
                geometryType = .TRIANGLES;
                geometry.triangles = .{
                    vertexFormat = .R32G32B32_SFLOAT,
                    vertexData.deviceAddress = arena_address(vertex_offset),
                    vertexStride = size_of(Vertex),
                    maxVertex = xx (vertices.count - 1),
                    indexType = .NONE_KHR,
                };
                flags = .OPAQUE;
            }

            acceleration_structure_build_geometry_info : VkAccelerationStructureBuildGeometryInfoKHR;
            {
                using acceleration_structure_build_geometry_info;
                type = .BOTTOM_LEVEL;
                flags = .PREFER_FAST_TRACE;
                mode = .BUILD;
                geometryCount = 1;
                pGeometries = *acceleration_structure_geometry;
            }

            max_primitive_counts := cast(u32, vertices.count / 3);
            acceleration_structure_build_sizes : VkAccelerationStructureBuildSizesInfoKHR;

            vkGetAccelerationStructureBuildSizesKHR(
                device,
                .DEVICE,
                *acceleration_structure_build_geometry_info,
                *max_primitive_counts,
                *acceleration_structure_build_sizes
            );

            acceleration_structure_offset := arena_suballocate(
                acceleration_structure_build_sizes.accelerationStructureSize,
                256
            );
            acceleration_structure_build_scratch_offset := arena_suballocate(
                acceleration_structure_build_sizes.buildScratchSize,
                physical_device_context.acceleration_structure_properties.minAccelerationStructureScratchOffsetAlignment
            );

            acceleration_structure_create_info : VkAccelerationStructureCreateInfo2KHR;
            {
                using acceleration_structure_create_info;
                createFlags = 0;
                addressRange = .{
                    address = arena_address(acceleration_structure_offset),
                    size = acceleration_structure_build_sizes.accelerationStructureSize,
                };
                addressFlags = .STORAGE_BUFFER_USAGE;
                type = .BOTTOM_LEVEL;
            }

            result = vkCreateAccelerationStructure2KHR(
                device,
                *acceleration_structure_create_info,
                null,
                *blas
            );
            assert(result == .SUCCESS);

            {
                using device_address_info : VkAccelerationStructureDeviceAddressInfoKHR;
                accelerationStructure = blas;
                blas_address = vkGetAccelerationStructureDeviceAddressKHR(device, *device_address_info);
            }
            assert(blas_address != 0);

            // Build
            acceleration_structure_build_geometry_info.dstAccelerationStructure  = blas;
            acceleration_structure_build_geometry_info.scratchData.deviceAddress = arena_address(acceleration_structure_build_scratch_offset);

            build_range_info := VkAccelerationStructureBuildRangeInfoKHR.{primitiveCount = max_primitive_counts};
            // The binding types ppBuildRangeInfos as *T, but the C API takes an array
            // of pointers (T* const*), one per build info. So pass the address of a pointer.
            build_range_info_pointer := *build_range_info;
            vkCmdBuildAccelerationStructuresKHR(command_buffers[0], 1, *acceleration_structure_build_geometry_info, xx *build_range_info_pointer);
        }

        // Barrier
        {
            memory_barrier : VkMemoryBarrier2;
            {
                using memory_barrier;
                srcStageMask  = .ACCELERATION_STRUCTURE_BUILD_KHR;
                srcAccessMask = .ACCELERATION_STRUCTURE_WRITE_KHR;
                dstStageMask  = .ACCELERATION_STRUCTURE_BUILD_KHR;
                dstAccessMask = .ACCELERATION_STRUCTURE_READ_KHR | .ACCELERATION_STRUCTURE_WRITE_KHR;
            }
            dependency_info : VkDependencyInfo;
            {
                using dependency_info;
                memoryBarrierCount = 1;
                pMemoryBarriers    = *memory_barrier;
            }
            vkCmdPipelineBarrier2(command_buffers[0], *dependency_info);
        }

        acceleration_structure_instance : VkAccelerationStructureInstanceKHR;
        {
            using acceleration_structure_instance;
            transform.matrix = .[
                 .[1, 0, 0, 0],
                 .[0, 1, 0, 0],
                 .[0, 0, 1, 0],
            ];
            __bitmask0 = 0xFF << 24;
            __bitmask1 = cast(u32, VkGeometryInstanceFlagsKHR.TRIANGLE_FACING_CULL_DISABLE) << 24;
            accelerationStructureReference = blas_address;
        }

        // The TLAS build reads instances from device memory; stage our one instance in the arena.
        instance_offset := arena_suballocate(size_of(VkAccelerationStructureInstanceKHR), 16);
        memcpy(arena_pointer(instance_offset), *acceleration_structure_instance, size_of(VkAccelerationStructureInstanceKHR));

        // TLAS
        {
            acceleration_structure_geometry : VkAccelerationStructureGeometryKHR;
            {
                using acceleration_structure_geometry;
                geometryType = .INSTANCES;
                geometry.instances = .{
                    arrayOfPointers = VK_FALSE,
                    data.deviceAddress = arena_address(instance_offset),
                };
            }

            acceleration_structure_build_geometry_info : VkAccelerationStructureBuildGeometryInfoKHR;
            {
                using acceleration_structure_build_geometry_info;
                type = .TOP_LEVEL;
                flags = .PREFER_FAST_TRACE;
                mode = .BUILD;
                geometryCount = 1;
                pGeometries = *acceleration_structure_geometry;
            }

            max_primitive_counts : u32 = 1;
            acceleration_structure_build_sizes : VkAccelerationStructureBuildSizesInfoKHR;

            vkGetAccelerationStructureBuildSizesKHR(
                device,
                .DEVICE,
                *acceleration_structure_build_geometry_info,
                *max_primitive_counts,
                *acceleration_structure_build_sizes
            );

            acceleration_structure_offset := arena_suballocate(
                acceleration_structure_build_sizes.accelerationStructureSize,
                256
            );
            acceleration_structure_build_scratch_offset := arena_suballocate(
                acceleration_structure_build_sizes.buildScratchSize,
                physical_device_context.acceleration_structure_properties.minAccelerationStructureScratchOffsetAlignment
            );

            acceleration_structure_create_info : VkAccelerationStructureCreateInfo2KHR;
            {
                using acceleration_structure_create_info;
                createFlags = 0;
                addressRange = .{
                    address = arena_address(acceleration_structure_offset),
                    size = acceleration_structure_build_sizes.accelerationStructureSize,
                };
                addressFlags = .STORAGE_BUFFER_USAGE;
                type = .TOP_LEVEL;
            }

            result = vkCreateAccelerationStructure2KHR(
                device,
                *acceleration_structure_create_info,
                null,
                *tlas
            );
            assert(result == .SUCCESS);

            {
                using device_address_info : VkAccelerationStructureDeviceAddressInfoKHR;
                accelerationStructure = tlas;
                tlas_address = vkGetAccelerationStructureDeviceAddressKHR(device, *device_address_info);
            }
            assert(tlas_address != 0);

            // Build
            acceleration_structure_build_geometry_info.dstAccelerationStructure  = tlas;
            acceleration_structure_build_geometry_info.scratchData.deviceAddress = arena_address(acceleration_structure_build_scratch_offset);

            build_range_info := VkAccelerationStructureBuildRangeInfoKHR.{primitiveCount = max_primitive_counts};
            build_range_info_pointer := *build_range_info;
            vkCmdBuildAccelerationStructuresKHR(command_buffers[0], 1, *acceleration_structure_build_geometry_info, xx *build_range_info_pointer);
        }

        // Barrier
        {
            memory_barrier : VkMemoryBarrier2;
            {
                using memory_barrier;
                srcStageMask  = .ACCELERATION_STRUCTURE_BUILD_KHR;
                srcAccessMask = .ACCELERATION_STRUCTURE_WRITE_KHR;
                dstStageMask  = .FRAGMENT_SHADER;
                dstAccessMask = .ACCELERATION_STRUCTURE_READ_KHR;
            }
            dependency_info : VkDependencyInfo;
            {
                using dependency_info;
                memoryBarrierCount = 1;
                pMemoryBarriers    = *memory_barrier;
            }
            vkCmdPipelineBarrier2(command_buffers[0], *dependency_info);
        }
    }
}

deinit_data :: () {
    vkDestroyAccelerationStructureKHR(device, tlas, null);
    vkDestroyAccelerationStructureKHR(device, blas, null);
    destroy_texture(texture);
}
