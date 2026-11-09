// Graphics
// Scene

Vertex :: struct @Gpu {
    position    : Vector3;
    color       : Vector3;
    uv          : Vector2;
}

ground_vertices := Vertex.[
    // Ground plane at y = +1 (+Y is down), facing up toward the camera.
    .{position = .{-15.0,  1.0,  15.0}, color = .{0.5, 0.5, 0.5}, uv = .{0.0, 0.0}},
    .{position = .{ 15.0,  1.0, -15.0}, color = .{0.5, 0.5, 0.5}, uv = .{6.0, 6.0}},
    .{position = .{-15.0,  1.0, -15.0}, color = .{0.5, 0.5, 0.5}, uv = .{0.0, 6.0}},

    .{position = .{-15.0,  1.0,  15.0}, color = .{0.5, 0.5, 0.5}, uv = .{0.0, 0.0}},
    .{position = .{ 15.0,  1.0,  15.0}, color = .{0.5, 0.5, 0.5}, uv = .{6.0, 0.0}},
    .{position = .{ 15.0,  1.0, -15.0}, color = .{0.5, 0.5, 0.5}, uv = .{6.0, 6.0}},
];

triangle_vertices := Vertex.[
    .{position = .{-2.0,  1.0, 0.0}, color = .{1.0, 0.0, 0.0}, uv = .{0.0, 1.0}},
    .{position = .{ 0.0, -2.0, 0.0}, color = .{1.0, 0.0, 0.0}, uv = .{0.5, 0.0}},
    .{position = .{ 2.0,  1.0, 0.0}, color = .{1.0, 0.0, 0.0}, uv = .{1.0, 1.0}},
];

Draw_Data :: struct @Gpu {
    vertices : Gpu_Pointer(Vertex);
    texture  : Texture_Handle;
    sampler  : Sampler_Handle;
}

Draw :: struct {
    vertex_offset : VkDeviceSize;
    vertex_count  : u32;
    blas          : VkAccelerationStructureKHR;
    blas_address  : VkDeviceAddress;
}

init_data :: () {
    white_pixel : u32 = 0xFFFFFFFF;
    texture = create_texture(command_buffers[0], *white_pixel, 1, 1, "white texture");

    sampler : Sampler_Handle;
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

        sampler = create_sampler(sampler_create_info);
    }

    add_draw(ground_vertices);
    add_draw(triangle_vertices);

    {
        draw_data_offset = heap_allocate(*heaps.buffer, xx (draws.count * size_of(Draw_Data)), 256);

        draw_datas := cast(*Draw_Data) heap_pointer(*heaps.buffer, draw_data_offset);
        for draws {
            draw_datas[it_index] = .{
                vertices = heap_gpu_pointer(*heaps.buffer, Vertex, it.vertex_offset),
                texture  = texture.handle,
                sampler  = sampler,
            };
        }
    }

    for * draws {
        it.blas, it.blas_address = build_blas(command_buffers[0], heap_address(*heaps.buffer, it.vertex_offset), size_of(Vertex), it.vertex_count);
    }
    acceleration_structure_build_barrier(command_buffers[0], .ACCELERATION_STRUCTURE_BUILD_KHR, .ACCELERATION_STRUCTURE_READ_KHR | .ACCELERATION_STRUCTURE_WRITE_KHR);

    instances : [..] VkAccelerationStructureInstanceKHR;
    defer array_free(instances);
    for draws {
        instance := array_add(*instances);
        instance.transform.matrix = .[
             .[1, 0, 0, 0],
             .[0, 1, 0, 0],
             .[0, 0, 1, 0],
        ];
        instance.__bitmask0 = 0xFF << 24;
        instance.__bitmask1 = cast(u32, VkGeometryInstanceFlagsKHR.TRIANGLE_FACING_CULL_DISABLE) << 24;
        instance.accelerationStructureReference = it.blas_address;
    }

    tlas, tlas_address = build_tlas(command_buffers[0], instances);
    acceleration_structure_build_barrier(command_buffers[0], .FRAGMENT_SHADER, .ACCELERATION_STRUCTURE_READ_KHR);
}

deinit_data :: () {
    vkDestroyAccelerationStructureKHR(device, tlas, null);
    for draws  vkDestroyAccelerationStructureKHR(device, it.blas, null);
    array_free(draws);
    destroy_texture(texture);
}

#scope_file

add_draw :: (vertices: [] Vertex) {
    draw := array_add(*draws);
    draw.vertex_count = xx vertices.count;

    size := vertices.count * size_of(Vertex);
    draw.vertex_offset = heap_allocate(*heaps.buffer, xx size, 256);
    memcpy(heap_pointer(*heaps.buffer, draw.vertex_offset), vertices.data, size);
}
