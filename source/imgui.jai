imgui_context      : *ImGui.ImGuiContext;
imgui_shaders      : [2] VkShaderEXT;
imgui_font_texture : Texture;
imgui_sampler      : Sampler_Handle;

IMGUI_VERTEX_BUDGET      :: 65536;
IMGUI_INDEX_BUDGET       :: 262144;
IMGUI_VERTEX_SLOT_STRIDE :: IMGUI_VERTEX_BUDGET * size_of(ImGui.ImDrawVert);
IMGUI_INDEX_SLOT_STRIDE  :: IMGUI_INDEX_BUDGET  * size_of(ImGui.ImDrawIdx);
imgui_vertex_offset : VkDeviceSize;
imgui_index_offset  : VkDeviceSize;

imgui_time              : float64;
imgui_mouse_pressed     : [3] bool;
imgui_mouse_wheel       : float;
imgui_clipboard_cstring : *u8;

Imgui_Push_Data :: struct @Gpu {
    vertices  : Gpu_Pointer(ImGui.ImDrawVert);
    scale     : Vector2;
    translate : Vector2;
    texture   : Texture_Handle;
    sampler   : Sampler_Handle;
}

init_imgui :: () {
    result : VkResult;

    imgui_context = ImGui.CreateContext();

    io := ImGui.GetIO();
    io.IniFilename = null;

    {
        io.KeyMap[ImGui.Key.Tab]        = xx Key_Code.TAB;
        io.KeyMap[ImGui.Key.LeftArrow]  = xx Key_Code.ARROW_LEFT;
        io.KeyMap[ImGui.Key.RightArrow] = xx Key_Code.ARROW_RIGHT;
        io.KeyMap[ImGui.Key.UpArrow]    = xx Key_Code.ARROW_UP;
        io.KeyMap[ImGui.Key.DownArrow]  = xx Key_Code.ARROW_DOWN;
        io.KeyMap[ImGui.Key.PageUp]     = xx Key_Code.PAGE_UP;
        io.KeyMap[ImGui.Key.PageDown]   = xx Key_Code.PAGE_DOWN;
        io.KeyMap[ImGui.Key.Home]       = xx Key_Code.HOME;
        io.KeyMap[ImGui.Key.End]        = xx Key_Code.END;
        io.KeyMap[ImGui.Key.Delete]     = xx Key_Code.DELETE;
        io.KeyMap[ImGui.Key.Backspace]  = xx Key_Code.BACKSPACE;
        io.KeyMap[ImGui.Key.Enter]      = xx Key_Code.ENTER;
        io.KeyMap[ImGui.Key.Escape]     = xx Key_Code.ESCAPE;
        io.KeyMap[ImGui.Key.A]          = #char "A";
        io.KeyMap[ImGui.Key.C]          = #char "C";
        io.KeyMap[ImGui.Key.V]          = #char "V";
        io.KeyMap[ImGui.Key.X]          = #char "X";
        io.KeyMap[ImGui.Key.Y]          = #char "Y";
        io.KeyMap[ImGui.Key.Z]          = #char "Z";

        io.SetClipboardTextFn = imgui_set_clipboard_text;
        io.GetClipboardTextFn = imgui_get_clipboard_text;
        io.ClipboardUserData = null;

        #if OS == .WINDOWS { io.ImeWindowHandle = window; }
    }

    {
        imgui_vertex_offset = heap_allocate(*buffer_heap, FRAMES_IN_FLIGHT * IMGUI_VERTEX_SLOT_STRIDE, 256);
        imgui_index_offset  = heap_allocate(*buffer_heap, FRAMES_IN_FLIGHT * IMGUI_INDEX_SLOT_STRIDE,  256);
    }

    imgui_shaders = create_graphics_shaders("imgui");

    {
        font_size := cast(float) window_height / 50.0;
        font := io.Fonts.AddFontFromFileTTF(io.Fonts, "assets/fonts/Merriweather/Merriweather-VariableFont_opsz,wdth,wght.ttf", font_size);
        assert(font != null, "Unable to load the ImGui font.");
    }

    {
        pixels : *u8;
        width, height, bpp : s32;
        io.Fonts.GetTexDataAsRGBA32(io.Fonts, *pixels, *width, *height, *bpp);

        imgui_font_texture = create_texture(command_buffers[0], pixels, xx width, xx height, .R8G8B8A8_UNORM, "imgui font texture", generate_mips = false);
        io.Fonts.TexID = cast(*void) imgui_font_texture.handle.id;
    }

    imgui_sampler = create_sampler(.{
        magFilter    = .LINEAR,
        minFilter    = .LINEAR,
        mipmapMode   = .NEAREST,
        addressModeU = .CLAMP_TO_EDGE,
        addressModeV = .CLAMP_TO_EDGE,
        addressModeW = .CLAMP_TO_EDGE,
        maxLod       = VK_LOD_CLAMP_NONE,
    });
}

