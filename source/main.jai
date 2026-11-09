// Graphics
// Main

DEVELOPER_TOOLS :: #run BUILD_TYPE == .DEBUG;

program_state : struct {
    using window_context : struct {
        window_width    : u32 = 1920;
        window_height   : u32 = 1080;

        window          : Window_Type;
    }

    Texture_Data :: struct {
        bytes : *void;
        width : s32;
        height: s32;
    }
    texture_datas : [..] Texture_Data;
}

world_state : struct {
    light_direction : Vector3;
    sun_intensity   : float = 3.0;
    exposure        : float = 1.0;
    debug_view      : Debug_View;
}

using render_context : struct {
    FRAMES_IN_FLIGHT :: 2;
    frame_index : u64 = 0;
    timeline_semaphore  : VkSemaphore;
    command_pool        : VkCommandPool;
    command_buffers             : [FRAMES_IN_FLIGHT] VkCommandBuffer;
    image_available_semaphores  : [FRAMES_IN_FLIGHT] VkSemaphore;
    present_ready_semaphores    : [swapchain_context.MAX_SWAPCHAIN_IMAGES] VkSemaphore;
    present_fences              : [swapchain_context.MAX_SWAPCHAIN_IMAGES] VkFence;

    frame_constants_offset      : VkDeviceSize;

    ambient_write_index      : u32;
    previous_view_projection : Matrix4;
    previous_camera_position : Vector3;

    timestamp_pool : VkQueryPool;
    gpu_frame_ms   : float;

    shaders                 : [2] VkShaderEXT;
    tonemap_shaders         : [2] VkShaderEXT;
    depth_shaders           : [2] VkShaderEXT;

    screenshot : struct {
        requested   : bool;
        captured    : bool;
        offset         : VkDeviceSize;
        allocated_size : VkDeviceSize;
        extent      : VkExtent2D;
        format      : VkFormat;
    }
}

