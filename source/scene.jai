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

    blas_address : VkDeviceAddress;
    blas, blas_address = build_blas(command_buffers[0], arena_address(vertex_offset), xx vertices.count);
    acceleration_structure_build_barrier(command_buffers[0], .ACCELERATION_STRUCTURE_BUILD_KHR, .ACCELERATION_STRUCTURE_READ_KHR | .ACCELERATION_STRUCTURE_WRITE_KHR);

    instance : VkAccelerationStructureInstanceKHR;
    {
        using instance;
        transform.matrix = .[
             .[1, 0, 0, 0],
             .[0, 1, 0, 0],
             .[0, 0, 1, 0],
        ];
        __bitmask0 = 0xFF << 24;
        __bitmask1 = cast(u32, VkGeometryInstanceFlagsKHR.TRIANGLE_FACING_CULL_DISABLE) << 24;
        accelerationStructureReference = blas_address;
    }

    tlas, tlas_address = build_tlas(command_buffers[0], .[instance]);
    acceleration_structure_build_barrier(command_buffers[0], .FRAGMENT_SHADER, .ACCELERATION_STRUCTURE_READ_KHR);
}

deinit_data :: () {
    vkDestroyAccelerationStructureKHR(device, tlas, null);
    vkDestroyAccelerationStructureKHR(device, blas, null);
    destroy_texture(texture);
}
