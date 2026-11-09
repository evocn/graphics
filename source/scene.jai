// Graphics
// Scene

Vertex_Attributes :: struct @Gpu {
    uv : Vector2;
}

ground_positions := Vector3.[
    // Ground plane at y = +1 (+Y is down), facing up toward the camera.
    .{-15.0,  1.0,  15.0},
    .{ 15.0,  1.0, -15.0},
    .{-15.0,  1.0, -15.0},
    .{ 15.0,  1.0,  15.0},
];

ground_attributes := Vertex_Attributes.[
    .{uv = .{0.0, 0.0}},
    .{uv = .{6.0, 6.0}},
    .{uv = .{0.0, 6.0}},
    .{uv = .{6.0, 0.0}},
];

ground_indices := u32.[0, 1, 2, 0, 3, 1];

quad_positions := Vector3.[
    .{-1.5,  1.0, 0.0},
    .{-1.5, -2.0, 0.0},
    .{ 1.5, -2.0, 0.0},
    .{ 1.5,  1.0, 0.0},
];

quad_attributes := Vertex_Attributes.[
    .{uv = .{0.0, 1.0}},
    .{uv = .{0.0, 0.0}},
    .{uv = .{1.0, 0.0}},
    .{uv = .{1.0, 1.0}},
];

quad_indices := u32.[0, 1, 2, 0, 2, 3];

Material :: struct @Gpu {
    base_color   : Vector4;
    texture      : Texture_Handle;
    sampler      : Sampler_Handle;
    alpha_cutoff : float;
}

Draw_Data :: struct @Gpu {
    transform      : Matrix4;
    positions      : Gpu_Pointer(Vector3);
    attributes     : Gpu_Pointer(Vertex_Attributes);
    indices        : Gpu_Pointer(u32);
    material_index : u32;
}

Mesh :: struct {
    position_offset  : VkDeviceSize;
    attribute_offset : VkDeviceSize;
    index_offset     : VkDeviceSize;
    vertex_count     : u32;
    index_count      : u32;
    blas             : VkAccelerationStructureKHR;
    blas_address     : VkDeviceAddress;
}

Instance :: struct {
    mesh_index     : u32;
    material_index : u32;
    transform      : Matrix4;
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

    ground_material      := add_material(.{base_color = srgb(0.5, 0.5, 0.5), texture = white_texture, sampler = sampler});
    green_croc_material  := add_material(.{base_color = srgb(0.4, 0.9, 0.3), texture = croc_texture,  sampler = sampler, alpha_cutoff = 0.5});
    orange_croc_material := add_material(.{base_color = srgb(1.0, 0.6, 0.2), texture = croc_texture,  sampler = sampler, alpha_cutoff = 0.5});

    ground_mesh := add_mesh(ground_positions, ground_attributes, ground_indices);
    quad_mesh   := add_mesh(quad_positions,   quad_attributes,   quad_indices);

    add_instance(ground_mesh, ground_material,      Matrix4_Identity);
    add_instance(quad_mesh,   green_croc_material,  placement(.{-2.5, 0.0, 2.5},  0.4));
    add_instance(quad_mesh,   orange_croc_material, placement(.{ 2.5, 0.0, 2.0}, -0.4));

    if !load_gltf(tprint("%/BoxTextured/BoxTextured.gltf", models_path), placement(.{0.0, 0.5, 1.0}, 0.6), sampler, white_texture) {
        log_error("Could not load BoxTextured.");
    }

    materials_offset = upload(materials);

    {
        draw_datas : [..] Draw_Data;
        defer array_free(draw_datas);
        for instances {
            mesh := meshes[it.mesh_index];
            array_add(*draw_datas, .{
                transform      = it.transform,
                positions      = heap_gpu_pointer(*heaps.buffer, Vector3, mesh.position_offset),
                attributes     = heap_gpu_pointer(*heaps.buffer, Vertex_Attributes, mesh.attribute_offset),
                indices        = heap_gpu_pointer(*heaps.buffer, u32, mesh.index_offset),
                material_index = it.material_index,
            });
        }
        draw_data_offset = upload(draw_datas);
    }

    for * meshes {
        it.blas, it.blas_address = build_blas(
            command_buffers[0],
            heap_address(*heaps.buffer, it.position_offset), size_of(Vector3), it.vertex_count,
            heap_address(*heaps.buffer, it.index_offset), it.index_count
        );
    }
    acceleration_structure_build_barrier(command_buffers[0], .ACCELERATION_STRUCTURE_BUILD_KHR, .ACCELERATION_STRUCTURE_READ_KHR | .ACCELERATION_STRUCTURE_WRITE_KHR);

    tlas_instances : [..] VkAccelerationStructureInstanceKHR;
    defer array_free(tlas_instances);
    for instances {
        flags := VkGeometryInstanceFlagsKHR.TRIANGLE_FACING_CULL_DISABLE;
        if materials[it.material_index].alpha_cutoff == 0  flags |= .FORCE_OPAQUE;

        tlas_instance := array_add(*tlas_instances);
        for row : 0..2  for column : 0..3  tlas_instance.transform.matrix[row][column] = it.transform.v[row].component[column];
        tlas_instance.__bitmask0 = (0xFF << 24) | cast(u32) it_index;
        tlas_instance.__bitmask1 = cast(u32) flags << 24;
        tlas_instance.accelerationStructureReference = meshes[it.mesh_index].blas_address;
    }

    tlas, tlas_address = build_tlas(command_buffers[0], tlas_instances);
    acceleration_structure_build_barrier(command_buffers[0], .FRAGMENT_SHADER, .ACCELERATION_STRUCTURE_READ_KHR);
}

deinit_data :: () {
    vkDestroyAccelerationStructureKHR(device, tlas, null);
    for meshes  vkDestroyAccelerationStructureKHR(device, it.blas, null);
    array_free(meshes);
    array_free(instances);
    array_free(materials);
    for textures  destroy_texture(it);
    array_free(textures);
}


add_texture :: (texture: Texture) -> Texture_Handle {
    array_add(*textures, texture);
    return texture.handle;
}

add_material :: (material: Material) -> u32 {
    array_add(*materials, material);
    return xx (materials.count - 1);
}

add_mesh :: (positions: [] Vector3, attributes: [] Vertex_Attributes, indices: [] u32) -> u32 {
    assert(positions.count == attributes.count);
    assert(indices.count % 3 == 0);

    mesh := array_add(*meshes);
    mesh.vertex_count     = xx positions.count;
    mesh.index_count      = xx indices.count;
    mesh.position_offset  = upload(positions);
    mesh.attribute_offset = upload(attributes);
    mesh.index_offset     = upload(indices);
    return xx (meshes.count - 1);
}

add_instance :: (mesh_index: u32, material_index: u32, transform: Matrix4) {
    array_add(*instances, .{mesh_index = mesh_index, material_index = material_index, transform = transform});
}

#scope_file

placement :: (translation: Vector3, yaw: float) -> Matrix4 {
    c := cos(yaw);
    s := sin(yaw);
    result := Matrix4_Identity;
    result.v[0] = .{ c, 0, s, translation.x};
    result.v[1] = .{ 0, 1, 0, translation.y};
    result.v[2] = .{-s, 0, c, translation.z};
    return result;
}

upload :: (array: [] $T) -> VkDeviceSize {
    size := array.count * size_of(T);
    offset := heap_allocate(*heaps.buffer, xx size, 256);
    memcpy(heap_pointer(*heaps.buffer, offset), array.data, size);
    return offset;
}