deinit_imgui :: () {

    destroy_graphics_shaders(imgui_shaders);
    destroy_texture(imgui_font_texture);

    free(imgui_clipboard_cstring);
    ImGui.DestroyContext(imgui_context);
}

imgui_get_clipboard_text :: (data: *void) -> *u8 #c_call {
    result : *u8;
    push_context {
        free(imgui_clipboard_cstring);

        text := Clipboard.os_clipboard_get_text();
        defer free(text);

        imgui_clipboard_cstring = alloc(text.count + 1);
        memcpy(imgui_clipboard_cstring, text.data, text.count);
        imgui_clipboard_cstring[text.count] = 0;

        result = imgui_clipboard_cstring;
    }
    return result;
}

imgui_set_clipboard_text :: (data: *void, text: *u8) #c_call {
    push_context {
        Clipboard.os_clipboard_set_text(to_string(text));
    }
}

imgui_process_event :: (event: Event) -> bool {
    io := ImGui.GetIO();
    if event.type == {
        case .MOUSE_WHEEL;
            if event.wheel_delta > 0 imgui_mouse_wheel = 1;
            if event.wheel_delta < 0 imgui_mouse_wheel = -1;
            return true;

        case .TEXT_INPUT;
            io.AddInputCharacter(io, event.utf32);
            return true;

        case .KEYBOARD;
            key := event.key_code;

            if key == .MOUSE_BUTTON_LEFT   { if event.key_pressed imgui_mouse_pressed[0] = true;  return true; }
            if key == .MOUSE_BUTTON_RIGHT  { if event.key_pressed imgui_mouse_pressed[1] = true;  return true; }
            if key == .MOUSE_BUTTON_MIDDLE { if event.key_pressed imgui_mouse_pressed[2] = true;  return true; }

            io.KeysDown[cast(s64)key] = cast(bool) event.key_pressed;
            io.KeyShift = event.shift_pressed;
            io.KeyCtrl  = event.ctrl_pressed;
            io.KeyAlt   = event.alt_pressed;
            io.KeySuper = event.cmd_meta_pressed;
            return true;
    }
    return false;
}

imgui_new_frame :: () {
    io := ImGui.GetIO();

    io.DisplaySize             = .{xx window_width, xx window_height};
    io.DisplayFramebufferScale = .{1, 1};

    now := seconds_since_init();
    if imgui_time > 0  io.DeltaTime = cast(float)(now - imgui_time);
    else                     io.DeltaTime = 1.0/60.0;
    if io.DeltaTime <= 0     io.DeltaTime = 0.000001;
    imgui_time = now;

    mouse_x, mouse_y := get_mouse_pointer_position(window, false);
    if !mouse_look_active && is_mouse_over_window(window) {
        io.MousePos = .{xx mouse_x, xx mouse_y};
    } else {
        io.MousePos = .{-FLOAT32_MAX, -FLOAT32_MAX};
    }

    is_down :: (key: Key_Code) -> bool {
        return cast(bool)(input_button_states[key] & .DOWN);
    }
    io.MouseDown[0] = imgui_mouse_pressed[0] || is_down(.MOUSE_BUTTON_LEFT);
    io.MouseDown[1] = imgui_mouse_pressed[1] || is_down(.MOUSE_BUTTON_RIGHT);
    io.MouseDown[2] = imgui_mouse_pressed[2] || is_down(.MOUSE_BUTTON_MIDDLE);
    imgui_mouse_pressed = .[false, false, false];

    io.MouseWheel = imgui_mouse_wheel;
    imgui_mouse_wheel = 0;

    ImGui.NewFrame();
}

