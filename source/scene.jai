// Graphics
// Scene

Vertex :: struct @Gpu {
    position    : Vector3;
    uv          : Vector2;
}

ground_vertices := Vertex.[
    // Ground plane at y = +1 (+Y is down), facing up toward the camera.
    .{position = .{-15.0,  1.0,  15.0}, uv = .{0.0, 0.0}},
    .{position = .{ 15.0,  1.0, -15.0}, uv = .{6.0, 6.0}},
    .{position = .{-15.0,  1.0, -15.0}, uv = .{0.0, 6.0}},

    .{position = .{-15.0,  1.0,  15.0}, uv = .{0.0, 0.0}},
    .{position = .{ 15.0,  1.0,  15.0}, uv = .{6.0, 0.0}},
    .{position = .{ 15.0,  1.0, -15.0}, uv = .{6.0, 6.0}},
];

triangle_vertices := Vertex.[
    .{position = .{-2.0,  1.0, 0.0}, uv = .{0.0, 1.0}},
    .{position = .{ 0.0, -2.0, 0.0}, uv = .{0.5, 0.0}},
    .{position = .{ 2.0,  1.0, 0.0}, uv = .{1.0, 1.0}},
];

Material :: struct @Gpu {
    base_color : Vector4;
    texture    : Texture_Handle;
    sampler      : Sampler_Handle;
    alpha_cutoff : float;
}

Draw_Data :: struct @Gpu {
    vertices       : Gpu_Pointer(Vertex); @ReadOnly
    material_index : u32;
}

Draw :: struct {
    vertex_offset  : VkDeviceSize;
    vertex_count   : u32;
    material_index : u32;
    blas           : VkAccelerationStructureKHR;
    blas_address   : VkDeviceAddress;
}

init_data :: () {
    white_pixel : u32 = 0xFFFFFFFF;
    white_texture := add_texture(create_texture(command_buffers[0], *white_pixel, 1, 1, .R8G8B8A8_SRGB, "white texture"));

    croc_data := program_state.texture_datas[0];
    croc_texture := add_texture(create_texture(command_buffers[0], croc_data.bytes, xx croc_data.width, xx croc_data.height, .R8G8B8A8_SRGB, "croc"));

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

    ground_material := add_material(.{base_color = srgb(0.5, 0.5, 0.5), texture = white_texture, sampler = sampler});
    croc_material   := add_material(.{base_color = srgb(1.0, 1.0, 1.0), texture = croc_texture,  sampler = sampler, alpha_cutoff = 0.5});

    add_draw(ground_vertices,   ground_material);
    add_draw(triangle_vertices, croc_material);

    materials_offset = upload(materials);

    {
        draw_datas : [..] Draw_Data;
        defer array_free(draw_datas);
        for draws {
            array_add(*draw_datas, .{
                vertices       = heap_gpu_pointer(*heaps.buffer, Vertex, it.vertex_offset),
                material_index = it.material_index,
            });
        }
        draw_data_offset = upload(draw_datas);
    }

    for * draws {
        it.blas, it.blas_address = build_blas(command_buffers[0], heap_address(*heaps.buffer, it.vertex_offset), size_of(Vertex), it.vertex_count, materials[it.material_index].alpha_cutoff == 0);
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
        instance.__bitmask0 = (0xFF << 24) | cast(u32) it_index;
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
    array_free(materials);
    for textures  destroy_texture(it);
    array_free(textures);
}

#scope_file

add_texture :: (texture: Texture) -> Texture_Handle {
    array_add(*textures, texture);
    return texture.handle;
}

add_material :: (material: Material) -> u32 {
    array_add(*materials, material);
    return xx (materials.count - 1);
}

add_draw :: (vertices: [] Vertex, material_index: u32) {
    draw := array_add(*draws);
    draw.vertex_count   = xx vertices.count;
    draw.material_index = material_index;
    draw.vertex_offset  = upload(vertices);
}

upload :: (array: [] $T) -> VkDeviceSize {
    size := array.count * size_of(T);
    offset := heap_allocate(*heaps.buffer, xx size, 256);
    memcpy(heap_pointer(*heaps.buffer, offset), array.data, size);
    return offset;
}
