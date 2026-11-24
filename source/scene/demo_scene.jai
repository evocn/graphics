init_demo_scene :: () {
    sampler := create_sampler(.{
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

    sponza_path := tprint("%/Sponza/Sponza.gltf", models_path);
    if file_exists(sponza_path) {
        if !load_gltf(sponza_path, placement(.{0.0, 1.0, 0.0}, PI / 2), sampler) {
            log_error("Could not load Sponza.");
        }
    } else {
        ground_material := add_material(.{base_color = srgb(0.5, 0.5, 0.5), sampler = sampler});
        add_draw(add_mesh(ground_positions, ground_attributes, ground_indices), ground_material, Matrix4_Identity);
    }

    if !load_gltf(tprint("%/BoxTextured/BoxTextured.gltf", models_path), placement(.{0.0, 0.5, 1.0}, 0.6), sampler) {
        log_error("Could not load BoxTextured.");
    }

    fox_first_skeleton := animation_context.skeletons.count;
    fox_root := multiply(placement(.{0.0, 1.0, 0.1}, PI / 2), make_scale_matrix4(.{0.008, 0.008, 0.008}));
    if !load_gltf(tprint("%/Fox/Fox.gltf", models_path), fox_root, sampler) {
        log_error("Could not load Fox.");
    }
    for fox_first_skeleton..animation_context.skeletons.count - 1 {
        skeleton := *animation_context.skeletons[it];
        for skeleton.clips  if it.name == "Walk"  skeleton.clip_index = xx it_index;
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

placement :: (translation: Vector3, yaw: float) -> Matrix4 {
    c := cos(yaw);
    s := sin(yaw);
    result := Matrix4_Identity;
    result.v[0] = .{ c, 0, s, translation.x};
    result.v[1] = .{ 0, 1, 0, translation.y};
    result.v[2] = .{-s, 0, c, translation.z};
    return result;
}