imgui_debug_ui :: () {
    io := ImGui.GetIO();

    OVERLAY_FLAGS :: ImGui.WindowFlags.NoDecoration | .AlwaysAutoResize | .NoSavedSettings | .NoFocusOnAppearing | .NoInputs;

    MARGIN :: 10.0;
    ImGui.SetNextWindowPos(.{MARGIN, MARGIN}, .Always);
    ImGui.SetNextWindowBgAlpha(0.6);
    if ImGui.Begin("##stats", null, OVERLAY_FLAGS) {
        frame_ms := ifx io.Framerate > 0 then 1000.0 / io.Framerate else 0;
        ImGui.Text("% ms (% FPS)",
            formatFloat(frame_ms,     trailing_width = 2, zero_removal = .NO),
            formatFloat(io.Framerate, trailing_width = 1, zero_removal = .NO));
        ImGui.Text("GPU % ms", formatFloat(gpu_frame_ms, trailing_width = 2, zero_removal = .NO));
    }
    ImGui.End();

    ImGui.SetNextWindowPos(.{MARGIN, 90}, .FirstUseEver);
    if ImGui.Begin("Lighting", null, .AlwaysAutoResize | .NoSavedSettings) {
        ImGui.SliderFloat("Sun", *sun_intensity, 0, 10);
        ImGui.SliderFloat("Exposure", *exposure, 0.1, 4);
        ImGui.Combo("View", cast(*s32) *debug_view, DEBUG_VIEW_NAMES.data);
    }
    ImGui.End();
}

