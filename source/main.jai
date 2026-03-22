// Graphics
// Main

DEVELOPER_TOOLS :: #run BUILD_TYPE == .DEBUG;

program_state : struct {
    using window_context : struct {
        window_width    : u32 = 960;
        window_height   : u32 = 540;

        window          : Window_Type;
    }
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

            descriptor_heap_buffer  : VkBuffer;
            descriptor_heap_memory  : VkDeviceMemory;

            descriptor_heap_cpu_map : *void;
            resource_heap_cpu_map   : *void;
            sampler_heap_cpu_map    : *void;

            bind_resource_heap_info : VkBindHeapInfoEXT;
            bind_sampler_heap_info  : VkBindHeapInfoEXT;

            first_image_id      : u32;
            first_sampler_id    : u32;
        }
    }

    using scene_data : struct {
        uniform_buffer          : VkBuffer;
        vertex_buffer           : VkBuffer;

        shaders                 : [2] VkShaderEXT;
    }
}

Vertex :: struct {
    position    : Vector3;
    color       : Vector3;
    uv          : Vector2;
}

vertices := Vertex.[
    .{position = .{ 0.0, -0.5,  0.0}, color = .{1, 0, 0}, uv = .{.5, .5}},
    .{position = .{ 0.5,  0.5,  0.0}, color = .{0, 1, 0}, uv = .{0, 0}},
    .{position = .{-0.5,  0.5,  0.0}, color = .{0, 0, 1}, uv = .{1, 1}},
];

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
            width, height : s32;
            desired_channels :: 4;
            channels : s32;

            full_texture_path := tprint("%/%.png", textures_path, texture_name);
            data := stbi_load(
                temp_c_string(full_texture_path),
                *width, *height,
                channels_in_file = *channels,
                desired_channels = desired_channels);
            assert(desired_channels == channels);
            log("- Loaded %", texture_name);
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

    init_descriptor_heap();
    defer deinit_descriptor_heap();

    init_swapchain();
    defer deinit_swapchain();

    init_render();
    defer deinit_render();

    result : VkResult;

    // Data
    {
        // Vertex Buffer
        {
            {
                using create_info : VkBufferCreateInfo;
                size = size_of(type_of(vertices));
                usage = .VERTEX_BUFFER;

                result = vkCreateBuffer(device, *create_info, null, *vertex_buffer);
                assert(result == .SUCCESS);
            }

            // @TODO: Track and free this memory.
            memory_requirements : VkMemoryRequirements;
            vkGetBufferMemoryRequirements(device, vertex_buffer, *memory_requirements);

            device_memory : VkDeviceMemory;
            {
                success, memory_type_index := select_memory_type(physical_device_context.memory_properties, memory_requirements.memoryTypeBits, .HOST_VISIBLE);
                assert(success);
                assert(memory_type_index != -1);

                {
                    using allocate_info : VkMemoryAllocateInfo;
                    allocationSize = memory_requirements.size;
                    memoryTypeIndex = xx memory_type_index;

                    result = vkAllocateMemory(device, *allocate_info, null, *device_memory);
                    assert(result == .SUCCESS);
                }
            }

            // Map
            {
                data : *void;
                result := vkMapMemory(
                    device,
                    device_memory,
                    0,
                    VK_WHOLE_SIZE,
                    0,
                    *data
                );
                assert(result == .SUCCESS);

                memcpy(data, *vertices, size_of(type_of(vertices)));
            }

            result = vkBindBufferMemory(device, vertex_buffer, device_memory, 0);
            assert(result == .SUCCESS);
        }

        // Uniform Buffer
        {
            {
                using buffer_create_info : VkBufferCreateInfo;
                size = 16 * size_of(float);
                usage = .UNIFORM_BUFFER;

                vkCreateBuffer(device, *buffer_create_info, null, *uniform_buffer);
            }

            // @TODO: Track and free this memory.
            device_memory : VkDeviceMemory;
            {
                allocate_info : VkMemoryAllocateInfo;
                {
                    using allocate_info;
                    allocationSize = 16 * size_of(float);
                    memoryTypeIndex = 0;
                }

                result = vkAllocateMemory(device, *allocate_info, null, *device_memory);
                assert(result == .SUCCESS);

                result = vkBindBufferMemory(device, uniform_buffer, device_memory, 0);
                assert(result == .SUCCESS);
            }
        }
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

        draw_frame();
    }

    vkDeviceWaitIdle(device);
}

