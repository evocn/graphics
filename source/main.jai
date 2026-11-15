DEVELOPER_TOOLS :: #run BUILD_TYPE == .DEBUG;

main_context : struct {
    window        : Window_Type;
    window_width  : u32 = 1920;
    window_height : u32 = 1080;
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
    renderer_context.debug_view = xx args.view;

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

    init_frames();
    defer deinit_frames();

    init_upload();
    defer deinit_upload();

    init_renderer();
    defer deinit_renderer();

    begin_upload();

    init_scene();
    defer deinit_scene();
    init_demo_scene();
    build_scene();

    init_imgui();
    defer deinit_imgui();

    end_upload();

    last_time := seconds_since_init();
    while true {
        update_input();
        if input_context.quit break;

        if swapchain_context.needs_recreation {
            if !recreate_swapchain() {
                sleep_milliseconds(16);
                continue;
            }
            resize_render_targets();
        }

        now := seconds_since_init();
        dt := cast(float) (now - last_time);
        last_time = now;
        Clamp(*dt, 0, 0.1);

        update_camera(dt);

        sun_angle := cast(float) now * 0.4;
        renderer_context.light_direction = unit_vector(Vector3.{cos(sun_angle) * 0.3, 1.0, sin(sun_angle) * 0.3});

        imgui_new_frame();
        renderer_debug_ui();
        ImGui.Render();

        if args.screenshot && frame_context.index + 1 == cast(u64) args.frames then screenshot_context.requested = true;

        draw_frame();

        if args.frames > 0 && frame_context.index >= cast(u64) args.frames then break;
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
#load "input.jai";
#load "camera.jai";
#load "scene.jai";
#load "demo_scene.jai";
#load "renderer.jai";

#load "vulkan/vulkan.jai";

#load "assets/assets.jai";

#load "tools/imgui.jai";
#load "tools/screenshot.jai";
