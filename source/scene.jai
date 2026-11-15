scene_context : struct {
    textures         : [..] Texture;
    materials        : [..] Material;
    materials_offset : VkDeviceSize;

    white_texture       : Texture_Handle;
    flat_normal_texture : Texture_Handle;

    draws                : [..] Draw_Data;
    draws_offset         : VkDeviceSize;
    draw_commands_offset : VkDeviceSize;

    blas         : VkAccelerationStructureKHR;
    blas_address : VkDeviceAddress;

    tlas         : VkAccelerationStructureKHR;
    tlas_address : VkDeviceAddress;
}

Vertex_Attributes :: struct @Gpu {
    normal  : Vector3;
    tangent : Vector4;
    uv      : Vector2;
}

ground_positions :: Vector3.[
    .{-15.0,  1.0,  15.0},
    .{ 15.0,  1.0, -15.0},
    .{-15.0,  1.0, -15.0},
    .{ 15.0,  1.0,  15.0},
];

ground_attributes :: Vertex_Attributes.[
    .{normal = .{0, -1, 0}, tangent = .{1, 0, 0, -1}, uv = .{0.0, 0.0}},
    .{normal = .{0, -1, 0}, tangent = .{1, 0, 0, -1}, uv = .{6.0, 6.0}},
    .{normal = .{0, -1, 0}, tangent = .{1, 0, 0, -1}, uv = .{0.0, 6.0}},
    .{normal = .{0, -1, 0}, tangent = .{1, 0, 0, -1}, uv = .{6.0, 0.0}},
];

ground_indices :: u32.[0, 1, 2, 0, 3, 1];

quad_positions :: Vector3.[
    .{-0.75,  1.0, 0.0},
    .{-0.75, -0.5, 0.0},
    .{ 0.75, -0.5, 0.0},
    .{ 0.75,  1.0, 0.0},
];

quad_attributes :: Vertex_Attributes.[
    .{normal = .{0, 0, -1}, tangent = .{1, 0, 0, -1}, uv = .{0.0, 1.0}},
    .{normal = .{0, 0, -1}, tangent = .{1, 0, 0, -1}, uv = .{0.0, 0.0}},
    .{normal = .{0, 0, -1}, tangent = .{1, 0, 0, -1}, uv = .{1.0, 0.0}},
    .{normal = .{0, 0, -1}, tangent = .{1, 0, 0, -1}, uv = .{1.0, 1.0}},
];

quad_indices :: u32.[0, 1, 2, 0, 2, 3];

Material :: struct @Gpu {
    base_color   : Vector4;
    texture      : Texture_Handle;
    sampler      : Sampler_Handle;
    alpha_cutoff : float;

    normal_texture             : Texture_Handle;
    metallic_roughness_texture : Texture_Handle;
    normal_scale               : float = 1;
    metallic                   : float = 0;
    roughness                  : float = 1;
}

Draw_Data :: struct @Gpu {
    transform      : Matrix4;
    positions      : Gpu_Pointer(Vector3);
    attributes     : Gpu_Pointer(Vertex_Attributes);
    indices        : Gpu_Pointer(u32);
    material_index : u32;
    vertex_count   : u32;
    index_count    : u32;
}

