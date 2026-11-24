animation_context : struct {
    skeletons : [..] Skeleton;
}

Skeleton :: struct {
    nodes                 : [] Skeleton_Node;
    order                 : [] s32;
    joints                : [] s32;
    inverse_bind_matrices : [] Matrix4;
    clips                 : [] Animation_Clip;
    clip_index            : s32;
    time                  : float;
    joint_matrices        : [] Matrix4x3;
}

Skeleton_Node :: struct {
    parent      : s32 = -1;
    translation : Vector3;
    rotation    : Quaternion;
    scale       := Vector3.{1, 1, 1};
    has_matrix  : bool;
    matrix      : Matrix4;
}

Animation_Path :: enum u8 {
    TRANSLATION;
    ROTATION;
    SCALE;
}

Animation_Channel :: struct {
    node   : s32;
    path   : Animation_Path;
    step   : bool;
    times  : [] float;
    values : [] float;
}

Animation_Clip :: struct {
    name     : string;
    duration : float;
    channels : [] Animation_Channel;
}

deinit_animation :: () {
    for skeleton : animation_context.skeletons {
        array_free(skeleton.nodes);
        array_free(skeleton.order);
        array_free(skeleton.joints);
        array_free(skeleton.inverse_bind_matrices);
        array_free(skeleton.joint_matrices);
        for clip : skeleton.clips {
            for clip.channels {
                array_free(it.times);
                array_free(it.values);
            }
            array_free(clip.channels);
            free(clip.name);
        }
        array_free(skeleton.clips);
    }
    array_free(animation_context.skeletons);
}

update_animations :: (dt: float) {
    for * skeleton : animation_context.skeletons {
        if skeleton.clips.count {
            duration := skeleton.clips[skeleton.clip_index].duration;
            skeleton.time += dt;
            if duration > 0  skeleton.time -= floor(skeleton.time / duration) * duration;
        }
        pose_skeleton(skeleton);
    }
}

animation_debug_ui :: () {
    if !animation_context.skeletons.count return;

    ImGui.SetNextWindowPos(.{10, 260}, .FirstUseEver);
    if ImGui.Begin("Animation", null, .AlwaysAutoResize | .NoSavedSettings) {
        for * skeleton : animation_context.skeletons {
            if !skeleton.clips.count continue;

            builder : String_Builder;
            builder.allocator = temp;
            for skeleton.clips  print_to_builder(*builder, "%\0", it.name);
            append(*builder, "\0");
            names := builder_to_string(*builder,, temp);

            previous := skeleton.clip_index;
            ImGui.Combo(temp_c_string(tprint("Skeleton %", it_index)), *skeleton.clip_index, names.data);
            if skeleton.clip_index != previous  skeleton.time = 0;
        }
    }
    ImGui.End();
}

#scope_file

pose_skeleton :: (skeleton: *Skeleton) {
    nodes := array_copy(skeleton.nodes,, temp);

    if skeleton.clips.count {
        clip := skeleton.clips[skeleton.clip_index];
        for clip.channels {
            node := *nodes[it.node];
            if it.path == {
                case .TRANSLATION;
                    value := sample(it, skeleton.time, 3);
                    node.translation = .{value[0], value[1], value[2]};
                case .ROTATION;
                    value := sample(it, skeleton.time, 4);
                    rotation := Quaternion.{value[0], value[1], value[2], value[3]};
                    normalize_or_identity(*rotation);
                    node.rotation = rotation;
                case .SCALE;
                    value := sample(it, skeleton.time, 3);
                    node.scale = .{value[0], value[1], value[2]};
            }
        }
    }

    globals := NewArray(nodes.count, Matrix4,, temp);
    for skeleton.order {
        node := nodes[it];
        local := ifx node.has_matrix then node.matrix else trs_matrix(node.translation, node.rotation, node.scale);
        globals[it] = ifx node.parent >= 0 then multiply(globals[node.parent], local) else local;
    }

    for joint, joint_index : skeleton.joints {
        joint_matrix := multiply(globals[joint], skeleton.inverse_bind_matrices[joint_index]);
        for row : 0..2  skeleton.joint_matrices[joint_index].v[row] = joint_matrix.v[row];
    }
}

sample :: (channel: Animation_Channel, time: float, components: int) -> [4] float {
    times := channel.times;
    previous, next := 0, 0;
    if time >= times[times.count - 1] {
        previous, next = times.count - 1, times.count - 1;
    } else if time > times[0] {
        next = 1;
        while times[next] < time  next += 1;
        previous = next - 1;
    }

    t := 0.0;
    if next != previous && !channel.step  t = (time - times[previous]) / (times[next] - times[previous]);

    a := channel.values.data + previous * components;
    b := channel.values.data + next * components;

    sign := 1.0;
    if components == 4 {
        d := a[0] * b[0] + a[1] * b[1] + a[2] * b[2] + a[3] * b[3];
        if d < 0  sign = -1;
    }

    result : [4] float;
    for 0..components - 1  result[it] = a[it] + (b[it] * sign - a[it]) * t;
    return result;
}

normalize_or_identity :: (q: *Quaternion) {
    length := sqrt(q.x * q.x + q.y * q.y + q.z * q.z + q.w * q.w);
    if length < 0.000001 {
        q.* = .{0, 0, 0, 1};
        return;
    }
    q.x /= length;
    q.y /= length;
    q.z /= length;
    q.w /= length;
}

trs_matrix :: (translation: Vector3, rotation: Quaternion, scale: Vector3) -> Matrix4 {
    x, y, z, w := rotation.x, rotation.y, rotation.z, rotation.w;

    result := Matrix4_Identity;
    result.v[0] = .{(1 - 2 * (y * y + z * z)) * scale.x, (2 * (x * y - z * w)) * scale.y,     (2 * (x * z + y * w)) * scale.z,     translation.x};
    result.v[1] = .{(2 * (x * y + z * w)) * scale.x,     (1 - 2 * (x * x + z * z)) * scale.y, (2 * (y * z - x * w)) * scale.z,     translation.y};
    result.v[2] = .{(2 * (x * z - y * w)) * scale.x,     (2 * (y * z + x * w)) * scale.y,     (1 - 2 * (x * x + y * y)) * scale.z, translation.z};
    return result;
}