init_instance :: () {
    result : VkResult;

    {
        using instance_create_info : VkInstanceCreateInfo;
        application_info := VkApplicationInfo.{apiVersion = VK_MAKE_API_VERSION(1, 4, 0, 0)};
        pApplicationInfo = *application_info;

        instance_extensions : [..] *u8;
        array_add(*instance_extensions, VK_KHR_SURFACE_EXTENSION_NAME.data);
        #if OS == .WINDOWS {
            array_add(*instance_extensions, VK_KHR_WIN32_SURFACE_EXTENSION_NAME.data);
        } else {
            #assert(false);
        }

        #if DEVELOPER_TOOLS {
            array_add(*instance_extensions, VK_EXT_DEBUG_REPORT_EXTENSION_NAME.data);
        }

        enabledExtensionCount   = xx instance_extensions.count;
        ppEnabledExtensionNames = instance_extensions.data;

        enabled_layers: [..] *u8;

        #if DEVELOPER_TOOLS {
            array_add(*enabled_layers, "VK_LAYER_KHRONOS_validation");
        }

        enabledLayerCount = xx enabled_layers.count;
        ppEnabledLayerNames = enabled_layers.data;

        result = vkCreateInstance(*instance_create_info, null, *instance);
        assert(result == .SUCCESS);
    }

    #if DEVELOPER_TOOLS {
        vkCreateDebugReportCallbackEXT  : PFN_vkCreateDebugReportCallbackEXT = xx vkGetInstanceProcAddr(instance, "vkCreateDebugReportCallbackEXT");
        vkDestroyDebugReportCallbackEXT : PFN_vkDestroyDebugReportCallbackEXT = xx vkGetInstanceProcAddr(instance, "vkDestroyDebugReportCallbackEXT");
        vkDebugReportMessageEXT         : PFN_vkDebugReportMessageEXT = xx vkGetInstanceProcAddr(instance, "vkDebugReportMessageEXT");

        if vkCreateDebugReportCallbackEXT {
            debug_callback_create_info: VkDebugReportCallbackCreateInfoEXT;
            debug_callback_create_info.flags |= .ERROR;
            debug_callback_create_info.flags |= .WARNING;
            debug_callback_create_info.pfnCallback = debug_callback;
            debug_callback_create_info.pUserData = xx *context;

            result = vkCreateDebugReportCallbackEXT(instance, *debug_callback_create_info, null, *debug_callback_handle);
            assert(result == .SUCCESS);
        }
        else {
            log_error("Unable to load the debug callback!");
        }
    }
}


deinit_instance :: () {
    #if DEVELOPER_TOOLS {
        if vkDestroyDebugReportCallbackEXT && debug_callback_handle {
            vkDestroyDebugReportCallbackEXT(instance, debug_callback_handle, null);
        }
    }
    vkDestroyInstance(instance, null);
}

init_surface :: () {
    #if OS == .WINDOWS {
        my_hwnd := program_state.window;
        using surface_create_info: VkWin32SurfaceCreateInfoKHR; 
        hinstance = GetModuleHandleW(null);
        hwnd      = my_hwnd;
        result := vkCreateWin32SurfaceKHR(instance, *surface_create_info, null, *surface);
        assert(result == .SUCCESS);
    } else {
        #assert(false);
    }
}

deinit_surface :: () {
    vkDestroySurfaceKHR(instance, surface, null);
}

