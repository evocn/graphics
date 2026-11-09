camera_position   : Vector3 = .{0, 0, -2};
camera_yaw        : float;
camera_pitch      : float;
mouse_look_active : bool;

CAMERA_FOV_VERTICAL :: PI / 3.0;
CAMERA_NEAR_PLANE   :: 0.1;
CAMERA_FAR_PLANE    :: 100.0;
CAMERA_MOVE_SPEED   :: 2.0;
LOOK_SENSITIVITY    :: 0.003;
PITCH_LIMIT         :: 1.55;

update_camera :: (dt: float) {
    if mouse_look_active && !input_application_has_focus {
        set_mouse_look(false);
    }

    if mouse_look_active {
        camera_yaw   += cast(float) mouse_delta_x * LOOK_SENSITIVITY;
        camera_pitch += cast(float) mouse_delta_y * LOOK_SENSITIVITY;
        Clamp(*camera_pitch, -PITCH_LIMIT, PITCH_LIMIT);
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
        camera_position += unit_vector(move) * (CAMERA_MOVE_SPEED * dt);
    }
}

set_mouse_look :: (active: bool) {
    if active == mouse_look_active  return;
    mouse_look_active = active;

    show_os_cursor(!active);

    #if OS == .WINDOWS {
        if active {
            rect : RECT;
            GetClientRect(window, *rect);

            top_left     := POINT.{rect.left,  rect.top};
            bottom_right := POINT.{rect.right, rect.bottom};
            ClientToScreen(window, *top_left);
            ClientToScreen(window, *bottom_right);

            clip := RECT.{top_left.x, top_left.y, bottom_right.x, bottom_right.y};
            ClipCursor(*clip);
        }
        else {
            ClipCursor(null);
        }
    }
}

camera_basis :: () -> forward: Vector3, right: Vector3, down: Vector3 {
    cy := cos(camera_yaw);
    sy := sin(camera_yaw);
    cp := cos(camera_pitch);
    sp := sin(camera_pitch);

    forward := Vector3.{cp * sy, sp, cp * cy};
    right   := Vector3.{cy, 0, -sy};
    down    := Vector3.{-sp * sy, cp, -sp * cy};

    return forward, right, down;
}

camera_view_projection :: (aspect: float) -> Matrix4 {
    forward, right, down := camera_basis();

    view := Matrix4_Identity;
    view.v[0] = .{right.x,   right.y,   right.z,   -dot(right,   camera_position)};
    view.v[1] = .{down.x,    down.y,    down.z,    -dot(down,    camera_position)};
    view.v[2] = .{forward.x, forward.y, forward.z, -dot(forward, camera_position)};

    f := 1.0 / tan(CAMERA_FOV_VERTICAL / 2.0);

    projection : Matrix4;
    projection._11 = f / aspect;
    projection._22 = f;
    projection._33 = CAMERA_FAR_PLANE / (CAMERA_FAR_PLANE - CAMERA_NEAR_PLANE);
    projection._34 = -(CAMERA_NEAR_PLANE * CAMERA_FAR_PLANE) / (CAMERA_FAR_PLANE - CAMERA_NEAR_PLANE);
    projection._43 = 1;

    return projection * view;
}
