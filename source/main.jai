DEVELOPER_TOOLS :: #run BUILD_TYPE == .DEBUG;

window        : Window_Type;
window_width  : u32 = 1920;
window_height : u32 = 1080;

light_direction : Vector3;
sun_intensity   : float = 3.0;
exposure        : float = 1.0;
debug_view      : Debug_View;

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
        shimmer    : int;   @"?Fly a fixed camera path, measure frame-to-frame shimmer over this many frames, save a heatmap to bin/shimmer/ and quit."
        benchmark  : int;   @"?Fly the shimmer camera path for this many frames without measuring shimmer, print the average GPU frame time and quit."
        view       : int;   @"?Start in a debug view: 0 lit, 1 ambient occlusion, 2 base color, 3 normals, 4 metallic/roughness, 5 sun only, 6 ambient only."
    }
    success, args := parse_arguments(Command_Line_Arguments);
    if !success return;

    if args.screenshot && args.frames == 0 then args.frames = 1;
    if args.shimmer > 0 then args.frames = SHIMMER_WARMUP_FRAMES + args.shimmer;
    if args.benchmark > 0 then args.frames = SHIMMER_WARMUP_FRAMES + args.benchmark;
    flying := args.shimmer > 0 || args.benchmark > 0;
    debug_view = xx args.view;

    benchmark_total : float64;
    benchmark_count : int;

    window = create_window(
        xx window_width, xx window_height,
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
    result := vkBeginCommandBuffer(init_command_buffer, *begin_info);
    assert(result == .SUCCESS);

    init_data();
    defer deinit_data();

    init_imgui();
    defer deinit_imgui();

    result = vkEndCommandBuffer(init_command_buffer);
    assert(result == .SUCCESS);
    submit_info := VkSubmitInfo.{commandBufferCount = 1, pCommandBuffers = *init_command_buffer};
    result = vkQueueSubmit(queue, 1, *submit_info, VK_NULL_HANDLE);
    assert(result == .SUCCESS);
    vkDeviceWaitIdle(device);
    heap_reset(*scratch_heap);

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
                        if mouse_look_active  set_mouse_look(false);
                        else                running = false;
                    }
            }

            if it.type == .QUIT then running = false;
        }

        for get_window_resizes() {
            if it.window != window continue;

            window_width  = xx it.width;
            window_height = xx it.height;
            swapchain_needs_recreation = true;
        }

        if !running break;

        if swapchain_needs_recreation {
            if !recreate_swapchain() {
                sleep_milliseconds(16);
                continue;
            }
        }

        now := seconds_since_init();
        dt := cast(float) (now - last_time);
        last_time = now;
        Clamp(*dt, 0, 0.1);
        if flying {
            now = cast(float64) frame_index * SHIMMER_TIME_STEP;
            dt  = SHIMMER_TIME_STEP;
        }

        update_camera(dt);
        if flying  shimmer_camera_path(cast(float) now);

        sun_angle := cast(float) now * 0.4;
        light_direction = unit_vector(Vector3.{cos(sun_angle) * 0.3, 1.0, sin(sun_angle) * 0.3});

        imgui_new_frame();
        if !flying  imgui_debug_ui();
        ImGui.Render();

        if args.screenshot && frame_index + 1 == cast(u64) args.frames then screenshot_requested = true;
        if args.shimmer > 0 && frame_index >= SHIMMER_WARMUP_FRAMES then screenshot_requested = true;

        draw_frame();

        if args.shimmer > 0 && screenshot_captured {
            vkDeviceWaitIdle(device);
            shimmer_accumulate();
            screenshot_captured = false;
        }

        if args.benchmark > 0 && frame_index > SHIMMER_WARMUP_FRAMES + FRAMES_IN_FLIGHT {
            benchmark_total += gpu_frame_ms;
            benchmark_count += 1;
        }

        if args.frames > 0 && frame_index >= cast(u64) args.frames then running = false;
    }

    vkDeviceWaitIdle(device);

    if screenshot_captured then save_screenshot();
    if args.shimmer > 0 then shimmer_finish();
    if benchmark_count > 0 then print("BENCHMARK % ms average GPU frame time over % frames\n", formatFloat(benchmark_total / benchmark_count, trailing_width = 3), benchmark_count);
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
#load "camera.jai";
#load "rhi/device.jai";
#load "rhi/heap.jai";
#load "rhi/descriptors.jai";
#load "rhi/gpu.jai";
#load "rhi/swapchain.jai";
#load "rhi/barrier.jai";
#load "rhi/shader.jai";
#load "rhi/texture.jai";
#load "rhi/acceleration_structure.jai";
#load "scene.jai";
#load "gltf.jai";
#load "frame.jai";
#load "imgui.jai";
#load "shimmer.jai";

textures_path   :: "assets/textures";
models_path     :: "assets/models";