render_imgui :: (command_buffer: VkCommandBuffer, frame_slot: u64) {

    draw_data := ImGui.GetDrawData();
    if !draw_data || draw_data.CmdListsCount == 0  return;

    io := ImGui.GetIO();
    fb_width  := cast(s32) swapchain_extent.width;
    fb_height := cast(s32) swapchain_extent.height;
    if fb_width <= 0 || fb_height <= 0  return;

    assert(draw_data.TotalVtxCount <= IMGUI_VERTEX_BUDGET, "ImGui vertex budget exceeded: % > %", draw_data.TotalVtxCount, IMGUI_VERTEX_BUDGET);
    assert(draw_data.TotalIdxCount <= IMGUI_INDEX_BUDGET,  "ImGui index budget exceeded: % > %",  draw_data.TotalIdxCount, IMGUI_INDEX_BUDGET);

    vertex_slot_offset := imgui_vertex_offset + frame_slot * IMGUI_VERTEX_SLOT_STRIDE;
    index_slot_offset  := imgui_index_offset  + frame_slot * IMGUI_INDEX_SLOT_STRIDE;

    {
        vertex_bytes_used, index_bytes_used : VkDeviceSize;
        for n : 0..draw_data.CmdListsCount-1 {
            cmd_list := draw_data.CmdLists[n];
            vertex_bytes := cast(VkDeviceSize) cmd_list.VtxBuffer.Size * size_of(ImGui.ImDrawVert);
            index_bytes  := cast(VkDeviceSize) cmd_list.IdxBuffer.Size * size_of(ImGui.ImDrawIdx);

            memcpy(heap_pointer(*buffer_heap, vertex_slot_offset + vertex_bytes_used), cmd_list.VtxBuffer.Data, xx vertex_bytes);
            memcpy(heap_pointer(*buffer_heap, index_slot_offset  + index_bytes_used),  cmd_list.IdxBuffer.Data,  xx index_bytes);

            vertex_bytes_used += vertex_bytes;
            index_bytes_used  += index_bytes;
        }
    }

    {
        vkCmdSetCullMode(command_buffer, .NONE);

        vkCmdSetDepthTestEnable(command_buffer,  VK_FALSE);
        vkCmdSetDepthWriteEnable(command_buffer, VK_FALSE);

        color_blend_enable : VkBool32 = VK_TRUE;
        vkCmdSetColorBlendEnableEXT(command_buffer, 0, 1, *color_blend_enable);

        blend_equation := VkColorBlendEquationEXT.{
            srcColorBlendFactor = .SRC_ALPHA,
            dstColorBlendFactor = .ONE_MINUS_SRC_ALPHA,
            colorBlendOp        = .ADD,
            srcAlphaBlendFactor = .ONE,
            dstAlphaBlendFactor = .ONE_MINUS_SRC_ALPHA,
            alphaBlendOp        = .ADD,
        };
        vkCmdSetColorBlendEquationEXT(command_buffer, 0, 1, *blend_equation);
    }

    bind_graphics_shaders(command_buffer, imgui_shaders);

    {
        index_buffer_info := VkBindIndexBuffer3InfoKHR.{
            addressRange = .{
                address = heap_address(*buffer_heap, index_slot_offset),
                size    = cast(VkDeviceSize) draw_data.TotalIdxCount * size_of(ImGui.ImDrawIdx),
            },
            addressFlags = .STORAGE_BUFFER_USAGE,
            indexType    = .UINT16,
        };
        vkCmdBindIndexBuffer3KHR(command_buffer, *index_buffer_info);
    }

    push_data := Imgui_Push_Data.{
        scale     = .{2.0 / io.DisplaySize.x, 2.0 / io.DisplaySize.y},
        translate = .{-1, -1},
        sampler   = imgui_sampler,
    };

    vertex_bytes_base : VkDeviceSize = 0;
    index_base : u32 = 0;
    for n : 0..draw_data.CmdListsCount-1 {
        cmd_list := draw_data.CmdLists[n];

        push_data.vertices = heap_gpu_pointer(*buffer_heap, ImGui.ImDrawVert, vertex_slot_offset + vertex_bytes_base);

        for cmd_i : 0..cmd_list.CmdBuffer.Size-1 {
            pcmd := *cmd_list.CmdBuffer.Data[cmd_i];
            if pcmd.UserCallback {
                pcmd.UserCallback(cmd_list, pcmd);
            }
            else {
                x1 := clamp(cast(s32) pcmd.ClipRect.x, 0, fb_width);
                y1 := clamp(cast(s32) pcmd.ClipRect.y, 0, fb_height);
                x2 := clamp(cast(s32) pcmd.ClipRect.z, 0, fb_width);
                y2 := clamp(cast(s32) pcmd.ClipRect.w, 0, fb_height);
                if x2 > x1 && y2 > y1 {
                    scissor := VkRect2D.{offset = .{x1, y1}, extent = .{xx (x2 - x1), xx (y2 - y1)}};
                    vkCmdSetScissorWithCount(command_buffer, 1, *scissor);

                    push_data.texture = .{id = cast(u32) cast(u64) pcmd.TextureId};

                    push_data_info := VkPushDataInfoEXT.{data = .{address = *push_data, size = size_of(Imgui_Push_Data)}};
                    vkCmdPushDataEXT(command_buffer, *push_data_info);

                    vkCmdDrawIndexed(command_buffer,
                        indexCount    = pcmd.ElemCount,
                        instanceCount = 1,
                        firstIndex    = index_base,
                        vertexOffset  = 0,
                        firstInstance = 0
                    );
                }
            }
            index_base += pcmd.ElemCount;
        }

        vertex_bytes_base += cast(VkDeviceSize) cmd_list.VtxBuffer.Size * size_of(ImGui.ImDrawVert);
    }
}
