// Graphics
// glTF

load_gltf :: (path: string, root: Matrix4, sampler: Sampler_Handle) -> bool {
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

    linear_images := NewArray(xx data.images_count, bool);
    defer array_free(linear_images);
    mark_linear :: (view: cgltf_texture_view) #expand {
        if view.texture && view.texture.image  linear_images[cgltf_image_index(data, view.texture.image)] = true;
    }
    for material_index : 0..cast(s64) data.materials_count - 1 {
        gltf_material := *data.materials[material_index];
        mark_linear(gltf_material.normal_texture);
        mark_linear(gltf_material.pbr_metallic_roughness.metallic_roughness_texture);
    }

    image_textures := NewArray(xx data.images_count, Texture_Handle);
    defer array_free(image_textures);
    for image_index : 0..cast(s64) data.images_count - 1 {
        format := ifx linear_images[image_index] then VkFormat.R8G8B8A8_UNORM else .R8G8B8A8_SRGB;
        image_textures[image_index] = load_gltf_image(*data.images[image_index], directory, format);
    }

    samplers := NewArray(xx data.samplers_count, Sampler_Handle);
    defer array_free(samplers);
    for sampler_index : 0..cast(s64) data.samplers_count - 1 {
        samplers[sampler_index] = create_sampler(gltf_sampler_info(*data.samplers[sampler_index]));
    }

    material_indices := NewArray(xx data.materials_count, u32);
    defer array_free(material_indices);
    for material_index : 0..cast(s64) data.materials_count - 1 {
        material_indices[material_index] = add_gltf_material(data, *data.materials[material_index], image_textures, samplers, sampler);
    }
    default_material := add_material(.{base_color = .{1, 1, 1, 1}, sampler = sampler});

    mesh_primitives := NewArray(xx data.meshes_count, [..] Draw_Data);
    defer {
        for mesh_primitives  array_free(it);
        array_free(mesh_primitives);
    }
    for mesh_index : 0..cast(s64) data.meshes_count - 1 {
        gltf_mesh := *data.meshes[mesh_index];
        for primitive_index : 0..cast(s64) gltf_mesh.primitives_count - 1 {
            primitive := *gltf_mesh.primitives[primitive_index];
            if primitive.type != .triangles {
                log("Skipping % primitive in %.", primitive.type, path);
                continue;
            }

            mesh, success := add_gltf_primitive(primitive);
            if !success continue;

            mesh.material_index = default_material;
            if primitive.material  mesh.material_index = material_indices[cgltf_material_index(data, primitive.material)];

            array_add(*mesh_primitives[mesh_index], mesh);
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
            add_draw(it, it.material_index, transform);
        }
    }

    log("Loaded % (% meshes, % materials, % images).", path, data.meshes_count, data.materials_count, data.images_count);
    return true;
}

#scope_file

load_gltf_image :: (image: *cgltf_image, directory: string, format: VkFormat) -> Texture_Handle {
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

    return add_texture(create_texture(command_buffers[0], pixels, xx width, xx height, format, name));
}

add_gltf_material :: (data: *cgltf_data, gltf_material: *cgltf_material, image_textures: [] Texture_Handle, samplers: [] Sampler_Handle, sampler: Sampler_Handle) -> u32 {
    material := Material.{base_color = .{1, 1, 1, 1}, sampler = sampler};

    image_of :: (view: cgltf_texture_view) -> Texture_Handle #expand {
        if !view.texture || !view.texture.image  return .{};
        return image_textures[cgltf_image_index(data, view.texture.image)];
    }

    if gltf_material.has_pbr_metallic_roughness {
        pbr := *gltf_material.pbr_metallic_roughness;
        factor := pbr.base_color_factor;
        material.base_color = .{factor[0], factor[1], factor[2], factor[3]};
        material.metallic   = pbr.metallic_factor;
        material.roughness  = pbr.roughness_factor;

        material.texture                    = image_of(pbr.base_color_texture);
        material.metallic_roughness_texture = image_of(pbr.metallic_roughness_texture);

        base_texture := pbr.base_color_texture.texture;
        if base_texture && base_texture.sampler  material.sampler = samplers[cgltf_sampler_index(data, base_texture.sampler)];
    }

    material.normal_texture = image_of(gltf_material.normal_texture);
    if gltf_material.normal_texture.texture  material.normal_scale = gltf_material.normal_texture.scale;

    material.double_sided = xx gltf_material.double_sided;

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
        info.maxAnisotropy    = min(16.0, device_limits.maxSamplerAnisotropy);
    }

    return info;
}

