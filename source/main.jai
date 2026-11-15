DEVELOPER_TOOLS :: #run BUILD_TYPE == .DEBUG;

main_context : struct {
    window        : Window_Type;
    window_width  : u32 = 1920;
    window_height : u32 = 1080;

    light_direction : Vector3;
    sun_intensity   : float = 3.0;
    exposure        : float = 1.0;
    debug_view      : Debug_View;
}

main :: () {
    set_working_directory_to_base_folder :: () {
        executable_path := path_strip_filename(get_path_of_running_executable());
        set_working_directory(tprint("%/../", executable_path));
    }
    set_working_directory_to_base_folder();

    Command_Line_Arguments :: struct {
        automation : bool;  @"?Open the window at the bottom of the z-order without taking focus."
        frames     : int;   @"?Quit after this many frames. 0 runs until closed."
        screenshot : bool;  @"?Save the last frame to bin/screenshots/ and quit. Runs 1 frame unless -frames is given."
        view       : int;   @"?Start in a debug view: 0 lit, 1 base color, 2 normals, 3 metallic/roughness, 4 sun only, 5 ambient only."
    }
    success, args := parse_arguments(Command_Line_Arguments);
    if !success return;

    if args.screenshot && args.frames == 0 then args.frames = 1;
    main_context.debug_view = xx args.view;

    main_context.window = create_window(
        xx main_context.window_width, xx main_context.window_height,
        program_title,
        window_x = 0,
        window_y = 0,
        activate = !args.automation,
    );

    #if OS == .WINDOWS {
        vulkan_library := LoadLibraryA("vulkan-1.dll");
        assert(vulkan_library != null, "Unable to find vulkan-1.dll.");
    }

    vkGIPA := GetProcAddress(vulkan_library, "vkGetInstanceProcAddr");
    vk_load_global_functions(vkGIPA);

    init_instance();
    defer deinit_instance();

    init_surface();
    defer deinit_surface();

    init_device();
    defer deinit_device();

    init_heaps();
    defer deinit_heaps();

    init_descriptor_heaps();

    init_swapchain();
    defer deinit_swapchain();

    init_render();
    defer deinit_render();

    begin_info := VkCommandBufferBeginInfo.{flags = .ONE_TIME_SUBMIT};
    result := vkBeginCommandBuffer(frame_context.init_command_buffer, *begin_info);
    assert(result == .SUCCESS);

    init_data();
    defer deinit_data();

    init_imgui();
    defer deinit_imgui();

    result = vkEndCommandBuffer(frame_context.init_command_buffer);
    assert(result == .SUCCESS);
    submit_info := VkSubmitInfo.{commandBufferCount = 1, pCommandBuffers = *frame_context.init_command_buffer};
    result = vkQueueSubmit(device_context.queue, 1, *submit_info, VK_NULL_HANDLE);
    assert(result == .SUCCESS);
    vkDeviceWaitIdle(device_context.device);
    heap_reset(*heap_context.scratch);

    running := true;
    last_time := seconds_since_init();
    while running {
        update_window_events();

        for events_this_frame {
            imgui_process_event(it);

            if it.type == {
                case .KEYBOARD;
                    if it.alt_pressed {
                        if it.key_pressed && it.key_code == .F4 {
                            running = false;
                        }
                    }

                    if it.key_pressed && it.key_code == .MOUSE_BUTTON_LEFT
                       && !ImGui.GetIO().WantCaptureMouse {
                        set_mouse_look(true);
                    }

                    if it.key_pressed && it.key_code == .ESCAPE {
                        if camera_context.mouse_look_active  set_mouse_look(false);
                        else                running = false;
                    }
            }

            if it.type == .QUIT then running = false;
        }

        for get_window_resizes() {
            if it.window != main_context.window continue;

            main_context.window_width  = xx it.width;
            main_context.window_height = xx it.height;
            swapchain_context.needs_recreation = true;
        }

        if !running break;

        if swapchain_context.needs_recreation {
            if !recreate_swapchain() {
                sleep_milliseconds(16);
                continue;
            }
        }

        now := seconds_since_init();
        dt := cast(float) (now - last_time);
        last_time = now;
        Clamp(*dt, 0, 0.1);

        update_camera(dt);

        sun_angle := cast(float) now * 0.4;
        main_context.light_direction = unit_vector(Vector3.{cos(sun_angle) * 0.3, 1.0, sin(sun_angle) * 0.3});

        imgui_new_frame();
        imgui_debug_ui();
        ImGui.Render();

        if args.screenshot && frame_context.index + 1 == cast(u64) args.frames then screenshot_context.requested = true;

        draw_frame();

        if args.frames > 0 && frame_context.index >= cast(u64) args.frames then running = false;
    }

    vkDeviceWaitIdle(device_context.device);

    if screenshot_context.captured then save_screenshot();
}

#import "Basic";
#import "String";
#import "Math";

#import "File";
#import "File_Utilities";
#import "Command_Line";

#import "Window_Creation";
#import "Input";

#import "Vulkan";
#import "stb_image";
#import "cgltf";
#import "stb_image_write";

ImGui     :: #import "ImGui";
Clipboard :: #import "Clipboard";

#import "System";
#if OS == .WINDOWS {
    #import "Windows";
}

#load "utils.jai";
#load "vulkan/vulkan.jai";
#load "camera.jai";
#load "scene.jai";
#load "gltf.jai";
#load "frame.jai";
#load "imgui.jai";
#load "tools/screenshot.jai";

textures_path   :: "assets/textures";
models_path     :: "assets/models";
