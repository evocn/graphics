// Graphics
// glTF

load_gltf :: (path: string, root: Matrix4, sampler: Sampler_Handle, white_texture: Texture_Handle) -> bool {
    options : cgltf_options;
    data : *cgltf_data;

    c_path := temp_c_string(path);
    result := cgltf_parse_file(*options, c_path, *data);
    if result != .success {
        log_error("Failed to parse %: %", path, result);
        return false;
    }
    defer cgltf_free(data);

    result = cgltf_load_buffers(*options, data, c_path);
    if result != .success {
        log_error("Failed to load buffers for %: %", path, result);
        return false;
    }

    directory := path_strip_filename(path);

    image_textures := NewArray(xx data.images_count, Texture_Handle);
    defer array_free(image_textures);
    for image_index : 0..cast(s64) data.images_count - 1 {
        image_textures[image_index] = load_gltf_image(*data.images[image_index], directory);
    }

    samplers := NewArray(xx data.samplers_count, Sampler_Handle);
    defer array_free(samplers);
    for sampler_index : 0..cast(s64) data.samplers_count - 1 {
        samplers[sampler_index] = create_sampler(gltf_sampler_info(*data.samplers[sampler_index]));
    }

    material_indices := NewArray(xx data.materials_count, u32);
    defer array_free(material_indices);
    for material_index : 0..cast(s64) data.materials_count - 1 {
        material_indices[material_index] = add_gltf_material(data, *data.materials[material_index], image_textures, samplers, sampler, white_texture);
    }
    default_material := add_material(.{base_color = .{1, 1, 1, 1}, texture = white_texture, sampler = sampler});

    Primitive_Mesh :: struct {
        mesh_index     : u32;
        material_index : u32;
    }
    mesh_primitives := NewArray(xx data.meshes_count, [..] Primitive_Mesh);
    defer {
        for mesh_primitives  array_free(it);
        array_free(mesh_primitives);
    }
    for mesh_index : 0..cast(s64) data.meshes_count - 1 {
        mesh := *data.meshes[mesh_index];
        for primitive_index : 0..cast(s64) mesh.primitives_count - 1 {
            primitive := *mesh.primitives[primitive_index];
            if primitive.type != .triangles {
                log("Skipping % primitive in %.", primitive.type, path);
                continue;
            }

            our_mesh, success := add_gltf_primitive(primitive);
            if !success continue;

            material_index := default_material;
            if primitive.material  material_index = material_indices[cgltf_material_index(data, primitive.material)];

            array_add(*mesh_primitives[mesh_index], .{our_mesh, material_index});
        }
    }

    gltf_to_world := Matrix4_Identity;
    gltf_to_world._22 = -1;
    gltf_to_world._33 = -1;
    root_from_gltf := multiply(root, gltf_to_world);

    for node_index : 0..cast(s64) data.nodes_count - 1 {
        node := *data.nodes[node_index];
        if !node.mesh continue;

        column_major : [16] float;
        cgltf_node_transform_world(node, column_major.data);

        node_transform : Matrix4;
        for row : 0..3  for column : 0..3  node_transform.v[row].component[column] = column_major[column * 4 + row];

        transform := multiply(root_from_gltf, node_transform);
        for mesh_primitives[cgltf_mesh_index(data, node.mesh)] {
            add_instance(it.mesh_index, it.material_index, transform);
        }
    }

    log("Loaded % (% meshes, % materials, % images).", path, data.meshes_count, data.materials_count, data.images_count);
    return true;
}

#scope_file

load_gltf_image :: (image: *cgltf_image, directory: string) -> Texture_Handle {
    width, height, channels : s32;
    pixels : *u8;

    name : string;
    if image.buffer_view {
        bytes := cgltf_buffer_view_data(image.buffer_view);
        pixels = stbi_load_from_memory(bytes, xx image.buffer_view.size, *width, *height, *channels, 4);
        name = ifx image.name then to_string(image.name) else "gltf image";
    } else {
        assert(image.uri != null);
        uri := copy_temporary_string(to_string(image.uri));
        uri.count = xx cgltf_decode_uri(uri.data);
        image_path := tprint("%1%2", directory, uri);
        pixels = stbi_load(temp_c_string(image_path), *width, *height, *channels, 4);
        name = image_path;
    }
    assert(pixels != null, "Failed to load glTF image %.", name);
    defer stbi_image_free(pixels);

    return add_texture(create_texture(command_buffers[0], pixels, xx width, xx height, .R8G8B8A8_SRGB, name));
}

