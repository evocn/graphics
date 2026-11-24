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

    mesh_primitives := NewArray(xx data.meshes_count, [..] Gltf_Primitive);
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

            gltf_primitive, success := add_gltf_primitive(primitive);
            if !success continue;

            gltf_primitive.material_index = default_material;
            if primitive.material  gltf_primitive.material_index = material_indices[cgltf_material_index(data, primitive.material)];

            array_add(*mesh_primitives[mesh_index], gltf_primitive);
        }
    }

    gltf_to_world := Matrix4_Identity;
    gltf_to_world._22 = -1;
    gltf_to_world._33 = -1;
    root_from_gltf := multiply(root, gltf_to_world);

    skeleton_indices := NewArray(xx data.skins_count, s64,, temp);
    for * skeleton_indices  it.* = -1;

    for node_index : 0..cast(s64) data.nodes_count - 1 {
        node := *data.nodes[node_index];
        if !node.mesh continue;

        if node.skin {
            skin_index := cgltf_skin_index(data, node.skin);
            if skeleton_indices[skin_index] < 0  skeleton_indices[skin_index] = add_gltf_skeleton(data, node.skin);

            for mesh_primitives[cgltf_mesh_index(data, node.mesh)] {
                assert(it.skin_vertices.address != 0, "A skinned primitive in % has no JOINTS_0/WEIGHTS_0.", path);
                add_deformable_draw(it.mesh, it.material_index, root_from_gltf, .{
                    skin_vertices  = it.skin_vertices,
                    skeleton_index = xx skeleton_indices[skin_index],
                });
            }
            continue;
        }

        column_major : [16] float;
        cgltf_node_transform_world(node, column_major.data);

        transform := multiply(root_from_gltf, gltf_matrix(column_major));
        for mesh_primitives[cgltf_mesh_index(data, node.mesh)] {
            add_draw(it.mesh, it.material_index, transform);
        }
    }

    log("Loaded % (% meshes, % materials, % images, % skins, % animations).", path, data.meshes_count, data.materials_count, data.images_count, data.skins_count, data.animations_count);
    return true;
}

#scope_file

Gltf_Primitive :: struct {
    mesh           : Mesh;
    material_index : u32;
    skin_vertices  : Gpu_Pointer(Skin_Vertex);
}

gltf_matrix :: (column_major: [16] float) -> Matrix4 {
    result : Matrix4;
    for row : 0..3  for column : 0..3  result.v[row].component[column] = column_major[column * 4 + row];
    return result;
}

add_gltf_skeleton :: (data: *cgltf_data, skin: *cgltf_skin) -> s64 {
    skeleton : Skeleton;

    skeleton.nodes = NewArray(xx data.nodes_count, Skeleton_Node);
    for node_index : 0..cast(s64) data.nodes_count - 1 {
        node := *data.nodes[node_index];
        out := *skeleton.nodes[node_index];
        if node.parent           out.parent      = xx cgltf_node_index(data, node.parent);
        if node.has_translation  out.translation = .{node.translation[0], node.translation[1], node.translation[2]};
        if node.has_rotation     out.rotation    = .{node.rotation[0], node.rotation[1], node.rotation[2], node.rotation[3]};
        if node.has_scale        out.scale       = .{node.scale[0], node.scale[1], node.scale[2]};
        if node.has_matrix {
            out.has_matrix = true;
            out.matrix     = gltf_matrix(node.matrix);
        }
    }

    order : [..] s32;
    stack : [..] s32;
    stack.allocator = temp;
    for skeleton.nodes  if it.parent < 0  array_add(*stack, xx it_index);
    while stack.count {
        node_index := pop(*stack);
        array_add(*order, node_index);
        node := *data.nodes[node_index];
        for 0..cast(s64) node.children_count - 1  array_add(*stack, xx cgltf_node_index(data, node.children[it]));
    }
    skeleton.order = order;

    joint_count := cast(s64) skin.joints_count;
    assert(joint_count <= 256, "Skins are limited to 256 joints, this one has %.", joint_count);
    skeleton.joints                = NewArray(joint_count, s32);
    skeleton.inverse_bind_matrices = NewArray(joint_count, Matrix4);
    skeleton.joint_matrices        = NewArray(joint_count, Matrix4x3);
    for 0..joint_count - 1 {
        skeleton.joints[it] = xx cgltf_node_index(data, skin.joints[it]);
        skeleton.inverse_bind_matrices[it] = Matrix4_Identity;
        if skin.inverse_bind_matrices {
            column_major : [16] float;
            cgltf_accessor_read_float(skin.inverse_bind_matrices, xx it, column_major.data, 16);
            skeleton.inverse_bind_matrices[it] = gltf_matrix(column_major);
        }
    }

    skeleton.clips = NewArray(xx data.animations_count, Animation_Clip);
    for animation_index : 0..cast(s64) data.animations_count - 1 {
        animation := *data.animations[animation_index];
        clip := *skeleton.clips[animation_index];
        clip.name = copy_string(ifx animation.name then to_string(animation.name) else tprint("Animation %", animation_index));

        channels : [..] Animation_Channel;
        for channel_index : 0..cast(s64) animation.channels_count - 1 {
            channel := *animation.channels[channel_index];
            if !channel.target_node continue;

            path : Animation_Path;
            if channel.target_path == {
                case .translation; path = .TRANSLATION;
                case .rotation;    path = .ROTATION;
                case .scale;       path = .SCALE;
                case;              continue;
            }
            components := ifx path == .ROTATION then 4 else 3;

            sampler := channel.sampler;
            key_count := cast(s64) sampler.input.count;
            times := NewArray(key_count, float);
            cgltf_accessor_unpack_floats(sampler.input, times.data, xx key_count);

            values := NewArray(key_count * components, float);
            if sampler.interpolation == .cubic_spline {
                raw := NewArray(key_count * components * 3, float,, temp);
                cgltf_accessor_unpack_floats(sampler.output, raw.data, xx raw.count);
                for key : 0..key_count - 1  for component : 0..components - 1  values[key * components + component] = raw[(key * 3 + 1) * components + component];
            } else {
                cgltf_accessor_unpack_floats(sampler.output, values.data, xx values.count);
            }

            array_add(*channels, .{
                node   = xx cgltf_node_index(data, channel.target_node),
                path   = path,
                step   = sampler.interpolation == .step,
                times  = times,
                values = values,
            });
            clip.duration = max(clip.duration, times[key_count - 1]);
        }
        clip.channels = channels;
    }

    array_add(*animation_context.skeletons, skeleton);
    return animation_context.skeletons.count - 1;
}