init_device :: () {
    result : VkResult;

    physical_device_count : u32 = ---;
    physical_devices : [..] VkPhysicalDevice;
    {
        result = vkEnumeratePhysicalDevices(instance, *physical_device_count, null);
        assert(result == .SUCCESS);
        assert(physical_device_count != 0, "You're running this on a machine which does not have any Vulkan-compatible drivers!");

        array_resize(*physical_devices, physical_device_count, initialize=false);
        result = vkEnumeratePhysicalDevices(instance, *physical_device_count, physical_devices.data);
        assert(result == .SUCCESS);
    }

    log("Vulkan sees % Physical device%.", physical_device_count, ifx physical_device_count == 1 then "" else "s");

    favorite_device_index : int = -1; // This is where we'll choose the physical device we want to use.
    for physical_device, device_index : physical_devices {
        log("\n");
        log("    Physical Device %:", device_index);

        is_discrete : bool;
        {
            physical_device_properties : VkPhysicalDeviceProperties;
            vkGetPhysicalDeviceProperties(physical_device, *physical_device_properties);
            log_physical_device_properties(physical_device_properties);
            is_discrete = physical_device_properties.deviceType == .DISCRETE_GPU;
        }

        queue_family_index_which_supports_present := -1;
        {
            queue_family_count: u32 = ---;
            queue_families : [..] VkQueueFamilyProperties;
            vkGetPhysicalDeviceQueueFamilyProperties(physical_device, *queue_family_count, null);
            array_resize(*queue_families, queue_family_count, initialize=false);
            vkGetPhysicalDeviceQueueFamilyProperties(physical_device, *queue_family_count, queue_families.data);
            log("    Physical device % supports % queues families.", device_index, queue_family_count);

            for queue_family, queue_family_index : queue_families {
                supports_present := VK_FALSE;
                vkGetPhysicalDeviceSurfaceSupportKHR(physical_device, xx queue_family_index, surface, *supports_present);

                log("        %: %", queue_family_index, queue_family);

                if supports_present && (queue_family.queueFlags & .GRAPHICS) {
                    queue_family_index_which_supports_present = queue_family_index;
                }
            }
        }

        if is_discrete {
            log("    It's a discrete GPU.");
        }
        has_graphics_queue_which_supports_present := queue_family_index_which_supports_present != -1;
        if has_graphics_queue_which_supports_present {
            log("    Queue family % supports present and graphics.", queue_family_index_which_supports_present);
        }

        if has_graphics_queue_which_supports_present && is_discrete {
            favorite_device_index = device_index;
        }
    }

    assert(favorite_device_index != -1);

    log("\n");

    log("Alright. We've seen enough. We're choosing device %!", favorite_device_index);
    physical_device_context.physical_device = physical_devices[favorite_device_index];

    log("\n");

    {
        using physical_device_context;

        // Select Queue Family Indices for the program.
        {
            queue_family_count: u32 = ---;
            queue_families : [..] VkQueueFamilyProperties;
            vkGetPhysicalDeviceQueueFamilyProperties(physical_device, *queue_family_count, null);
            array_resize(*queue_families, queue_family_count, initialize=false);
            vkGetPhysicalDeviceQueueFamilyProperties(physical_device, *queue_family_count, queue_families.data);

            using queue_family_indices;
            for queue_family, queue_family_index : queue_families {
                supports_present := VK_FALSE;
                vkGetPhysicalDeviceSurfaceSupportKHR(physical_device, xx queue_family_index, surface, *supports_present);

                if graphics == -1 && queue_family.queueFlags & .GRAPHICS {
                    graphics = queue_family_index;
                }
                else if compute == -1 && queue_family.queueFlags & (.COMPUTE & ~.GRAPHICS) {
                    compute = queue_family_index;
                }
                else if transfer == -1 && queue_family.queueFlags & (.TRANSFER & ~.GRAPHICS & ~.COMPUTE) {
                    transfer = queue_family_index;
                }
            }

            {
                using queue_family_indices;
                log("Using the following queue family indices with this GPU:");
                log("    %: Graphics", graphics);
                log("    %: Compute", compute);
                log("    %: Transfer", transfer);
                log("\n");
            }
        }

        vkGetPhysicalDeviceMemoryProperties(physical_device, *memory_properties);
        {
            using memory_properties;
            log("Physical Device Memory types:");
            for 0..memoryTypeCount-1 {
                log("    %: %", it, memoryTypes[it]);
            }
            log("\n");
        }

        // Create Device
        {
            using device_create_info: VkDeviceCreateInfo;

            queue_create_infos: [3] VkDeviceQueueCreateInfo;
            queue_create_infos[0].queueFamilyIndex = xx queue_family_indices.graphics;
            queue_create_infos[0].queueCount = 1;
            queue_create_infos[0].pQueuePriorities = float.[1.0].data;

            queue_create_infos[1].queueFamilyIndex = xx queue_family_indices.compute;
            queue_create_infos[1].queueCount = 1;
            queue_create_infos[1].pQueuePriorities = float.[1.0].data;

            queue_create_infos[2].queueFamilyIndex = xx queue_family_indices.transfer;
            queue_create_infos[2].queueCount = 1;
            queue_create_infos[2].pQueuePriorities = float.[1.0].data;

            queueCreateInfoCount    = 3;
            pQueueCreateInfos       = queue_create_infos.data;

            // Device Extensions
            device_extensions: [..] *u8;
            array_add(*device_extensions, VK_KHR_SWAPCHAIN_EXTENSION_NAME.data);
            array_add(*device_extensions, VK_KHR_DYNAMIC_RENDERING_EXTENSION_NAME.data);
            array_add(*device_extensions, VK_EXT_SHADER_OBJECT_EXTENSION_NAME.data);
            array_add(*device_extensions, VK_EXT_DESCRIPTOR_HEAP_EXTENSION_NAME.data);
            array_add(*device_extensions, VK_KHR_UNIFIED_IMAGE_LAYOUTS_EXTENSION_NAME.data);

            enabledExtensionCount   = xx device_extensions.count;
            ppEnabledExtensionNames = device_extensions.data;

            // Properties
            {
                descriptor_heap_properties = .{pNext = null};
                properties2 = .{pNext = *descriptor_heap_properties};
                vkGetPhysicalDeviceProperties2(physical_device, *properties2);
            }

            // Features
            {
                unified_image_layout_features = .{unifiedImageLayouts = VK_TRUE, pNext = null};
                shader_object_features = .{shaderObject = VK_TRUE, pNext = *unified_image_layout_features};
                vulkan_1_4_features = .{pNext = *shader_object_features};
                vulkan_1_3_features = .{pNext = *vulkan_1_4_features};
                {
                    using vulkan_1_3_features;
                    dynamicRendering = VK_TRUE;
                    synchronization2 = VK_TRUE;
                }
                vulkan_1_2_features = .{pNext = *vulkan_1_3_features};
                {
                    using vulkan_1_2_features;
                    timelineSemaphore = VK_TRUE;
                    bufferDeviceAddress = VK_TRUE;
                    runtimeDescriptorArray = VK_TRUE;
                }
                vulkan_1_1_features = .{pNext = *vulkan_1_2_features};
                {
                    using vulkan_1_1_features;
                }
                vkGetPhysicalDeviceFeatures2(physical_device, *features2);
                {
                    using features2.features;
                    geometryShader = VK_FALSE;
                    tessellationShader = VK_FALSE;
                }
            }

            features2.pNext = *vulkan_1_1_features;
            pNext = *features2;

            result = vkCreateDevice(physical_device, *device_create_info, null, *device);
            assert(result == .SUCCESS);
        }
    }
}

