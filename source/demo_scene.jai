init_demo_scene :: () {
    croc_texture := load_image_texture(tprint("%/croc.png", textures_path), .R8G8B8A8_SRGB);

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
}

#scope_file

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

placement :: (translation: Vector3, yaw: float) -> Matrix4 {
    c := cos(yaw);
    s := sin(yaw);
    result := Matrix4_Identity;
    result.v[0] = .{ c, 0, s, translation.x};
    result.v[1] = .{ 0, 1, 0, translation.y};
    result.v[2] = .{-s, 0, c, translation.z};
    return result;
}
