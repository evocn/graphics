// Graphics
// ImGui
//
// Vulkan render backend plus platform glue for the ImGui module. The render half is
// modeled on jai/modules/ImGui_GL.jai / ImGui_Metal.jai, but written against this
// renderer's idioms: shader objects, dynamic state, the shared arena, and the
// descriptor heap. The input half is adapted from jai/modules/ImGui_Platform.jai;
// cursor visibility is left to set_mouse_look rather than handed to ImGui.
//
// Per-frame vertex/index data streams through FRAMES_IN_FLIGHT regions of the arena;
// reuse is safe because draw_frame waits on the timeline semaphore before recording
// over a slot. Draw order: call render_imgui inside the frame's rendering scope,
// after the scene, so the UI composites on top.

imgui_state : struct {
    imgui_context : *ImGui.ImGuiContext;

    shaders : [2] VkShaderEXT;

    font_image  : VkImage;
    font_memory : VkDeviceMemory;

    font_image_id : u32;
    sampler_id    : u32;

    VERTEX_BUDGET :: 65536;
    INDEX_BUDGET  :: 262144;
    vertex_slot_stride :: VERTEX_BUDGET * size_of(ImGui.ImDrawVert);
    index_slot_stride  :: INDEX_BUDGET  * size_of(ImGui.ImDrawIdx);
    vertex_offset : VkDeviceSize;
    index_offset  : VkDeviceSize;

    time              : float64;
    mouse_pressed     : [3] bool;
    mouse_wheel       : float;
    clipboard_cstring : *u8;
}

// Must match Push_Data in imgui.slang (scalar layout).
Imgui_Push_Data :: struct {
    vertices  : VkDeviceAddress;
    scale     : Vector2;
    translate : Vector2;
    texture   : [2] u32;
    sampler   : [2] u32;
}

