
DEBUG :: true;

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
        command_pool : VkCommandPool;
        timeline_semaphore : VkSemaphore;
        command_buffers             : [FRAMES_IN_FLIGHT] VkCommandBuffer;
        image_available_semaphores  : [FRAMES_IN_FLIGHT] VkSemaphore;
        present_ready_semaphores    : [swapchain_context.MAX_SWAPCHAIN_IMAGES] VkSemaphore;
    }

    using data : struct {
        uniform_buffer          : VkBuffer;
        vertex_buffer           : VkBuffer;

        descriptor_set_layouts  : [1] VkDescriptorSetLayout;
        pipeline_layout         : VkPipelineLayout;
        descriptor_sets         : [1] VkDescriptorSet;

        shaders                 : [2] VkShaderEXT;
    }
}

Vertex :: struct {
    position    : Vector3;
    color       : Vector3;
}

vertices := Vertex.[
    .{position = .{ 0.0, -0.5,  0.0}, color = .{1, 0, 0}},
    .{position = .{ 0.5,  0.5,  0.0}, color = .{0, 1, 0}},
    .{position = .{-0.5,  0.5,  0.0}, color = .{0, 0, 1}},
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

    init_swapchain();
    defer deinit_swapchain();

    result : VkResult;

    // Descriptor Sets
    {
        // Descriptor Set Layouts
        {
            using descriptor_set_layouts[0];
            layout := *descriptor_set_layouts[0];

            bindings : [2] VkDescriptorSetLayoutBinding;
            {
                {
                    using bindings[0];
                    binding = 0;
                    descriptorType = .UNIFORM_BUFFER;
                    descriptorCount = 1;
                    stageFlags = .VERTEX;
                }

                {
                    using bindings[1];
                    binding = 0;
                    descriptorType = .UNIFORM_BUFFER;
                    descriptorCount = 0;
                    stageFlags = .FRAGMENT;
                }
            }

            {
                using create_info : VkDescriptorSetLayoutCreateInfo;
                flags = 0;
                bindingCount = 1;
                pBindings = bindings.data;

                result = vkCreateDescriptorSetLayout(device, *create_info, null, layout);
                assert(result == .SUCCESS);
            }
        }

        // Pipeline Layout
        {
            using create_info : VkPipelineLayoutCreateInfo;
            setLayoutCount = descriptor_set_layouts.count;
            pSetLayouts = descriptor_set_layouts.data;
            pushConstantRangeCount = 0;
            pPushConstantRanges = null;

            result = vkCreatePipelineLayout(device, *create_info, null, *pipeline_layout);
            assert(result == .SUCCESS);
        }

        descriptor_pool : VkDescriptorPool;
        {
            pool_sizes : [1] VkDescriptorPoolSize;
            {
                {
                    using pool_sizes[0];
                    type = .UNIFORM_BUFFER;
                    descriptorCount = 100;
                }
            }

            {
                using create_info : VkDescriptorPoolCreateInfo;
                poolSizeCount = pool_sizes.count;
                pPoolSizes = pool_sizes.data;
                maxSets = 100;

                vkCreateDescriptorPool(device, *create_info, null, *descriptor_pool);
            }
        }

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

                memory_requirements : VkMemoryRequirements;
                vkGetBufferMemoryRequirements(device, vertex_buffer, *memory_requirements);

                device_memory : VkDeviceMemory;
                {
                    // @TODO: A more fully-featured way to specify what memory type you want things out of.
                    memory_type_index := get_host_visible_memory_type(physical_device_context.memory_properties);
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

        // Descriptor Sets
        {
            {
                using descriptor_sets[0];
                set := *descriptor_sets[0];

                // Allocate
                {
                    using allocation_info : VkDescriptorSetAllocateInfo;
                    descriptorPool = descriptor_pool;
                    descriptorSetCount = descriptor_set_layouts.count;
                    pSetLayouts = descriptor_set_layouts.data;

                    result = vkAllocateDescriptorSets(device, *allocation_info, set);
                    assert(result == .SUCCESS);
                }

                // Update
                {
                    write_descriptor_sets : [1] VkWriteDescriptorSet;
                    {
                        {
                            using write_descriptor_sets[0];

                            descriptor_buffer_info : VkDescriptorBufferInfo;
                            {
                                using descriptor_buffer_info;
                                buffer = uniform_buffer;
                                offset = 0;
                                range = VK_WHOLE_SIZE;
                            }

                            dstSet = set.*;
                            dstBinding = 0;
                            dstArrayElement = 0;
                            descriptorCount = 1;
                            descriptorType = .UNIFORM_BUFFER;
                            pBufferInfo = *descriptor_buffer_info;
                        }
                    }
                    vkUpdateDescriptorSets(device, write_descriptor_sets.count, write_descriptor_sets.data, 0, null);
                }
            }
        }
    }

    // Shader Objects
    {
        // Read spirv from file
        spirv : [2] string;
        {
            shader_file_path := tprint("%/%", compiled_shaders_directory, "debug-vertex.spv");

            success : bool;
            spirv[0], success = read_entire_file(shader_file_path);
            assert(success, "Unable to read shader file %", shader_file_path);
        }

        {
            shader_file_path := tprint("%/%", compiled_shaders_directory, "debug-fragment.spv");

            success : bool;
            spirv[1], success = read_entire_file(shader_file_path);
            assert(success, "Unable to read shader file %", shader_file_path);
        }

        // Shader Object Create Infos
        {
            shader_create_infos : [2] VkShaderCreateInfoEXT;

            {
                using shader_create_infos[0];
                flags = .LINK_STAGE;

                stage       = .VERTEX;
                nextStage   = .FRAGMENT;

                codeType    = .SPIRV;
                codeSize    = xx spirv[0].count;
                pCode       = spirv[0].data;

                pName       = "main";

                setLayoutCount = descriptor_set_layouts.count;
                pSetLayouts = descriptor_set_layouts.data;

                pushConstantRangeCount = 0;
                pPushConstantRanges = null;
                pSpecializationInfo = null;
            }

            {
                using shader_create_infos[1];
                flags = .LINK_STAGE;

                stage       = .FRAGMENT;
                nextStage   = 0;

                codeType    = .SPIRV;
                codeSize    = xx spirv[1].count;
                pCode       = spirv[1].data;

                pName       = "main";

                setLayoutCount = descriptor_set_layouts.count;
                pSetLayouts = descriptor_set_layouts.data;

                pushConstantRangeCount = 0;
                pPushConstantRanges = null;
                pSpecializationInfo = null;
            }

            result = vkCreateShadersEXT(device,
                shader_create_infos.count, shader_create_infos.data,
                null,
                shaders.data
            );

            if (result != .SUCCESS)
            {
                log("fuck!");
            }
        }
    }

    init_render();
    defer deinit_render();

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

        #if DEBUG {
            array_add(*instance_extensions, VK_EXT_DEBUG_REPORT_EXTENSION_NAME.data);
        }

        enabledExtensionCount   = xx instance_extensions.count;
        ppEnabledExtensionNames = instance_extensions.data;

        enabled_layers: [..] *u8;

        #if DEBUG {
            array_add(*enabled_layers, "VK_LAYER_KHRONOS_validation");
        }

        enabledLayerCount = xx enabled_layers.count;
        ppEnabledLayerNames = enabled_layers.data;

        result = vkCreateInstance(*instance_create_info, null, *instance);
        assert(result == .SUCCESS);
    }

    #if DEBUG {
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
    #if DEBUG {
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
            array_add(*device_extensions, VK_KHR_UNIFIED_IMAGE_LAYOUTS_EXTENSION_NAME.data);

            enabledExtensionCount   = xx device_extensions.count;
            ppEnabledExtensionNames = device_extensions.data;

            // Enabled Features
            unified_image_layout_features := VkPhysicalDeviceUnifiedImageLayoutsFeaturesKHR.{unifiedImageLayouts = VK_TRUE, pNext = null};
            shader_object_features := VkPhysicalDeviceShaderObjectFeaturesEXT.{shaderObject = VK_TRUE, pNext = *unified_image_layout_features};

            vulkan_1_4_features := VkPhysicalDeviceVulkan14Features.{pNext = *shader_object_features};

            vulkan_1_3_features := VkPhysicalDeviceVulkan13Features.{pNext = *vulkan_1_4_features};
            {
                using vulkan_1_3_features;
                dynamicRendering = VK_TRUE;
                synchronization2 = VK_TRUE;
            }

            vulkan_1_2_features := VkPhysicalDeviceVulkan12Features.{pNext = *vulkan_1_3_features};
            {
                using vulkan_1_2_features;
                timelineSemaphore = VK_TRUE;
            }

            vulkan_1_1_features := VkPhysicalDeviceVulkan11Features.{pNext = *vulkan_1_2_features};
            {
                using vulkan_1_1_features;
            }

            features2 : VkPhysicalDeviceFeatures2;
            vkGetPhysicalDeviceFeatures2(physical_device, *features2);
            features2.pNext = *vulkan_1_1_features;

            features2.features.geometryShader = VK_FALSE;
            features2.features.tessellationShader = VK_FALSE;

            pNext = *features2;

            result = vkCreateDevice(physical_device, *device_create_info, null, *device);
            assert(result == .SUCCESS);
        }
    }
}