add_gltf_primitive :: (primitive: *cgltf_primitive) -> Draw_Data, success: bool {
    position_accessor, normal_accessor, tangent_accessor, uv_accessor : *cgltf_accessor;
    for attribute_index : 0..cast(s64) primitive.attributes_count - 1 {
        attribute := *primitive.attributes[attribute_index];
        if attribute.type == .position                          position_accessor = attribute.data;
        if attribute.type == .normal                            normal_accessor   = attribute.data;
        if attribute.type == .tangent                           tangent_accessor  = attribute.data;
        if attribute.type == .texcoord && attribute.index == 0  uv_accessor       = attribute.data;
    }
    if !position_accessor return .{}, false;

    vertex_count := cast(s64) position_accessor.count;

    positions := NewArray(vertex_count, Vector3);
    defer array_free(positions);
    cgltf_accessor_unpack_floats(position_accessor, cast(*float) positions.data, xx (vertex_count * 3));

    indices : [] u32;
    defer array_free(indices);
    if primitive.indices {
        indices = NewArray(xx primitive.indices.count, u32);
        cgltf_accessor_unpack_indices(primitive.indices, indices.data, size_of(u32), xx indices.count);
    } else {
        indices = NewArray(vertex_count, u32);
        for * indices  it.* = xx it_index;
    }

    attributes := NewArray(vertex_count, Vertex_Attributes);
    defer array_free(attributes);

    if uv_accessor {
        assert(cast(s64) uv_accessor.count == vertex_count);
        uvs := NewArray(vertex_count, Vector2,, temp);
        cgltf_accessor_unpack_floats(uv_accessor, cast(*float) uvs.data, xx (vertex_count * 2));
        for uvs  attributes[it_index].uv = it;
    }

    if normal_accessor {
        assert(cast(s64) normal_accessor.count == vertex_count);
        normals := NewArray(vertex_count, Vector3,, temp);
        cgltf_accessor_unpack_floats(normal_accessor, cast(*float) normals.data, xx (vertex_count * 3));
        for normals  attributes[it_index].normal = it;
    } else {
        for triangle : 0..indices.count / 3 - 1 {
            a := indices[triangle * 3 + 0];
            b := indices[triangle * 3 + 1];
            c := indices[triangle * 3 + 2];
            face_normal := cross(positions[b] - positions[a], positions[c] - positions[a]);
            attributes[a].normal += face_normal;
            attributes[b].normal += face_normal;
            attributes[c].normal += face_normal;
        }
        for * attributes  it.normal = unit_vector(it.normal);
    }

    if tangent_accessor {
        assert(cast(s64) tangent_accessor.count == vertex_count);
        tangents := NewArray(vertex_count, Vector4,, temp);
        cgltf_accessor_unpack_floats(tangent_accessor, cast(*float) tangents.data, xx (vertex_count * 4));
        for tangents  attributes[it_index].tangent = it;
    } else {
        generate_tangents(positions, indices, attributes);
    }

    for triangle : 0..indices.count / 3 - 1 {
        a := *indices[triangle * 3 + 1];
        b := *indices[triangle * 3 + 2];
        a.*, b.* = b.*, a.*;
    }

    return add_mesh(positions, attributes, indices), true;
}

generate_tangents :: (positions: [] Vector3, indices: [] u32, attributes: [] Vertex_Attributes) {
    tangents   := NewArray(positions.count, Vector3,, temp);
    bitangents := NewArray(positions.count, Vector3,, temp);

    for triangle : 0..indices.count / 3 - 1 {
        corners := u32.[indices[triangle * 3 + 0], indices[triangle * 3 + 1], indices[triangle * 3 + 2]];
        a, b, c := corners[0], corners[1], corners[2];

        edge1 := positions[b] - positions[a];
        edge2 := positions[c] - positions[a];
        duv1  := attributes[b].uv - attributes[a].uv;
        duv2  := attributes[c].uv - attributes[a].uv;

        determinant := duv1.x * duv2.y - duv2.x * duv1.y;
        if abs(determinant) < 0.0000001 then continue;
        r := 1.0 / determinant;

        tangent   := (edge1 * duv2.y - edge2 * duv1.y) * r;
        bitangent := (edge2 * duv1.x - edge1 * duv2.x) * r;
        for corners {
            tangents[it]   += tangent;
            bitangents[it] += bitangent;
        }
    }

    for * attributes {
        n := it.normal;
        t := tangents[it_index] - n * dot(n, tangents[it_index]);
        if length(t) < 0.000001 {
            t = ifx abs(n.x) < 0.9 then cross(n, .{1, 0, 0}) else cross(n, .{0, 1, 0});
        }
        t = unit_vector(t);
        w := ifx dot(cross(n, t), bitangents[it_index]) < 0 then -1.0 else 1.0;
        it.tangent = .{t.x, t.y, t.z, w};
    }
}
