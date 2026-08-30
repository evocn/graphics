// Graphics
// Main

DEVELOPER_TOOLS :: #run BUILD_TYPE == .DEBUG;

program_state : struct {
    using window_context : struct {
        window_width    : u32 = 960;
        window_height   : u32 = 540;

        window          : Window_Type;
    }

    Texture_Data :: struct {
        bytes : *void;
        width : s32;
        height: s32;
    }
    texture_datas : [..] Texture_Data;
}

using vulkan_context : struct {
    instance                : VkInstance;
    surface                 : VkSurfaceKHR;
    debug_callback_handle   : VkDebugReportCallbackEXT;

    physical_device_context : struct {
        physical_device : VkPhysicalDevice;
        queue_family_indices : struct {
            graphics : int = -1;
            compute  : int = -1;
            transfer : int = -1;
        }

        memory_properties : VkPhysicalDeviceMemoryProperties;

        using properties : struct {
            properties2 : VkPhysicalDeviceProperties2;
            vulkan_1_1_properties   : VkPhysicalDeviceVulkan11Properties;
            vulkan_1_2_properties   : VkPhysicalDeviceVulkan12Properties;
            vulkan_1_3_properties   : VkPhysicalDeviceVulkan13Properties;
            vulkan_1_4_properties   : VkPhysicalDeviceVulkan14Properties;
            descriptor_heap_properties      : VkPhysicalDeviceDescriptorHeapPropertiesEXT;
        }

        using features : struct {
            features2           : VkPhysicalDeviceFeatures2;
            vulkan_1_1_features : VkPhysicalDeviceVulkan11Features;
            vulkan_1_2_features : VkPhysicalDeviceVulkan12Features;
            vulkan_1_3_features : VkPhysicalDeviceVulkan13Features;
            vulkan_1_4_features : VkPhysicalDeviceVulkan14Features;
            shader_object_features          : VkPhysicalDeviceShaderObjectFeaturesEXT;
            unified_image_layout_features   : VkPhysicalDeviceUnifiedImageLayoutsFeaturesKHR;
            descriptor_heap_features        : VkPhysicalDeviceDescriptorHeapFeaturesEXT;
            untyped_pointers_features       : VkPhysicalDeviceShaderUntypedPointersFeaturesKHR;
            address_commands_features       : VkPhysicalDeviceDeviceAddressCommandsFeaturesKHR;
        }
    }

    device  : VkDevice;
    queue   : VkQueue;

    swapchain_context : struct {
        MAX_SWAPCHAIN_IMAGES   :: 3;
        swapchain       : VkSwapchainKHR;
        surface_format  : VkSurfaceFormatKHR;
        extent      : VkExtent2D;
        image_count : u32;
        images      : [MAX_SWAPCHAIN_IMAGES] VkImage;
        views       : [MAX_SWAPCHAIN_IMAGES] VkImageView;

        needs_recreation : bool;
    }

    using render_context : struct {
        FRAMES_IN_FLIGHT :: 2;
        frame_index : u64 = 0;
        timeline_semaphore  : VkSemaphore;
        command_pool        : VkCommandPool;
        command_buffers             : [FRAMES_IN_FLIGHT] VkCommandBuffer;
        image_available_semaphores  : [FRAMES_IN_FLIGHT] VkSemaphore;
        present_ready_semaphores    : [swapchain_context.MAX_SWAPCHAIN_IMAGES] VkSemaphore;

        using descriptor_heap : struct {
            image_descriptor_stride     : VkDeviceSize;
            sampler_descriptor_stride   : VkDeviceSize;

            resource_heap_offset    : VkDeviceSize;
            sampler_heap_offset     : VkDeviceSize;

            bind_resource_heap_info : VkBindHeapInfoEXT;
            bind_sampler_heap_info  : VkBindHeapInfoEXT;

            first_image_id      : u32;
            first_sampler_id    : u32;
        }

        shaders                 : [2] VkShaderEXT;
    }

    arena : struct {
        SIZE :: 16 * 1024 * 1024;

        buffer  : VkBuffer;
        memory  : VkDeviceMemory;
        address : VkDeviceAddress;
        cpu_map : *void;
        used    : VkDeviceSize;
    }

    using scene_data : struct {
        texture : struct {
            image   : VkImage;
            memory  : VkDeviceMemory;
        }

        staging_offset  : VkDeviceSize;
        staging_size    : VkDeviceSize;
        vertex_offset   : VkDeviceSize;
        vertex_size     : VkDeviceSize;
    }
}

main :: () {
    set_working_directory_to_base_folder :: () {
        executable_path := path_strip_filename(get_path_of_running_executable());
        set_working_directory(tprint("%/../", executable_path));
    }
    set_working_directory_to_base_folder();

    program_state.window = create_window(
        xx program_state.window_width, xx program_state.window_height,
        program_title,
        window_x = 0,
        window_y = 0,
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

    init_surface();
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

    init_arena();
    defer deinit_arena();

    init_descriptor_heap();

    init_swapchain();
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

    // Wait until all GPU initialization work is complete before proceeding.
    vkDeviceWaitIdle(device);

    running := true;
    while running {
        update_window_events();

        for events_this_frame {
            if it.type == {
                case .KEYBOARD;
                    // Alt binds
                    if it.alt_pressed {
                        if it.key_pressed && it.key_code == .F4 {
                            running = false;
                        }
                    }

                    // Debug inputs
                    if it.key_pressed && it.key_code == .ESCAPE {
                        running = false;
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
            if !recreate_swapchain() {
                sleep_milliseconds(16);
                continue;
            }
        }

        draw_frame();
    }

    vkDeviceWaitIdle(device);
}

////////////////////////////////////////////////////////////////////////////////

#import "Basic";
#import "String";
#import "Math";

#import "File";

#import "Window_Creation";
#import "Input";

#import "Vulkan";
#import "stb_image";

#import "System";
#if OS == .WINDOWS {
    #import "Windows";
}

////////////////////////////////////////////////////////////////////////////////

#load "utils.jai";
#load "device.jai";
#load "memory.jai";
#load "swapchain.jai";
#load "scene.jai";
#load "frame.jai";

////////////////////////////////////////////////////////////////////////////////

textures_path   :: "assets/textures";
models_path     :: "assets/models";

textures_to_load :: string.[
    "croc"
];

models_to_load :: string.[
];
