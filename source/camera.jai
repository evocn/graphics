// Graphics
// Camera

camera : struct {
    position : Vector3 = .{0, 0, -2};
    yaw      : float = 0;
    pitch    : float = 0;

    mouse_look_active : bool;

    fov_vertical : float = PI / 3.0;
    near_plane   : float = 0.1;
    far_plane    : float = 100.0;

    MOVE_SPEED       :: 2.0;
    LOOK_SENSITIVITY :: 0.003;
    PITCH_LIMIT      :: 1.55;
}

update_camera :: (dt: float) {
    using camera;

    if mouse_look_active && !input_application_has_focus {
        set_mouse_look(false);
    }

    if mouse_look_active {
        yaw   += cast(float) mouse_delta_x * LOOK_SENSITIVITY;
        pitch += cast(float) mouse_delta_y * LOOK_SENSITIVITY;
        Clamp(*pitch, -PITCH_LIMIT, PITCH_LIMIT);
    }

    forward, right := camera_basis();

    move : Vector3;
    if input_button_states[#char "W"] & .DOWN  move += forward;
    if input_button_states[#char "S"] & .DOWN  move -= forward;
    if input_button_states[#char "D"] & .DOWN  move += right;
    if input_button_states[#char "A"] & .DOWN  move -= right;
    if input_button_states[#char "E"] & .DOWN  move.y -= 1;
    if input_button_states[#char "Q"] & .DOWN  move.y += 1;

    if length(move) > 0 {
        position += unit_vector(move) * (MOVE_SPEED * dt);
    }
}

set_mouse_look :: (active: bool) {
    if active == camera.mouse_look_active  return;
    camera.mouse_look_active = active;

    show_os_cursor(!active);

    #if OS == .WINDOWS {
        if active {
            rect : RECT;
            GetClientRect(program_state.window, *rect);

            top_left     := POINT.{rect.left,  rect.top};
            bottom_right := POINT.{rect.right, rect.bottom};
            ClientToScreen(program_state.window, *top_left);
            ClientToScreen(program_state.window, *bottom_right);

            clip := RECT.{top_left.x, top_left.y, bottom_right.x, bottom_right.y};
            ClipCursor(*clip);
        }
        else {
            ClipCursor(null);
        }
    }
}

// World convention: +X right, +Y down, +Z forward. This matches Vulkan clip space
// directly, so no axis flips appear anywhere in the projection.
camera_basis :: () -> forward: Vector3, right: Vector3, down: Vector3 {
    using camera;

    cy := cos(yaw);
    sy := sin(yaw);
    cp := cos(pitch);
    sp := sin(pitch);

    forward := Vector3.{cp * sy, sp, cp * cy};
    right   := Vector3.{cy, 0, -sy};
    down    := Vector3.{-sp * sy, cp, -sp * cy};

    return forward, right, down;
}

camera_view_projection :: (aspect: float) -> Matrix4 {
    using camera;

    forward, right, down := camera_basis();

    view := Matrix4_Identity;
    view.v[0] = .{right.x,   right.y,   right.z,   -dot(right,   position)};
    view.v[1] = .{down.x,    down.y,    down.z,    -dot(down,    position)};
    view.v[2] = .{forward.x, forward.y, forward.z, -dot(forward, position)};

    f := 1.0 / tan(fov_vertical / 2.0);

    projection : Matrix4;
    projection._11 = f / aspect;
    projection._22 = f;
    projection._33 = far_plane / (far_plane - near_plane);
    projection._34 = -(near_plane * far_plane) / (far_plane - near_plane);
    projection._43 = 1;

    return projection * view;
}