init_data :: () {
    white_pixel : u32 = 0xFFFFFFFF;
    scene_context.white_texture = add_texture(create_texture(*white_pixel, 1, 1, .R8G8B8A8_SRGB, "white texture"));

    flat_normal_pixel : u32 = 0xFFFF8080;
    scene_context.flat_normal_texture = add_texture(create_texture(*flat_normal_pixel, 1, 1, .R8G8B8A8_UNORM, "flat normal texture"));

    croc_width, croc_height, croc_channels : s32;
    croc_pixels := stbi_load(temp_c_string(tprint("%/croc.png", textures_path)), *croc_width, *croc_height, *croc_channels, 4);
    assert(croc_pixels != null, "Unable to load croc.png.");
    croc_texture := add_texture(create_texture(croc_pixels, xx croc_width, xx croc_height, .R8G8B8A8_SRGB, "croc"));
    stbi_image_free(croc_pixels);

    sampler := create_sampler(.{
        magFilter    = .NEAREST,
        minFilter    = .NEAREST,
        mipmapMode   = .NEAREST,
        addressModeU = .REPEAT,
        addressModeV = .REPEAT,
        addressModeW = .REPEAT,
        maxLod       = VK_LOD_CLAMP_NONE,
    });

    trilinear_sampler := create_sampler(.{
        magFilter        = .LINEAR,
        minFilter        = .LINEAR,
        mipmapMode       = .LINEAR,
        addressModeU     = .REPEAT,
        addressModeV     = .REPEAT,
        addressModeW     = .REPEAT,
        anisotropyEnable = VK_TRUE,
        maxAnisotropy    = min(16.0, device_context.limits.maxSamplerAnisotropy),
        maxLod           = VK_LOD_CLAMP_NONE,
    });

    ground_material      := add_material(.{base_color = srgb(0.5, 0.5, 0.5), texture = scene_context.white_texture, sampler = sampler});
    green_croc_material  := add_material(.{base_color = srgb(0.4, 0.9, 0.3), texture = croc_texture,  sampler = sampler, alpha_cutoff = 0.5});
    orange_croc_material := add_material(.{base_color = srgb(1.0, 0.6, 0.2), texture = croc_texture,  sampler = sampler, alpha_cutoff = 0.5});

    ground := add_mesh(ground_positions, ground_attributes, ground_indices);
    quad   := add_mesh(quad_positions,   quad_attributes,   quad_indices);

    sponza_path := tprint("%/Sponza/Sponza.gltf", models_path);
    if file_exists(sponza_path) {
        if !load_gltf(sponza_path, placement(.{0.0, 1.0, 0.0}, PI / 2), trilinear_sampler) {
            log_error("Could not load Sponza.");
        }
    } else {
        add_draw(ground, ground_material, Matrix4_Identity);
    }

    add_draw(quad, green_croc_material,  placement(.{-1.3, 0.0, 0.6},  0.4));
    add_draw(quad, orange_croc_material, placement(.{ 1.3, 0.0, 0.8}, -0.4));

    box_first_material := scene_context.materials.count;
    if !load_gltf(tprint("%/BoxTextured/BoxTextured.gltf", models_path), placement(.{0.0, 0.5, 1.0}, 0.6), trilinear_sampler) {
        log_error("Could not load BoxTextured.");
    }
    for box_first_material..scene_context.materials.count - 1 {
        scene_context.materials[it].texture = croc_texture;
        scene_context.materials[it].sampler = sampler;
    }

    scene_context.materials_offset = upload(scene_context.materials);
    scene_context.draws_offset     = upload(scene_context.draws);

    draw_commands := NewArray(scene_context.draws.count, VkDrawIndexedIndirectCommand,, temp);
    for scene_context.draws {
        draw_commands[it_index] = .{
            indexCount    = it.index_count,
            instanceCount = 1,
            firstIndex    = xx ((it.indices.address - heap_context.buffer.address) / size_of(u32)),
            firstInstance = xx it_index,
        };
    }
    scene_context.draw_commands_offset = upload(draw_commands);

    {
        transforms := NewArray(scene_context.draws.count, VkTransformMatrixKHR,, temp);
        for scene_context.draws  for row : 0..2  for column : 0..3  transforms[it_index].matrix[row][column] = it.transform.v[row].component[column];
        transforms_offset := upload(transforms);

        geometries       := NewArray(scene_context.draws.count, VkAccelerationStructureGeometryKHR,, temp);
        primitive_counts := NewArray(scene_context.draws.count, u32,, temp);
        for scene_context.draws {
            geometry := *geometries[it_index];
            geometry.geometryType = .TRIANGLES;
            if scene_context.materials[it.material_index].alpha_cutoff == 0  geometry.flags = .OPAQUE;
            geometry.geometry.triangles = .{
                vertexFormat                = .R32G32B32_SFLOAT,
                vertexData.deviceAddress    = it.positions.address,
                vertexStride                = size_of(Vector3),
                maxVertex                   = it.vertex_count - 1,
                indexType                   = .UINT32,
                indexData.deviceAddress     = it.indices.address,
                transformData.deviceAddress = heap_address(*heap_context.buffer, transforms_offset + xx (it_index * size_of(VkTransformMatrixKHR))),
            };
            primitive_counts[it_index] = it.index_count / 3;
        }

        scene_context.blas, scene_context.blas_address = build_acceleration_structure(.BOTTOM_LEVEL, geometries, primitive_counts);
    }
    acceleration_structure_build_barrier(.ACCELERATION_STRUCTURE_BUILD_KHR, .ACCELERATION_STRUCTURE_READ_KHR | .ACCELERATION_STRUCTURE_WRITE_KHR);

    tlas_instance : VkAccelerationStructureInstanceKHR;
    tlas_instance.transform.matrix[0][0] = 1;
    tlas_instance.transform.matrix[1][1] = 1;
    tlas_instance.transform.matrix[2][2] = 1;
    tlas_instance.__bitmask0 = 0xFF << 24;
    tlas_instance.__bitmask1 = cast(u32) VkGeometryInstanceFlagsKHR.TRIANGLE_FACING_CULL_DISABLE << 24;
    tlas_instance.accelerationStructureReference = scene_context.blas_address;

    scene_context.tlas, scene_context.tlas_address = build_tlas(.[tlas_instance]);
    acceleration_structure_build_barrier(.FRAGMENT_SHADER, .ACCELERATION_STRUCTURE_READ_KHR);
}