deinit_device :: () {
    vkDestroyDevice(device, null);
}

init_descriptor_heap :: () {
    result : VkResult;
    using physical_device_context;

    image_descriptor_stride = descriptor_heap_properties.imageDescriptorSize;
    sampler_descriptor_stride = descriptor_heap_properties.samplerDescriptorSize;

    max_image_descriptors   :: 1;
    max_sampler_descriptors :: 1;
    resource_heap_size := align_up(
        align_up(max_image_descriptors * image_descriptor_stride, descriptor_heap_properties.imageDescriptorAlignment) + descriptor_heap_properties.minResourceHeapReservedRange,
        descriptor_heap_properties.resourceHeapAlignment);
    sampler_heap_size := align_up(
        align_up(max_sampler_descriptors * sampler_descriptor_stride, descriptor_heap_properties.samplerDescriptorAlignment) + descriptor_heap_properties.minSamplerHeapReservedRange,
        descriptor_heap_properties.samplerHeapAlignment);
    descriptor_heap_size := align_up(sampler_heap_size, descriptor_heap_properties.resourceHeapAlignment) + resource_heap_size;

    {
        using buffer_create_info : VkBufferCreateInfo;
        size = descriptor_heap_size;
        usage = .DESCRIPTOR_HEAP_EXT | .SHADER_DEVICE_ADDRESS;

        result = vkCreateBuffer(device, *buffer_create_info, null, *descriptor_heap_buffer);
        assert(result == .SUCCESS);
    }

    // Allocate Memory for the buffer.
    memory_requirements : VkMemoryRequirements;
    vkGetBufferMemoryRequirements(device, descriptor_heap_buffer, *memory_requirements);

    {
        success, memory_type_index := select_memory_type(physical_device_context.memory_properties, memory_requirements.memoryTypeBits, .DEVICE_LOCAL | .HOST_VISIBLE);
        assert(success);
        assert(memory_type_index != -1);

        {
            memory_allocate_flags_info : VkMemoryAllocateFlagsInfo;
            {
                using memory_allocate_flags_info;
                flags = .DEVICE_ADDRESS;
            }

            using memory_allocate_info : VkMemoryAllocateInfo;
            pNext = *memory_allocate_flags_info;
            allocationSize = memory_requirements.size;
            memoryTypeIndex = xx memory_type_index;

            result = vkAllocateMemory(device, *memory_allocate_info, null, *descriptor_heap_memory);
            assert(result == .SUCCESS);
        }
    }

    
    result = vkBindBufferMemory(device, descriptor_heap_buffer, descriptor_heap_memory, 0);
    assert(result == .SUCCESS);

    result = vkMapMemory(device, descriptor_heap_memory, 0, VK_WHOLE_SIZE, 0, *descriptor_heap_cpu_map);
    assert(result == .SUCCESS);
    assert(descriptor_heap_cpu_map != null);

    device_address_info := VkBufferDeviceAddressInfo.{buffer = descriptor_heap_buffer};
    device_address := vkGetBufferDeviceAddress(device, *device_address_info);

    // Binding Infos
    {
        // Sampler
        {
            using bind_sampler_heap_info;
            heapRange = .{
                address = device_address,
                size = sampler_heap_size,
            };
            reservedRangeOffset = 0;
            reservedRangeSize = descriptor_heap_properties.minSamplerHeapReservedRange;
        }
        sampler_heap_cpu_map = descriptor_heap_cpu_map + descriptor_heap_properties.minSamplerHeapReservedRange;

        // Resource 
        {
            using bind_resource_heap_info;
            heapRange = .{
                address = device_address + align_up(sampler_heap_size, descriptor_heap_properties.resourceHeapAlignment),
                size = resource_heap_size,
            };
            reservedRangeOffset = 0;
            reservedRangeSize = descriptor_heap_properties.minResourceHeapReservedRange;
        }
        resource_heap_cpu_map = descriptor_heap_cpu_map + align_up(sampler_heap_size, descriptor_heap_properties.resourceHeapAlignment) + descriptor_heap_properties.minResourceHeapReservedRange;
    }

    first_image_id    = cast(u32, (descriptor_heap_properties.minResourceHeapReservedRange + image_descriptor_stride - 1) / image_descriptor_stride);
    first_sampler_id  = cast(u32, (descriptor_heap_properties.minSamplerHeapReservedRange + sampler_descriptor_stride - 1) / sampler_descriptor_stride);
}

deinit_descriptor_heap :: () {
    // @TODO
}