deinit_device :: () {
    vkDestroyDevice(device, null);
}


init_swapchain :: () {
    result : VkResult;
    using physical_device_context;

    // Use first available format
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

    chosen_present_mode : VkPresentModeKHR = .FIFO;   // always supported.
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

    {
        {
            using semaphore_create_info: VkSemaphoreCreateInfo;
            for image_index : 0..swapchain_context.image_count-1 {
                vkCreateSemaphore(device, *semaphore_create_info, null, *present_ready_semaphores[image_index]);
            }
            for index : 0..FRAMES_IN_FLIGHT-1 {
                vkCreateSemaphore(device, *semaphore_create_info, null, *image_available_semaphores[index]);
            }
        }

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

set_draw_state :: (index: u64) {
    vkCmdSetRasterizerDiscardEnable(command_buffers[index], VK_FALSE);
    vkCmdSetPrimitiveRestartEnable(command_buffers[index],  VK_FALSE);

    vkCmdSetPrimitiveTopology(command_buffers[index],       .TRIANGLE_LIST);

    vkCmdSetDepthTestEnable(command_buffers[index],         VK_FALSE);
    vkCmdSetDepthWriteEnable(command_buffers[index],        VK_FALSE);
    vkCmdSetDepthBiasEnable(command_buffers[index],         VK_FALSE);
    vkCmdSetDepthBoundsTestEnable(command_buffers[index],   VK_FALSE);
    vkCmdSetDepthClampEnableEXT(command_buffers[index],     VK_FALSE);

    vkCmdSetStencilTestEnable(command_buffers[index],       VK_FALSE);

    vkCmdSetPolygonModeEXT(command_buffers[index],          .FILL);
    vkCmdSetFrontFace(command_buffers[index],               .CLOCKWISE);
    vkCmdSetCullMode(command_buffers[index],                .BACK);

    vkCmdSetAlphaToOneEnableEXT(command_buffers[index],     VK_FALSE);
    vkCmdSetAlphaToCoverageEnableEXT(command_buffers[index],VK_FALSE);
    vkCmdSetLogicOpEnableEXT(command_buffers[index],        VK_FALSE);

    color_blend_enables : [1] VkBool32;
    {
        color_blend_enables[0] = VK_FALSE;
    }

    vkCmdSetColorBlendEnableEXT(command_buffers[index],
        firstAttachment = 0,
        attachmentCount = color_blend_enables.count,
        pColorBlendEnables = color_blend_enables.data,
    );

    color_write_masks : [1] VkColorComponentFlags;
    {
        color_write_masks[0] = .R | .G | .B | .A;
    }
    vkCmdSetColorWriteMaskEXT(command_buffers[index],
        firstAttachment = 0,
        attachmentCount = color_write_masks.count,
        pColorWriteMasks = color_write_masks.data
    );

    vkCmdSetRasterizationSamplesEXT(command_buffers[index], .e1);
    sample_mask : VkSampleMask = 1;
    vkCmdSetSampleMaskEXT(command_buffers[index], .e1, *sample_mask);


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
        vkCmdSetViewportWithCount(command_buffers[index], viewports.count, viewports.data);
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
        vkCmdSetScissorWithCount(command_buffers[index], scissors.count, scissors.data);
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

        vertex_input_attribute_descriptions : [2] VkVertexInputAttributeDescription2EXT;
        {
            // Position
            {
                using vertex_input_attribute_descriptions[0];
                location    = 0;
                binding     = 0;
                format      = .R32G32B32_SFLOAT;
                offset      = offset_of(Vertex, "position");
            }

            // Color
            {
                using vertex_input_attribute_descriptions[1];
                location    = 1;
                binding     = 0;
                format      = .R32G32B32_SFLOAT;
                offset      = offset_of(Vertex, "color");
            }
        }

        vkCmdSetVertexInputEXT(
            command_buffers[index],
            vertex_input_binding_descriptions.count,
            vertex_input_binding_descriptions.data,
            vertex_input_attribute_descriptions.count,
            vertex_input_attribute_descriptions.data,
        );
    }
}

u64_low, u64_high :: #run get_integer_range(u64);

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

        result = vkWaitSemaphores(device, *semaphore_wait_info, u64_high);
        assert(result == .SUCCESS);
    }
    // @TODO: Wait for the frame from FRAMES_IN_FLIGHT ago to be finished.
    // This means wait for the timeline semaphore to hit frame_index - 2.

    image_index: u32;
    result = vkAcquireNextImageKHR(device, swapchain_context.swapchain, u64_high, image_available_semaphores[index], VK_NULL_HANDLE, *image_index);
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
        set_draw_state(index);

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

        // Bind Descriptor Sets
        {
            dynamic_offsets : [0] u32;
            {
            }

            vkCmdBindDescriptorSets(
                command_buffers[index],
                pipelineBindPoint = .GRAPHICS,
                layout = pipeline_layout,
                firstSet = 0,
                descriptorSetCount = descriptor_sets.count,
                pDescriptorSets = descriptor_sets.data,
                dynamicOffsetCount = dynamic_offsets.count,
                pDynamicOffsets = dynamic_offsets.data
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

#import "System";
#if OS == .WINDOWS {
    #import "Windows";
}

////////////////////////////////////////////////////////////////////////////////

#load "utils.jai";