// Records the font upload into command_buffers[0], so call it inside main's GPU
// initialization recording, before that command buffer is submitted.
init_imgui :: () {
    result : VkResult;
    using imgui_state;

    imgui_context = ImGui.CreateContext();

    io := ImGui.GetIO();
    io.IniFilename = null;

    // Key mapping, indices into io.KeysDown[], which imgui_process_event fills
    // indexed by Key_Code.
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

        #if OS == .WINDOWS { io.ImeWindowHandle = program_state.window; }
    }

    // Arena regions for streamed vertex/index data.
    {
        vertex_offset = arena_suballocate(FRAMES_IN_FLIGHT * vertex_slot_stride, 256);
        index_offset  = arena_suballocate(FRAMES_IN_FLIGHT * index_slot_stride,  256);
    }

    // Shaders
    {
        spirv : [2] string;
        {
            read_shader_file :: (name: string) -> spirv: string
            {
                shader_file_path := tprint("%/%", compiled_shaders_directory, tprint("%.spv", name));

                spirv, success := read_entire_file(shader_file_path);
                assert(success, "Unable to read shader file %", shader_file_path);

                return spirv;
            }
            spirv[0] = read_shader_file("imgui-vertex");
            spirv[1] = read_shader_file("imgui-fragment");
        }

        shader_create_infos : [2] VkShaderCreateInfoEXT;

        {
            using shader_create_infos[0];
            flags = .LINK_STAGE | .DESCRIPTOR_HEAP;

            stage       = .VERTEX;
            nextStage   = .FRAGMENT;

            codeType    = .SPIRV;
            codeSize    = xx spirv[0].count;
            pCode       = spirv[0].data;

            pName       = "main";
        }

        {
            using shader_create_infos[1];
            flags = .LINK_STAGE | .DESCRIPTOR_HEAP;

            stage       = .FRAGMENT;
            nextStage   = 0;

            codeType    = .SPIRV;
            codeSize    = xx spirv[1].count;
            pCode       = spirv[1].data;

            pName       = "main";
        }

        result = vkCreateShadersEXT(device,
            shader_create_infos.count, shader_create_infos.data,
            null,
            shaders.data
        );
        assert(result == .SUCCESS);

        set_debug_name(.SHADER_EXT, shaders[0], "imgui vertex");
        set_debug_name(.SHADER_EXT, shaders[1], "imgui fragment");
    }

    // Font, baked at a size proportional to the initial window height. Rebaking on
    // live resizes is not supported; the size chosen here sticks for the run.
    {
        font_size := cast(float) program_state.window_height / 50.0;
        font := io.Fonts.AddFontFromFileTTF(io.Fonts, "assets/fonts/Merriweather/Merriweather-VariableFont_opsz,wdth,wght.ttf", font_size);
        assert(font != null, "Unable to load the ImGui font.");
    }

    // Font atlas texture
    {
        pixels : *u8;
        width, height, bpp : s32;
        io.Fonts.GetTexDataAsRGBA32(io.Fonts, *pixels, *width, *height, *bpp);

        // Stage the pixels in the arena for the copy below. The region is not
        // reclaimed afterwards; the arena has no free, and the atlas is small.
        staging_size   := cast(VkDeviceSize) (4 * width * height);
        staging_offset := arena_suballocate(staging_size, 256);
        memcpy(arena_pointer(staging_offset), pixels, xx staging_size);

        {
            using image_create_info : VkImageCreateInfo;
            imageType     = .e2D;
            format        = .R8G8B8A8_UNORM;
            extent        = .{width = xx width, height = xx height, depth = 1};
            mipLevels     = 1;
            arrayLayers   = 1;
            samples       = .e1;
            tiling        = .OPTIMAL;
            usage         = .SAMPLED | .TRANSFER_DST;
            sharingMode   = .EXCLUSIVE;
            initialLayout = .UNDEFINED;

            result = vkCreateImage(device, *image_create_info, null, *font_image);
            assert(result == .SUCCESS);
        }

        {
            memory_requirements : VkMemoryRequirements;
            vkGetImageMemoryRequirements(device, font_image, *memory_requirements);

            success, memory_type_index := select_memory_type(physical_device_context.memory_properties, memory_requirements.memoryTypeBits, .DEVICE_LOCAL);
            assert(success);

            {
                using allocate_info : VkMemoryAllocateInfo;
                allocationSize  = memory_requirements.size;
                memoryTypeIndex = xx memory_type_index;

                result = vkAllocateMemory(device, *allocate_info, null, *font_memory);
                assert(result == .SUCCESS);
            }
            result = vkBindImageMemory(device, font_image, font_memory, 0);
            assert(result == .SUCCESS);

            set_debug_name(.IMAGE,         font_image,  "imgui font texture");
            set_debug_name(.DEVICE_MEMORY, font_memory, "imgui font texture memory");
        }

        {
            image_memory_barrier : VkImageMemoryBarrier2;
            {
                using image_memory_barrier;
                srcStageMask        = .NONE;
                srcAccessMask       = .NONE;
                dstStageMask        = .COPY;
                dstAccessMask       = .TRANSFER_WRITE;
                oldLayout           = .UNDEFINED;
                newLayout           = .GENERAL;
                srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
                dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
                image               = font_image;
                subresourceRange    = .{
                    aspectMask = .COLOR,
                    levelCount = VK_REMAINING_MIP_LEVELS,
                    layerCount = VK_REMAINING_ARRAY_LAYERS,
                };
            }

            dependency_info : VkDependencyInfo;
            {
                using dependency_info;
                imageMemoryBarrierCount = 1;
                pImageMemoryBarriers    = *image_memory_barrier;
            }

            vkCmdPipelineBarrier2(command_buffers[0], *dependency_info);
        }

        {
            region : VkDeviceMemoryImageCopyKHR;
            {
                using region;
                addressRange = .{
                    address = arena_address(staging_offset),
                    size    = staging_size,
                };
                addressFlags = .STORAGE_BUFFER_USAGE;
                imageSubresource = .{
                    aspectMask = .COLOR,
                    layerCount = VK_REMAINING_ARRAY_LAYERS,
                };
                imageLayout = .GENERAL;
                imageExtent = .{xx width, xx height, 1};
            }

            using copy_info : VkCopyDeviceMemoryImageInfoKHR;
            image = font_image;
            regionCount = 1;
            pRegions = *region;

            vkCmdCopyMemoryToImageKHR(command_buffers[0], *copy_info);
        }

        // Descriptor, one slot past the scene texture.
        font_image_id = first_image_id + 1;
        {
            view_create_info : VkImageViewCreateInfo;
            {
                using view_create_info;
                image    = font_image;
                viewType = .e2D;
                format   = .R8G8B8A8_UNORM;
                subresourceRange = .{
                    aspectMask = .COLOR,
                    levelCount = VK_REMAINING_MIP_LEVELS,
                    layerCount = VK_REMAINING_ARRAY_LAYERS,
                };
            }

            image_descriptor_info : VkImageDescriptorInfoEXT;
            {
                using image_descriptor_info;
                pView  = *view_create_info;
                layout = .GENERAL;
            }

            resource_descriptor_info : VkResourceDescriptorInfoEXT;
            {
                using resource_descriptor_info;
                type = .SAMPLED_IMAGE;
                data.pImage = *image_descriptor_info;
            }

            destination := VkHostAddressRangeEXT.{
                address = arena_pointer(resource_heap_offset + font_image_id * image_descriptor_stride),
                size    = image_descriptor_stride,
            };

            result = vkWriteResourceDescriptorsEXT(device, 1, *resource_descriptor_info, *destination);
            assert(result == .SUCCESS);
        }

        io.Fonts.TexID = cast(*void) font_image_id;
    }

    // Linear-clamp sampler for the UI, one slot past the scene sampler.
    sampler_id = first_sampler_id + 1;
    {
        sampler_create_info : VkSamplerCreateInfo;
        {
            using sampler_create_info;
            magFilter    = .LINEAR;
            minFilter    = .LINEAR;
            mipmapMode   = .NEAREST;
            addressModeU = .CLAMP_TO_EDGE;
            addressModeV = .CLAMP_TO_EDGE;
            addressModeW = .CLAMP_TO_EDGE;
            maxLod       = VK_LOD_CLAMP_NONE;
            borderColor  = .INT_OPAQUE_BLACK;
        }

        destination := VkHostAddressRangeEXT.{
            address = arena_pointer(sampler_heap_offset + sampler_id * sampler_descriptor_stride),
            size    = sampler_descriptor_stride,
        };

        result = vkWriteSamplerDescriptorsEXT(device, 1, *sampler_create_info, *destination);
        assert(result == .SUCCESS);
    }
}