init_swapchain :: () {
    result : VkResult;
    using physical_device_context;

    // Use first available surface format
    surface_format_count : u32 = ---;
    surface_formats : [..] VkSurfaceFormatKHR;
    result = vkGetPhysicalDeviceSurfaceFormatsKHR(physical_device, surface, *surface_format_count, null);
    assert(result == .SUCCESS);
    array_resize(*surface_formats, surface_format_count, initialize=false);

    vkGetPhysicalDeviceSurfaceFormatsKHR(physical_device, surface, *surface_format_count, surface_formats.data);
    assert(result == .SUCCESS);

    for surface_format : surface_formats {
        if surface_format.format == .UNDEFINED {
            swapchain_context.surface_format.format = .B8G8R8A8_UNORM;
            break;
        }
        else {
            swapchain_context.surface_format = surface_format;
            // @NOTE: This is where you'd pick a desired swapchain format from the list provided by the physical device.
        }
    }

    present_mode_count : u32 = ---;
    present_modes: [..] VkPresentModeKHR;
    vkGetPhysicalDeviceSurfacePresentModesKHR(physical_device, surface, *present_mode_count, null);
    array_resize(*present_modes, present_mode_count, initialize=false);
    vkGetPhysicalDeviceSurfacePresentModesKHR(physical_device, surface, *present_mode_count, present_modes.data);

    chosen_present_mode : VkPresentModeKHR = .FIFO; // always supported.
    for present_mode : present_modes {
        if present_mode == .MAILBOX {
            chosen_present_mode = .MAILBOX;
            break;
        }
    }

    PRESENT_MODE_MAILBOX_IMAGE_COUNT : u32 : 3;
    PRESENT_MODE_DEFAULT_IMAGE_COUNT : u32 : 2;
 
    swapchain_context.image_count = ifx chosen_present_mode == .MAILBOX  then PRESENT_MODE_MAILBOX_IMAGE_COUNT else  PRESENT_MODE_DEFAULT_IMAGE_COUNT;

    surface_capabilities: VkSurfaceCapabilitiesKHR;
    vkGetPhysicalDeviceSurfaceCapabilitiesKHR(physical_device, surface, *surface_capabilities);

    swapchain_context.extent = surface_capabilities.currentExtent;
    if swapchain_context.extent.width == U32_MAX {
        swapchain_context.extent.width  = clamp(
            program_state.window_width,
            surface_capabilities.minImageExtent.width,
            surface_capabilities.maxImageExtent.width
        );
        swapchain_context.extent.height = clamp(
            program_state.window_height,
            surface_capabilities.minImageExtent.height,
            surface_capabilities.maxImageExtent.height
        );
    }

    swapchain_create_info: VkSwapchainCreateInfoKHR;
    the_surface := surface;  // No way yet to avoid importing this with 'using'. Should fix that!
    {
        swapchain_create_info.surface = the_surface;

        using swapchain_create_info;
        minImageCount               = swapchain_context.image_count;
        imageFormat                 = swapchain_context.surface_format.format;
        imageColorSpace             = swapchain_context.surface_format.colorSpace;
        imageExtent                 = swapchain_context.extent;
        imageArrayLayers            = 1;
        imageUsage                  |= .COLOR_ATTACHMENT;
        imageUsage                  |=  .TRANSFER_DST;
        imageSharingMode            = .EXCLUSIVE;
        preTransform                = surface_capabilities.currentTransform;
        compositeAlpha              = .OPAQUE;
        presentMode                 = chosen_present_mode;
        clipped                     = VK_TRUE;
    }
    
    result = vkCreateSwapchainKHR(device, *swapchain_create_info, null, *swapchain_context.swapchain);
    assert(result == .SUCCESS);

    result = vkGetSwapchainImagesKHR(device, swapchain_context.swapchain, *swapchain_context.image_count, null);
    assert(result == .SUCCESS);

    result = vkGetSwapchainImagesKHR(device, swapchain_context.swapchain, *swapchain_context.image_count, swapchain_context.images.data);
    assert(result == .SUCCESS);

    // Create image views of all swapchain images
    {
        for 0..swapchain_context.image_count-1 {
            image_view_create_info : VkImageViewCreateInfo;

            {
                using image_view_create_info;
                image = swapchain_context.images[it];
                viewType = .e2D;
                format = swapchain_context.surface_format.format;
                components.r = .IDENTITY;
                components.g = .IDENTITY;
                components.b = .IDENTITY;
                components.a = .IDENTITY;

                subresourceRange.aspectMask = .COLOR;
                subresourceRange.baseMipLevel = 0;
                subresourceRange.levelCount = 1;
                subresourceRange.baseArrayLayer = 0;
                subresourceRange.layerCount = 1;
            }

            result = vkCreateImageView(device, *image_view_create_info, null, *swapchain_context.views[it]);
            assert(result == .SUCCESS);
        }
    }
}

deinit_swapchain :: () {
    // @TODO: Destroy image views too.
    vkDestroySwapchainKHR(device, swapchain_context.swapchain, null);
}