deinit_data :: () {
    vkDestroyAccelerationStructureKHR(device_context.device, scene_context.tlas, null);
    vkDestroyAccelerationStructureKHR(device_context.device, scene_context.blas, null);
    array_free(scene_context.draws);
    array_free(scene_context.materials);
    for scene_context.textures  destroy_texture(it);
    array_free(scene_context.textures);
}

add_texture :: (texture: Texture) -> Texture_Handle {
    array_add(*scene_context.textures, texture);
    return texture.handle;
}

add_material :: (material_in: Material) -> u32 {
    material := material_in;
    if material.texture.id == 0                     material.texture = scene_context.white_texture;
    if material.normal_texture.id == 0              material.normal_texture = scene_context.flat_normal_texture;
    if material.metallic_roughness_texture.id == 0  material.metallic_roughness_texture = scene_context.white_texture;
    array_add(*scene_context.materials, material);
    return xx (scene_context.materials.count - 1);
}

add_mesh :: (positions: [] Vector3, attributes: [] Vertex_Attributes, indices: [] u32) -> Draw_Data {
    assert(positions.count == attributes.count);
    assert(indices.count % 3 == 0);

    return .{
        transform    = Matrix4_Identity,
        positions    = heap_gpu_pointer(*heap_context.buffer, Vector3,           upload(positions)),
        attributes   = heap_gpu_pointer(*heap_context.buffer, Vertex_Attributes, upload(attributes)),
        indices      = heap_gpu_pointer(*heap_context.buffer, u32,               upload(indices)),
        vertex_count = xx positions.count,
        index_count  = xx indices.count,
    };
}

add_draw :: (mesh: Draw_Data, material_index: u32, transform: Matrix4) {
    draw := mesh;
    draw.material_index = material_index;
    draw.transform      = transform;
    array_add(*scene_context.draws, draw);
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
    offset := heap_allocate(*heap_context.buffer, xx size, 256);
    memcpy(heap_pointer(*heap_context.buffer, offset), array.data, size);
    return offset;
}