deinit_imgui :: () {
    using imgui_state;

    for shader : shaders {
        vkDestroyShaderEXT(device, shader, null);
    }
    vkDestroyImage(device, font_image, null);
    vkFreeMemory(device, font_memory, null);

    free(clipboard_cstring);
    ImGui.DestroyContext(imgui_context);
}

// ImGui wants a zero-terminated C string that stays valid after we return, so keep the
// latest copy around until the next request.
imgui_get_clipboard_text :: (data: *void) -> *u8 #c_call {
    result : *u8;
    push_context {
        free(imgui_state.clipboard_cstring);

        text := Clipboard.os_clipboard_get_text();
        defer free(text);

        imgui_state.clipboard_cstring = alloc(text.count + 1);
        memcpy(imgui_state.clipboard_cstring, text.data, text.count);
        imgui_state.clipboard_cstring[text.count] = 0;

        result = imgui_state.clipboard_cstring;
    }
    return result;
}

imgui_set_clipboard_text :: (data: *void, text: *u8) #c_call {
    push_context {
        Clipboard.os_clipboard_set_text(to_string(text));
    }
}

// Pass every event through; read io.WantCaptureMouse / io.WantCaptureKeyboard to
// decide whether the game should also act on it.
imgui_process_event :: (event: Event) -> bool {
    io := ImGui.GetIO();
    if event.type == {
        case .MOUSE_WHEEL;
            if event.wheel_delta > 0 imgui_state.mouse_wheel = 1;
            if event.wheel_delta < 0 imgui_state.mouse_wheel = -1;
            return true;

        case .TEXT_INPUT;
            io.AddInputCharacter(io, event.utf32);
            return true;

        case .KEYBOARD;
            key := event.key_code;

            if key == .MOUSE_BUTTON_LEFT   { if event.key_pressed imgui_state.mouse_pressed[0] = true;  return true; }
            if key == .MOUSE_BUTTON_RIGHT  { if event.key_pressed imgui_state.mouse_pressed[1] = true;  return true; }
            if key == .MOUSE_BUTTON_MIDDLE { if event.key_pressed imgui_state.mouse_pressed[2] = true;  return true; }

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

    io.DisplaySize             = .{xx program_state.window_width, xx program_state.window_height};
    io.DisplayFramebufferScale = .{1, 1};

    now := seconds_since_init();
    if imgui_state.time > 0  io.DeltaTime = cast(float)(now - imgui_state.time);
    else                     io.DeltaTime = 1.0/60.0;
    if io.DeltaTime <= 0     io.DeltaTime = 0.000001; // ImGui asserts on non-positive DeltaTime.
    imgui_state.time = now;

    // While mouse look is on, the cursor belongs to the camera.
    mouse_x, mouse_y := get_mouse_pointer_position(program_state.window, false);
    if !camera.mouse_look_active && is_mouse_over_window(program_state.window) {
        io.MousePos = .{xx mouse_x, xx mouse_y};
    } else {
        io.MousePos = .{-FLOAT32_MAX, -FLOAT32_MAX};
    }

    // A press event always counts as "held this frame", so sub-frame clicks are not lost.
    is_down :: (key: Key_Code) -> bool {
        return cast(bool)(input_button_states[key] & .DOWN);
    }
    io.MouseDown[0] = imgui_state.mouse_pressed[0] || is_down(.MOUSE_BUTTON_LEFT);
    io.MouseDown[1] = imgui_state.mouse_pressed[1] || is_down(.MOUSE_BUTTON_RIGHT);
    io.MouseDown[2] = imgui_state.mouse_pressed[2] || is_down(.MOUSE_BUTTON_MIDDLE);
    imgui_state.mouse_pressed = .[false, false, false];

    io.MouseWheel = imgui_state.mouse_wheel;
    imgui_state.mouse_wheel = 0;

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
    }
    ImGui.End();
}