init_render :: () {
    result : VkResult;

    // Command Buffers
    {
        // Pool
        {
            using command_pool_create_info: VkCommandPoolCreateInfo;
            flags            = .RESET_COMMAND_BUFFER;
            queueFamilyIndex = xx physical_device_context.queue_family_indices.graphics;
            result = vkCreateCommandPool(device, *command_pool_create_info, null, *command_pool);
            assert(result == .SUCCESS);
        }

        {
            using command_buffer_allocate_info: VkCommandBufferAllocateInfo;
            commandPool        = command_pool;
            level              = .PRIMARY;
            commandBufferCount = FRAMES_IN_FLIGHT;
            result = vkAllocateCommandBuffers(device, *command_buffer_allocate_info, command_buffers.data);
            assert(result == .SUCCESS);
        }
    }

    // Semaphores
    {
        // Render / Present
        {
            using semaphore_create_info: VkSemaphoreCreateInfo;
            for image_index : 0..swapchain_context.image_count-1 {
                vkCreateSemaphore(device, *semaphore_create_info, null, *present_ready_semaphores[image_index]);
            }
            for index : 0..FRAMES_IN_FLIGHT-1 {
                vkCreateSemaphore(device, *semaphore_create_info, null, *image_available_semaphores[index]);
            }
        }

        // Timeline
        {
            semaphore_type_create_info : VkSemaphoreTypeCreateInfo;
            {
                using semaphore_type_create_info;
                semaphoreType = .TIMELINE;
                initialValue = 0;
            }

            using timeline_semaphore_create_info: VkSemaphoreCreateInfo;
            pNext = *semaphore_type_create_info;

            vkCreateSemaphore(device, *timeline_semaphore_create_info, null, *timeline_semaphore);
        }
    }

    // Shaders
    {
        // Read spirv from file
        spirv : [2] string;
        {
            read_shader_file :: (name: string) -> spirv: string
            {
                shader_file_path := tprint("%/%", compiled_shaders_directory, tprint("%.spv", name));

                spirv, success := read_entire_file(shader_file_path);
                assert(success, "Unable to read shader file %", shader_file_path);

                return spirv;
            }
            spirv[0] = read_shader_file("material-vertex");
            spirv[1] = read_shader_file("material-fragment");
        }

        // Shader Object Create Infos
        {
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

                pushConstantRangeCount = 0;
                pPushConstantRanges = null;
                pSpecializationInfo = null;
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

                pushConstantRangeCount = 0;
                pPushConstantRanges = null;
                pSpecializationInfo = null;
            }

            result = vkCreateShadersEXT(device,
                shader_create_infos.count, shader_create_infos.data,
                null,
                shaders.data
            );
            assert(result == .SUCCESS);
        }
    }
}

deinit_render :: () {
    for image_index : 0..swapchain_context.image_count-1 {
        vkDestroySemaphore(device, present_ready_semaphores[image_index], null);
    }
    for index : 0..FRAMES_IN_FLIGHT-1 {
        vkDestroySemaphore(device, image_available_semaphores[index], null);
    }
    vkDestroyCommandPool(device, command_pool, null);
}

bind_descriptor_heaps :: (command_buffer : VkCommandBuffer) {
    vkCmdBindSamplerHeapEXT(command_buffer, *bind_sampler_heap_info);
    vkCmdBindResourceHeapEXT(command_buffer, *bind_resource_heap_info);
}

set_draw_state :: (command_buffer: VkCommandBuffer) {
    vkCmdSetRasterizerDiscardEnable(command_buffer, VK_FALSE);
    vkCmdSetPrimitiveRestartEnable(command_buffer,  VK_FALSE);

    vkCmdSetPrimitiveTopology(command_buffer,       .TRIANGLE_LIST);

    vkCmdSetDepthTestEnable(command_buffer,         VK_FALSE);
    vkCmdSetDepthWriteEnable(command_buffer,        VK_FALSE);
    vkCmdSetDepthBiasEnable(command_buffer,         VK_FALSE);
    vkCmdSetDepthBoundsTestEnable(command_buffer,   VK_FALSE);
    vkCmdSetDepthClampEnableEXT(command_buffer,     VK_FALSE);

    vkCmdSetStencilTestEnable(command_buffer,       VK_FALSE);

    vkCmdSetPolygonModeEXT(command_buffer,          .FILL);
    vkCmdSetFrontFace(command_buffer,               .CLOCKWISE);
    vkCmdSetCullMode(command_buffer,                .BACK);

    vkCmdSetAlphaToOneEnableEXT(command_buffer,     VK_FALSE);
    vkCmdSetAlphaToCoverageEnableEXT(command_buffer,VK_FALSE);
    vkCmdSetLogicOpEnableEXT(command_buffer,        VK_FALSE);

    color_blend_enables : [1] VkBool32;
    {
        color_blend_enables[0] = VK_FALSE;
    }

    vkCmdSetColorBlendEnableEXT(command_buffer,
        firstAttachment = 0,
        attachmentCount = color_blend_enables.count,
        pColorBlendEnables = color_blend_enables.data,
    );

    color_write_masks : [1] VkColorComponentFlags;
    {
        color_write_masks[0] = .R | .G | .B | .A;
    }
    vkCmdSetColorWriteMaskEXT(command_buffer,
        firstAttachment = 0,
        attachmentCount = color_write_masks.count,
        pColorWriteMasks = color_write_masks.data
    );

    vkCmdSetRasterizationSamplesEXT(command_buffer, .e1);
    sample_mask : VkSampleMask = 1;
    vkCmdSetSampleMaskEXT(command_buffer, .e1, *sample_mask);


    {
        viewports : [1] VkViewport;
        {
            {
                using viewports[0];
                x = 0;                    
                y = 0;
                width       = xx swapchain_context.extent.width;
                height      = xx swapchain_context.extent.height;
                minDepth = 0;
                maxDepth = 1;
            }
        }
        vkCmdSetViewportWithCount(command_buffer, viewports.count, viewports.data);
    }

    {
        scissors : [1] VkRect2D;
        {
            {
                using scissors[0];
                offset = .{0, 0};
                extent = swapchain_context.extent;
            }
        }
        vkCmdSetScissorWithCount(command_buffer, scissors.count, scissors.data);
    }

    // Vertex Input
    {
        vertex_input_binding_descriptions : [1] VkVertexInputBindingDescription2EXT;
        {
            {
                using vertex_input_binding_descriptions[0];
                binding     = 0;
                stride      = size_of(Vertex);
                inputRate   = .VERTEX;
                divisor     = 1;
            }
        }

        vertex_input_attribute_descriptions := VkVertexInputAttributeDescription2EXT.[
            .{ location = 0, binding = 0, format = .R32G32B32_SFLOAT, offset = offset_of(Vertex, "position") },
            .{ location = 1, binding = 0, format = .R32G32B32_SFLOAT, offset = offset_of(Vertex, "color") },
            .{ location = 2, binding = 0, format = .R32G32_SFLOAT,    offset = offset_of(Vertex, "uv") },
        ];

        vkCmdSetVertexInputEXT(
            command_buffer,
            vertex_input_binding_descriptions.count,
            vertex_input_binding_descriptions.data,
            vertex_input_attribute_descriptions.count,
            vertex_input_attribute_descriptions.data,
        );
    }
}