pack_skin_vertex :: (joints: [4] u32, weights: [4] float) -> Skin_Vertex {
    total := weights[0] + weights[1] + weights[2] + weights[3];
    normalized := weights;
    if total <= 0  normalized = .[1, 0, 0, 0];
    else           for * normalized  it.* /= total;

    quantized : [4] s32;
    sum, largest : s32;
    for normalized {
        quantized[it_index] = cast(s32) (it * 255 + 0.5);
        sum += quantized[it_index];
        if it > normalized[largest]  largest = xx it_index;
    }
    quantized[largest] += 255 - sum;

    result : Skin_Vertex;
    for 0..3 {
        assert(joints[it] < 256);
        result.joints  |= joints[it] << (8 * it);
        result.weights |= (cast(u32) quantized[it]) << (8 * it);
    }
    return result;
}

load_gltf_image :: (image: *cgltf_image, directory: string, format: VkFormat) -> Texture_Handle {
    name := ifx image.name then to_string(image.name) else "gltf image";

    if image.buffer_view {
        bytes := cgltf_buffer_view_data(image.buffer_view);
        return load_image_texture_from_memory(bytes, xx image.buffer_view.size, format, name);
    }

    assert(image.uri != null);
    if begins_with(to_string(image.uri), "data:") {
        data_uri := to_string(image.uri);
        comma := find_index_from_left(data_uri, #char ",");
        assert(comma >= 0 && contains(slice(data_uri, 0, comma), ";base64"), "Unsupported data URI in glTF image %.", name);

        bytes, decoded := base64_decode(slice(data_uri, comma + 1, data_uri.count - comma - 1));
        assert(decoded, "Invalid base64 in glTF image %.", name);
        defer free(bytes);
        return load_image_texture_from_memory(bytes.data, bytes.count, format, name);
    }

    uri := copy_temporary_string(to_string(image.uri));
    uri.count = xx cgltf_decode_uri(uri.data);
    return load_image_texture(tprint("%1%2", directory, uri), format);
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
        info.maxAnisotropy    = min(16.0, device_context.limits.maxSamplerAnisotropy);
    }

    return info;
}

add_gltf_primitive :: (primitive: *cgltf_primitive) -> Gltf_Primitive, success: bool {
    position_accessor, normal_accessor, tangent_accessor, uv_accessor, joints_accessor, weights_accessor : *cgltf_accessor;
    for attribute_index : 0..cast(s64) primitive.attributes_count - 1 {
        attribute := *primitive.attributes[attribute_index];
        if attribute.type == .position                          position_accessor = attribute.data;
        if attribute.type == .normal                            normal_accessor   = attribute.data;
        if attribute.type == .tangent                           tangent_accessor  = attribute.data;
        if attribute.type == .texcoord && attribute.index == 0  uv_accessor       = attribute.data;
        if attribute.type == .joints   && attribute.index == 0  joints_accessor   = attribute.data;
        if attribute.type == .weights  && attribute.index == 0  weights_accessor  = attribute.data;
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

    result := Gltf_Primitive.{mesh = add_mesh(positions, attributes, indices)};

    if joints_accessor && weights_accessor {
        assert(cast(s64) joints_accessor.count == vertex_count && cast(s64) weights_accessor.count == vertex_count);
        skin_vertices := NewArray(vertex_count, Skin_Vertex,, temp);
        for * skin_vertices {
            joints  : [4] u32;
            weights : [4] float;
            cgltf_accessor_read_uint(joints_accessor, xx it_index, joints.data, 4);
            cgltf_accessor_read_float(weights_accessor, xx it_index, weights.data, 4);
            it.* = pack_skin_vertex(joints, weights);
        }
        result.skin_vertices = add_skin_vertices(skin_vertices);
    }

    return result, true;
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