// Encodes ImGui's draw data into the frame's rendering scope. Assumes set_draw_state
// ran earlier in the scope; only the state it needs differently is touched, so call
// this last, after the scene's draws.
render_imgui :: (command_buffer: VkCommandBuffer, frame_slot: u64) {
    using imgui_state;

    draw_data := ImGui.GetDrawData();
    if !draw_data || draw_data.CmdListsCount == 0  return;

    io := ImGui.GetIO();
    fb_width  := cast(s32) swapchain_context.extent.width;
    fb_height := cast(s32) swapchain_context.extent.height;
    if fb_width <= 0 || fb_height <= 0  return;

    assert(draw_data.TotalVtxCount <= VERTEX_BUDGET, "ImGui vertex budget exceeded: % > %", draw_data.TotalVtxCount, VERTEX_BUDGET);
    assert(draw_data.TotalIdxCount <= INDEX_BUDGET,  "ImGui index budget exceeded: % > %",  draw_data.TotalIdxCount, INDEX_BUDGET);

    vertex_slot_offset := vertex_offset + frame_slot * vertex_slot_stride;
    index_slot_offset  := index_offset  + frame_slot * index_slot_stride;

    // Pack every command list's vertices and indices contiguously into this frame's slot.
    {
        vertex_bytes_used, index_bytes_used : VkDeviceSize;
        for n : 0..draw_data.CmdListsCount-1 {
            cmd_list := draw_data.CmdLists[n];
            vertex_bytes := cast(VkDeviceSize) cmd_list.VtxBuffer.Size * size_of(ImGui.ImDrawVert);
            index_bytes  := cast(VkDeviceSize) cmd_list.IdxBuffer.Size * size_of(ImGui.ImDrawIdx);

            memcpy(arena_pointer(vertex_slot_offset + vertex_bytes_used), cmd_list.VtxBuffer.Data, xx vertex_bytes);
            memcpy(arena_pointer(index_slot_offset  + index_bytes_used),  cmd_list.IdxBuffer.Data,  xx index_bytes);

            vertex_bytes_used += vertex_bytes;
            index_bytes_used  += index_bytes;
        }
    }

    // State deltas from set_draw_state: no culling, no depth, alpha blending on.
    {
        vkCmdSetCullMode(command_buffer, .NONE);

        vkCmdSetDepthTestEnable(command_buffer,  VK_FALSE);
        vkCmdSetDepthWriteEnable(command_buffer, VK_FALSE);

        color_blend_enables : [1] VkBool32;
        color_blend_enables[0] = VK_TRUE;
        vkCmdSetColorBlendEnableEXT(command_buffer, 0, color_blend_enables.count, color_blend_enables.data);

        blend_equation : VkColorBlendEquationEXT;
        {
            using blend_equation;
            srcColorBlendFactor = .SRC_ALPHA;
            dstColorBlendFactor = .ONE_MINUS_SRC_ALPHA;
            colorBlendOp        = .ADD;
            srcAlphaBlendFactor = .ONE;
            dstAlphaBlendFactor = .ONE_MINUS_SRC_ALPHA;
            alphaBlendOp        = .ADD;
        }
        vkCmdSetColorBlendEquationEXT(command_buffer, 0, 1, *blend_equation);
    }

    {
        stages := VkShaderStageFlagBits.[
            .VERTEX,
            .FRAGMENT,
        ];

        vkCmdBindShadersEXT(command_buffer, stages.count, stages.data, shaders.data);
    }

    vkCmdBindIndexBuffer(command_buffer, arena.buffer, index_slot_offset, .UINT16);

    push_data := Imgui_Push_Data.{
        scale     = .{2.0 / io.DisplaySize.x, 2.0 / io.DisplaySize.y},
        translate = .{-1, -1},
        sampler   = .[sampler_id, 0],
    };

    // Slang lowers SV_VertexID to gl_VertexIndex - gl_BaseVertex (D3D semantics), so
    // vkCmdDrawIndexed's vertexOffset would cancel out of the pulled index. Instead each
    // command list gets its own base pointer, and every draw uses vertexOffset = 0.
    vertex_bytes_base : VkDeviceSize = 0;
    index_base : u32 = 0;
    for n : 0..draw_data.CmdListsCount-1 {
        cmd_list := draw_data.CmdLists[n];

        push_data.vertices = arena_address(vertex_slot_offset + vertex_bytes_base);

        for cmd_i : 0..cmd_list.CmdBuffer.Size-1 {
            pcmd := *cmd_list.CmdBuffer.Data[cmd_i];
            if pcmd.UserCallback {
                pcmd.UserCallback(cmd_list, pcmd);
            }
            else {
                // Clamp; validation rejects scissors that poke outside the target.
                x1 := clamp(cast(s32) pcmd.ClipRect.x, 0, fb_width);
                y1 := clamp(cast(s32) pcmd.ClipRect.y, 0, fb_height);
                x2 := clamp(cast(s32) pcmd.ClipRect.z, 0, fb_width);
                y2 := clamp(cast(s32) pcmd.ClipRect.w, 0, fb_height);
                if x2 > x1 && y2 > y1 {
                    scissors : [1] VkRect2D;
                    scissors[0] = .{
                        offset = .{x1, y1},
                        extent = .{xx (x2 - x1), xx (y2 - y1)},
                    };
                    vkCmdSetScissorWithCount(command_buffer, scissors.count, scissors.data);

                    push_data.texture = .[cast(u32) cast(u64) pcmd.TextureId, 0];

                    push_data_info : VkPushDataInfoEXT;
                    {
                        using push_data_info;
                        offset = 0;
                        data = .{
                            address = *push_data,
                            size    = size_of(Imgui_Push_Data),
                        };
                    }
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