u64_min, u64_max :: #run get_integer_range(u64);

draw_frame :: () {
    result : VkResult;

    frame_index += 1;
    index := frame_index % FRAMES_IN_FLIGHT;

    {
        using semaphore_wait_info : VkSemaphoreWaitInfo;

        semaphoreCount = 1;
        pSemaphores = *timeline_semaphore;
        // @TODO: First two frames?
        pValues = u64.[ifx frame_index > 2 then cast(u64, frame_index - 2) else 0].data;

        result = vkWaitSemaphores(device, *semaphore_wait_info, u64_max);
        assert(result == .SUCCESS);
    }
    // @TODO: Wait for the frame from FRAMES_IN_FLIGHT ago to be finished.
    // This means wait for the timeline semaphore to hit frame_index - 2.

    image_index: u32;
    result = vkAcquireNextImageKHR(device, swapchain_context.swapchain, u64_max, image_available_semaphores[index], VK_NULL_HANDLE, *image_index);
    assert(result == .SUCCESS);

    {
        using beginInfo: VkCommandBufferBeginInfo;
        flags = .ONE_TIME_SUBMIT;
        result = vkBeginCommandBuffer(command_buffers[index], *beginInfo);
        assert(result == .SUCCESS);
    }

    {
        swapchain_image_subresource_range : VkImageSubresourceRange;
        {
            using swapchain_image_subresource_range;
            aspectMask     = .COLOR;
            baseMipLevel   = 0;
            levelCount     = VK_REMAINING_MIP_LEVELS;
            baseArrayLayer = 0;
            layerCount     = VK_REMAINING_ARRAY_LAYERS;
        }

        {
            image_memory_barrier : VkImageMemoryBarrier;
            {
                using image_memory_barrier;
                srcAccessMask       = 0;
                dstAccessMask       = .TRANSFER_WRITE;
                oldLayout           = .UNDEFINED;
                newLayout           = .GENERAL;
                srcQueueFamilyIndex = xx physical_device_context.queue_family_indices.graphics;
                dstQueueFamilyIndex = xx physical_device_context.queue_family_indices.graphics;
                image               = swapchain_context.images[image_index];
                subresourceRange    = swapchain_image_subresource_range;
            }

            vkCmdPipelineBarrier(command_buffers[index], .TRANSFER, .TRANSFER, 
                                 0, 0, null, 0, null, 1, *image_memory_barrier);
        }

        color_attachment : VkRenderingAttachmentInfoKHR;
        {
            using color_attachment;
            imageView = swapchain_context.views[image_index];
            imageLayout = .GENERAL;
            loadOp = .CLEAR;
            storeOp = .STORE;
        }

        {
            using rendering_info : VkRenderingInfo;
            renderArea = VkRect2D.{
                offset = .{0, 0},
                extent = swapchain_context.extent,
            };
            layerCount = 1;
            viewMask = 0;
            colorAttachmentCount = 1;
            pColorAttachments = *color_attachment;
            pDepthAttachment = null;
            pStencilAttachment = null;

            vkCmdBeginRendering(command_buffers[index], *rendering_info);
        }

        // Set up my dynamic state
        bind_descriptor_heaps(command_buffers[index]);
        set_draw_state(command_buffers[index]);

        // Clear frame
        {
            clear_color : VkClearColorValue;
            {
                color1 := Vector4.{1,  1, 0, 1};
                color2 := Vector4.{.5, 0, 1, 1};

                now := seconds_since_init();
                t := cos(cast(float) now) * .5 + .5;
                Clamp(*t, 0, 1);
                color := lerp(color1, color2, t);
                clear_color.float32_ = color.component;
            }

            clear_attachments : [1] VkClearAttachment;
            {
                {
                    using clear_attachments[0];
                    aspectMask = .COLOR;
                    colorAttachment = 0;
                    clearValue.color = clear_color;
                }
            }

            clear_rects : [1] VkClearRect;
            {
                {
                    using clear_rects[0];
                    rect = .{
                        offset = .{0, 0},
                        extent = swapchain_context.extent,
                    };
                    baseArrayLayer = 0;
                    layerCount = 1;
                }
            }

            vkCmdClearAttachments(command_buffers[index],
                clear_attachments.count, clear_attachments.data,
                clear_rects.count, clear_rects.data
            );
        }

        // Bind Shaders
        {
            stages := VkShaderStageFlagBits.[
                .VERTEX,
                .FRAGMENT,
            ];

            vkCmdBindShadersEXT(
                command_buffers[index],
                stages.count, stages.data, shaders.data
            );
        }

        // Push Descriptor Data
        {
            // For combined image/samplers, the 12 MSB contain the sampler id, while the remaining contain the image id.
            data : u32 = (first_image_id & 0xFFFFF) | (first_sampler_id << 20);
            push_data_info : VkPushDataInfoEXT;
            {
                using push_data_info;
                offset = 0;
                data = .{
                    address = *data,
                    size = size_of(u32),
                };
            }
        }

        // Bind Data
        {
            offsets : [1] VkDeviceSize;
            {
                offsets[0] = 0;
            }

            vkCmdBindVertexBuffers(
                command_buffers[index],
                0,
                1,
                *vertex_buffer,
                offsets.data,
            );
        }

        vkCmdDraw(
            command_buffers[index],
            vertexCount = 3,
            instanceCount = 1,
            firstVertex = 0,
            firstInstance = 0
        );

        vkCmdEndRendering(command_buffers[index]);

        {
            using imgMemoryBarrier : VkImageMemoryBarrier;
            srcAccessMask       = .TRANSFER_WRITE;
            dstAccessMask       = .MEMORY_READ;
            oldLayout           = .GENERAL;
            newLayout           = .PRESENT_SRC_KHR;
            srcQueueFamilyIndex = xx physical_device_context.queue_family_indices.graphics;
            dstQueueFamilyIndex = xx physical_device_context.queue_family_indices.graphics;
            image               = swapchain_context.images[image_index];
            subresourceRange    = swapchain_image_subresource_range;

            vkCmdPipelineBarrier(command_buffers[index], .TRANSFER, .BOTTOM_OF_PIPE,
                0, 0, null, 0, null, 1, *imgMemoryBarrier);
        }
    }

    result = vkEndCommandBuffer(command_buffers[index]);
    assert(result == .SUCCESS);

    {
        // Wait at the Color Attachment Output stage so the GPU can do vertex work before the image is fully acquired.
        wait_image_info : VkSemaphoreSubmitInfo;
        {
            using wait_image_info;
            semaphore = image_available_semaphores[index];
            value = 0; // binary.
            stageMask = .COLOR_ATTACHMENT_OUTPUT;
        }

        // Signal this when the Color Attachment Output stage finishes.
        signal_present_info : VkSemaphoreSubmitInfo;
        {
            using signal_present_info;
            semaphore = present_ready_semaphores[image_index];
            value = 0; // binary.
            stageMask = .COLOR_ATTACHMENT_OUTPUT;
        }

        // Signal the timeline when all commands have finished.
        signal_timeline_info : VkSemaphoreSubmitInfo;
        {
            using signal_timeline_info;
            semaphore = timeline_semaphore;
            value = frame_index;
            stageMask = .ALL_COMMANDS;
        };

        signal_infos := VkSemaphoreSubmitInfo.[signal_present_info, signal_timeline_info];

        command_buffer_info : VkCommandBufferSubmitInfo;
        {
            using command_buffer_info;
            commandBuffer = command_buffers[index];
        }

        submit_info_2: VkSubmitInfo2;
        {
            using submit_info_2;
            waitSemaphoreInfoCount = 1;
            pWaitSemaphoreInfos = *wait_image_info;
            commandBufferInfoCount = 1;
            pCommandBufferInfos = *command_buffer_info;
            signalSemaphoreInfoCount = 2;
            pSignalSemaphoreInfos = signal_infos.data;
        }

        result = vkQueueSubmit2(queue, 1, *submit_info_2, VK_NULL_HANDLE);
        assert(result == .SUCCESS);
    }

    {
        using present_info: VkPresentInfoKHR;
        waitSemaphoreCount = 1;
        pWaitSemaphores    = *present_ready_semaphores[image_index];
        swapchainCount     = 1;
        pSwapchains        = *swapchain_context.swapchain;
        pImageIndices      = *image_index;

        result = vkQueuePresentKHR(queue, *present_info);
        assert(result == .SUCCESS);
    }
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

////////////////////////////////////////////////////////////////////////////////

textures_path   :: "assets/textures";
models_path     :: "assets/models";

textures_to_load :: string.[
    "croc"
];

models_to_load :: string.[
];
