input_context : struct {
    quit       : bool;
    mouse_look : bool;
    look_delta : Vector2;
    move       : Vector3;
}

update_input :: () {
    update_window_events();

    for events_this_frame {
        imgui_process_event(it);

        if it.type == .QUIT  input_context.quit = true;
        if it.type != .KEYBOARD || !it.key_pressed  continue;

        if it.alt_pressed && it.key_code == .F4  input_context.quit = true;

        if it.key_code == .MOUSE_BUTTON_LEFT && !ImGui.GetIO().WantCaptureMouse {
            set_mouse_look(true);
        }

        if it.key_code == .ESCAPE {
            if input_context.mouse_look  set_mouse_look(false);
            else                         input_context.quit = true;
        }
    }

    for get_window_resizes() {
        if it.window != main_context.window continue;

        main_context.window_width  = xx it.width;
        main_context.window_height = xx it.height;
        swapchain_context.needs_recreation = true;
    }

    if input_context.mouse_look && !input_application_has_focus  set_mouse_look(false);

    input_context.look_delta = .{};
    if input_context.mouse_look  input_context.look_delta = .{xx mouse_delta_x, xx mouse_delta_y};

    is_down :: (key: Key_Code) -> float {
        return ifx input_button_states[key] & .DOWN then 1.0 else 0.0;
    }
    input_context.move = .{
        x = is_down(xx #char "D") - is_down(xx #char "A"),
        y = is_down(xx #char "Q") - is_down(xx #char "E"),
        z = is_down(xx #char "W") - is_down(xx #char "S"),
    };
}

#scope_file

set_mouse_look :: (active: bool) {
    if active == input_context.mouse_look  return;
    input_context.mouse_look = active;

    show_os_cursor(!active);

    #if OS == .WINDOWS {
        if active {
            rect : RECT;
            GetClientRect(main_context.window, *rect);

            top_left     := POINT.{rect.left,  rect.top};
            bottom_right := POINT.{rect.right, rect.bottom};
            ClientToScreen(main_context.window, *top_left);
            ClientToScreen(main_context.window, *bottom_right);

            clip := RECT.{top_left.x, top_left.y, bottom_right.x, bottom_right.y};
            ClipCursor(*clip);
        }
        else {
            ClipCursor(null);
        }
    }
}
