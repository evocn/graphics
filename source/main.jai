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

    shaders                 : [2] VkShaderEXT;

    screenshot : struct {
        requested   : bool;
        captured    : bool;
        offset      : VkDeviceSize;
        extent      : VkExtent2D;
        format      : VkFormat;
    }
}

using scene_data : struct {
    texture : Texture;

    draw_data_offset : VkDeviceSize;

    vertex_offset   : VkDeviceSize;
    vertex_size     : VkDeviceSize;

    blas         : VkAccelerationStructureKHR;
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
    }
    success, args := parse_arguments(Command_Line_Arguments);
    if !success return;

    if args.screenshot && args.frames == 0 then args.frames = 1;

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

    result : VkResult;

    init_heaps();
    defer deinit_heaps();

    init_descriptor_heaps();

    init_swapchain(program_state.window_width, program_state.window_height);
    defer deinit_swapchain();

    init_render();
    defer deinit_render();

    {
        using begin_info: VkCommandBufferBeginInfo;
        flags = .ONE_TIME_SUBMIT;
        result = vkBeginCommandBuffer(command_buffers[0], *begin_info);
        assert(result == .SUCCESS);
    }

    init_data();
    defer deinit_data();

    init_imgui();
    defer deinit_imgui();

    // Submit any GPU initialization work accumulated so far.
    {
        result = vkEndCommandBuffer(command_buffers[0]);
        assert(result == .SUCCESS);

        using submit_info : VkSubmitInfo;
        commandBufferCount = 1;
        pCommandBuffers = *command_buffers[0];

        result = vkQueueSubmit(queue, 1, *submit_info, VK_NULL_HANDLE);
        assert(result == .SUCCESS);
    }

    vkDeviceWaitIdle(device);
    heap_reset(*heaps.scratch);

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

        // Update
        {
            update_camera(dt);

            // Update Light
            {
                using world_state;

                // The sun orbits the scene.
                sun_angle := cast(float) now * 0.4;
                light_direction = unit_vector(Vector3.{cos(sun_angle) * 0.7, 1.0, sin(sun_angle) * 0.7});
            }
        }

        imgui_new_frame();
        imgui_debug_ui();
        ImGui.Render();

        if args.screenshot && frame_index + 1 == cast(u64) args.frames then screenshot.requested = true;

        draw_frame();

        if args.frames > 0 && frame_index >= cast(u64) args.frames then running = false;
    }

    vkDeviceWaitIdle(device);

    if screenshot.captured then save_screenshot();
}

////////////////////////////////////////////////////////////////////////////////

#import "Basic";
#import "String";
#import "Math";

#import "File";
#import "Command_Line";

#import "Window_Creation";
#import "Input";

#import "Vulkan";
#import "stb_image";
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
#load "rhi/texture.jai";
#load "rhi/acceleration_structure.jai";
#load "scene.jai";
#load "frame.jai";
#load "imgui.jai";

////////////////////////////////////////////////////////////////////////////////

textures_path   :: "assets/textures";
models_path     :: "assets/models";

textures_to_load :: string.[
    "croc"
];

models_to_load :: string.[
];