add_gltf_material :: (data: *cgltf_data, gltf_material: *cgltf_material, image_textures: [] Texture_Handle, samplers: [] Sampler_Handle, sampler: Sampler_Handle, white_texture: Texture_Handle) -> u32 {
    material := Material.{base_color = .{1, 1, 1, 1}, texture = white_texture, sampler = sampler};

    if gltf_material.has_pbr_metallic_roughness {
        pbr := *gltf_material.pbr_metallic_roughness;
        factor := pbr.base_color_factor;
        material.base_color = .{factor[0], factor[1], factor[2], factor[3]};

        texture := pbr.base_color_texture.texture;
        if texture && texture.image {
            material.texture = image_textures[cgltf_image_index(data, texture.image)];
            if texture.sampler  material.sampler = samplers[cgltf_sampler_index(data, texture.sampler)];
        }
    }

    if gltf_material.alpha_mode == {
        case .mask;  material.alpha_cutoff = gltf_material.alpha_cutoff;
        case .blend; material.alpha_cutoff = 0.5;
    }

    return add_material(material);
}

gltf_sampler_info :: (sampler: *cgltf_sampler) -> VkSamplerCreateInfo {
    wrap :: (mode: cgltf_wrap_mode) -> VkSamplerAddressMode {
        if mode == {
            case .clamp_to_edge;   return .CLAMP_TO_EDGE;
            case .mirrored_repeat; return .MIRRORED_REPEAT;
            case;                  return .REPEAT;
        }
    }

    info := VkSamplerCreateInfo.{
        magFilter    = ifx sampler.mag_filter == .nearest then .NEAREST else .LINEAR,
        minFilter    = .LINEAR,
        mipmapMode   = .LINEAR,
        addressModeU = wrap(sampler.wrap_s),
        addressModeV = wrap(sampler.wrap_t),
        addressModeW = .REPEAT,
        maxLod       = VK_LOD_CLAMP_NONE,
    };

    if sampler.min_filter == {
        case .nearest;                info.minFilter = .NEAREST; info.maxLod = 0.25;
        case .linear;                 info.maxLod = 0.25;
        case .nearest_mipmap_nearest; info.minFilter = .NEAREST; info.mipmapMode = .NEAREST;
        case .linear_mipmap_nearest;  info.mipmapMode = .NEAREST;
        case .nearest_mipmap_linear;  info.minFilter = .NEAREST;
    }

    if info.minFilter == .LINEAR && info.magFilter == .LINEAR && info.mipmapMode == .LINEAR {
        info.anisotropyEnable = VK_TRUE;
        info.maxAnisotropy    = min(16.0, physical_device_context.properties2.properties.limits.maxSamplerAnisotropy);
    }

    return info;
}

add_gltf_primitive :: (primitive: *cgltf_primitive) -> mesh_index: u32, success: bool {
    position_accessor, uv_accessor : *cgltf_accessor;
    for attribute_index : 0..cast(s64) primitive.attributes_count - 1 {
        attribute := *primitive.attributes[attribute_index];
        if attribute.type == .position                          position_accessor = attribute.data;
        if attribute.type == .texcoord && attribute.index == 0  uv_accessor       = attribute.data;
    }
    if !position_accessor return 0, false;

    vertex_count := cast(s64) position_accessor.count;

    positions := NewArray(vertex_count, Vector3);
    defer array_free(positions);
    cgltf_accessor_unpack_floats(position_accessor, cast(*float) positions.data, xx (vertex_count * 3));

    attributes := NewArray(vertex_count, Vertex_Attributes);
    defer array_free(attributes);
    if uv_accessor {
        assert(cast(s64) uv_accessor.count == vertex_count);
        cgltf_accessor_unpack_floats(uv_accessor, cast(*float) attributes.data, xx (vertex_count * 2));
    }

    indices : [] u32;
    defer array_free(indices);
    if primitive.indices {
        indices = NewArray(xx primitive.indices.count, u32);
        cgltf_accessor_unpack_indices(primitive.indices, indices.data, size_of(u32), xx indices.count);
    } else {
        indices = NewArray(vertex_count, u32);
        for * indices  it.* = xx it_index;
    }

    for triangle : 0..indices.count / 3 - 1 {
        a := *indices[triangle * 3 + 1];
        b := *indices[triangle * 3 + 2];
        a.*, b.* = b.*, a.*;
    }

    return add_mesh(positions, attributes, indices), true;
}