using scene_data : struct {
    textures         : [..] Texture;
    materials        : [..] Material;
    materials_offset : VkDeviceSize;

    white_texture       : Texture_Handle;
    flat_normal_texture : Texture_Handle;

    meshes           : [..] Mesh;
    instances        : [..] Instance;
    draw_data_offset : VkDeviceSize;

    scene_blas         : VkAccelerationStructureKHR;
    scene_blas_address : VkDeviceAddress;

    tlas         : VkAccelerationStructureKHR;
    tlas_address : VkDeviceAddress;
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
    world_state.debug_view = xx args.view;

    benchmark_total : float64;
    benchmark_count : int;

    program_state.window = create_window(
        xx program_state.window_width, xx program_state.window_height,
        program_title,
        window_x = 0,
        window_y = 0,
        activate = !args.automation,
    );

    {
        #if OS == .WINDOWS {
            vulkan_library := LoadLibraryA("vulkan-1.dll");
            assert(vulkan_library != null, "Unable to find vulkan-1.dll.");
        }

        vkGIPA := GetProcAddress(vulkan_library, "vkGetInstanceProcAddr");
        vk_load_global_functions(vkGIPA);
    }

    // Load Texture Data
    {
        log("Loading our textures...");
        for texture_name : textures_to_load {
            new_texture_data := array_add(*program_state.texture_datas);

            desired_channels :: 4;
            channels : s32;

            full_texture_path := tprint("%/%.png", textures_path, texture_name);
            new_texture_data.bytes = stbi_load(
                temp_c_string(full_texture_path),
                *new_texture_data.width, *new_texture_data.height,
                channels_in_file = *channels,
                desired_channels = desired_channels);
            assert(desired_channels == channels);
            log("- Loaded % (%x%, % channels)", texture_name, new_texture_data.width, new_texture_data.height, channels);
        }

        log("\n");
    }
  
    init_instance();
    defer deinit_instance();

    vk_load_instance_functions(instance);

    init_surface(program_state.window);
    defer deinit_surface();

    init_device();
    defer deinit_device();

    vk_load_device_functions(device);

    // Get Queues
    {
        vkGetDeviceQueue(device, xx physical_device_context.queue_family_indices.graphics, queueIndex=0, *queue);
        //vkGetDeviceQueue(device, xx physical_device_context.queue_family_indices.compute, queueIndex=0, *compute_queue);
        //vkGetDeviceQueue(device, xx physical_device_context.queue_family_indices.transfer, queueIndex=0, *transfer_queue);
    }

    init_heaps();
    defer deinit_heaps();

    init_descriptor_heaps();

    init_swapchain(program_state.window_width, program_state.window_height);
    defer deinit_swapchain();

    init_render();
    defer deinit_render();

    begin_init_commands();
    heaps.scratch.on_full = (heap: *Heap) {
        submit_init_commands();
        begin_init_commands();
    };

    init_data();
    defer deinit_data();

    for program_state.texture_datas  stbi_image_free(it.bytes);
    array_free(program_state.texture_datas);

    init_imgui();
    defer deinit_imgui();

    submit_init_commands();
    heaps.scratch.on_full = null;

    running := true;
    last_time := seconds_since_init();
    while running {
        update_window_events();

        for events_this_frame {
            imgui_process_event(it);

            if it.type == {
                case .KEYBOARD;
                    // Alt binds
                    if it.alt_pressed {
                        if it.key_pressed && it.key_code == .F4 {
                            running = false;
                        }
                    }

                    if it.key_pressed && it.key_code == .MOUSE_BUTTON_LEFT
                       && !ImGui.GetIO().WantCaptureMouse {
                        set_mouse_look(true);
                    }

                    // Debug inputs
                    if it.key_pressed && it.key_code == .ESCAPE {
                        if camera.mouse_look_active  set_mouse_look(false);
                        else                         running = false;
                    }
            }

            if it.type == .QUIT then running = false;
        }

        for get_window_resizes() {
            if it.window != program_state.window continue;

            program_state.window_width  = xx it.width;
            program_state.window_height = xx it.height;
            swapchain_context.needs_recreation = true;
        }

        if !running break;

        if swapchain_context.needs_recreation {
            if !recreate_swapchain(program_state.window_width, program_state.window_height, present_fences) {
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

        {
            update_camera(dt);
            if flying  shimmer_camera_path(cast(float) now);

            // Update Light
            {
                using world_state;

                // The sun orbits the scene.
                sun_angle := cast(float) now * 0.4;
                light_direction = unit_vector(Vector3.{cos(sun_angle) * 0.3, 1.0, sin(sun_angle) * 0.3});
            }
        }

        imgui_new_frame();
        if !flying  imgui_debug_ui();
        ImGui.Render();

        if args.screenshot && frame_index + 1 == cast(u64) args.frames then screenshot.requested = true;
        if args.shimmer > 0 && frame_index >= SHIMMER_WARMUP_FRAMES then screenshot.requested = true;

        draw_frame();

        if args.shimmer > 0 && screenshot.captured {
            vkDeviceWaitIdle(device);
            shimmer_accumulate();
            screenshot.captured = false;
        }

        if args.benchmark > 0 && frame_index > SHIMMER_WARMUP_FRAMES + FRAMES_IN_FLIGHT {
            benchmark_total += gpu_frame_ms;
            benchmark_count += 1;
        }

        if args.frames > 0 && frame_index >= cast(u64) args.frames then running = false;
    }

    vkDeviceWaitIdle(device);

    if screenshot.captured then save_screenshot();
    if args.shimmer > 0 then shimmer_finish();
    if benchmark_count > 0 then print("BENCHMARK % ms average GPU frame time over % frames\n", formatFloat(benchmark_total / benchmark_count, trailing_width = 3), benchmark_count);
}

begin_init_commands :: () {
    begin_info := VkCommandBufferBeginInfo.{flags = .ONE_TIME_SUBMIT};
    result := vkBeginCommandBuffer(command_buffers[0], *begin_info);
    assert(result == .SUCCESS);
}

submit_init_commands :: () {
    result := vkEndCommandBuffer(command_buffers[0]);
    assert(result == .SUCCESS);

    submit_info := VkSubmitInfo.{commandBufferCount = 1, pCommandBuffers = *command_buffers[0]};
    result = vkQueueSubmit(queue, 1, *submit_info, VK_NULL_HANDLE);
    assert(result == .SUCCESS);

    vkDeviceWaitIdle(device);
    heap_reset(*heaps.scratch);
}

////////////////////////////////////////////////////////////////////////////////

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

////////////////////////////////////////////////////////////////////////////////

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

////////////////////////////////////////////////////////////////////////////////

textures_path   :: "assets/textures";
models_path     :: "assets/models";

textures_to_load :: string.[
    "croc"
];

models_to_load :: string.[
];
