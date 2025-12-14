
// Main

////////////////////////////////////////////////////////////////////////////////

DEBUG :: true;

program_state : struct {
    window_width    : u32 = 2560;
    window_height   : u32 = 1440;

    window          : Window_Type;
}

instance                : VkInstance;
debug_callback_handle   : VkDebugReportCallbackEXT;

surface                 : VkSurfaceKHR;

physical_device         : VkPhysicalDevice;
queue_family_index      : u32;
memory_properties       : VkPhysicalDeviceMemoryProperties;

device                  : VkDevice;
queue                   : VkQueue;

uniform_buffer          : VkBuffer;
vertex_buffer           : VkBuffer;

descriptor_set_layouts  : [1] VkDescriptorSetLayout;
pipeline_layout         : VkPipelineLayout;
descriptor_sets         : [1] VkDescriptorSet;

shaders                 : [2] VkShaderEXT;

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

    // Create window
    program_state.window = create_window(
        xx program_state.window_width, xx program_state.window_height,
        program_title,
        window_x = 1080,
        window_y = 0,
    );

    #if OS == .WINDOWS {
        vulkan_library := LoadLibraryA("vulkan-1.dll");
        assert(vulkan_library != null, "Unable to find vulkan-1.dll.");
    }

    vkGIPA := GetProcAddress(vulkan_library, "vkGetInstanceProcAddr");
    vk_load_global_functions(vkGIPA);
  
    //print_available_vulkan_extensions();

    if !init_instance() {
        print("Instance initialization failed.\n");
        return;
    }
    defer deinit_instance();

    vk_load_instance_functions(instance);

    if !init_surface() {
        print("Window surface creation failed.\n");
        return;
    }
    defer deinit_surface();

    if !init_device() {
        print("Device initialization failed.\n");
        return;
    }
    defer deinit_device();

    vk_load_device_functions(device);

    vkGetDeviceQueue(device, queue_family_index, queueIndex=0, *queue);

    if !init_swapchain() {
        print("Swapchain initialization failed.\n");
        return;
    }
    defer deinit_swapchain();


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

            create_info : VkDescriptorSetLayoutCreateInfo;
            {
                using create_info;
                flags = 0;
                bindingCount = 1;
                pBindings = bindings.data;
            }

            result := vkCreateDescriptorSetLayout(device, *create_info, null, layout);
            assert(result == .SUCCESS);
        }

        // Pipeline Layout
        {
            create_info : VkPipelineLayoutCreateInfo;
            {
                using create_info;
                setLayoutCount = descriptor_set_layouts.count;
                pSetLayouts = descriptor_set_layouts.data;
                pushConstantRangeCount = 0;
                pPushConstantRanges = null;
            }

            result := vkCreatePipelineLayout(device, *create_info, null, *pipeline_layout);
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

            create_info : VkDescriptorPoolCreateInfo;
            {
                using create_info;
                poolSizeCount = pool_sizes.count;
                pPoolSizes = pool_sizes.data;
                maxSets = 100;
            }

            vkCreateDescriptorPool(device, *create_info, null, *descriptor_pool);
        }

        // Data
        {
            // Vertex Buffer
            {
                create_info : VkBufferCreateInfo;
                {
                    using create_info;
                    size = size_of(type_of(vertices));
                    usage = .VERTEX_BUFFER;
                }

                vkCreateBuffer(device, *create_info, null, *vertex_buffer);

                device_memory : VkDeviceMemory;
                {
                    allocate_info : VkMemoryAllocateInfo;
                    {
                        using allocate_info;
                        allocationSize = size_of(type_of(vertices));
                        memoryTypeIndex = 1;
                    }

                    vkAllocateMemory(device, *allocate_info, null, *device_memory);
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

                // Bind
                {
                    vkBindBufferMemory(
                        device,
                        vertex_buffer,
                        device_memory,
                        0
                    );
                }
            }


            // Uniform Buffer
            {
                create_info : VkBufferCreateInfo;
                {
                    using create_info;
                    size = 16 * size_of(float);
                    usage = .UNIFORM_BUFFER;
                }

                vkCreateBuffer(device, *create_info, null, *uniform_buffer);

                device_memory : VkDeviceMemory;
                {
                    allocate_info : VkMemoryAllocateInfo;
                    {
                        using allocate_info;
                        allocationSize = 16 * size_of(float);
                        memoryTypeIndex = 0;
                    }

                    vkAllocateMemory(device, *allocate_info, null, *device_memory);
                }

                {
                    vkBindBufferMemory(
                        device,
                        uniform_buffer,
                        device_memory,
                        0
                    );
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
                    allocation_info : VkDescriptorSetAllocateInfo;
                    {
                        using allocation_info;
                        descriptorPool = descriptor_pool;
                        descriptorSetCount = descriptor_set_layouts.count;
                        pSetLayouts = descriptor_set_layouts.data;
                    }

                    result := vkAllocateDescriptorSets(device, *allocation_info, set);
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

                    vkUpdateDescriptorSets(device,
                        write_descriptor_sets.count,
                        write_descriptor_sets.data,
                        0,
                        null
                    );
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

            result := vkCreateShadersEXT(device,
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
}

init_instance :: () -> bool {
    result : VkResult = .ERROR_INITIALIZATION_FAILED;
    
    // Application Info
    app_info: VkApplicationInfo;
    app_info.pApplicationName   = program_title.data;
    app_info.applicationVersion = VK_MAKE_VERSION(1, 4, 0);
    app_info.pEngineName        = program_title.data;
    app_info.engineVersion      = VK_MAKE_VERSION(1, 4, 0);
    app_info.apiVersion         = VK_API_VERSION_1_4;

    // Create Vulkan Instance
    create_info : VkInstanceCreateInfo;
    create_info.pApplicationInfo        = *app_info;

    #if !DEBUG {
        extensions: [2] *u8;
        extensions[0] = VK_KHR_SURFACE_EXTENSION_NAME.data;
        // @ToDo: Non-Windows version
        extensions[1] = VK_KHR_WIN32_SURFACE_EXTENSION_NAME.data;
    } else {
        #if OS == .WINDOWS {
            extensions: [3] *u8;
            extensions[0] = VK_KHR_SURFACE_EXTENSION_NAME.data;
            extensions[1] = VK_KHR_WIN32_SURFACE_EXTENSION_NAME.data;
            extensions[2] = VK_EXT_DEBUG_REPORT_EXTENSION_NAME.data;
        } else {
            extensions: [0] *u8;
            // @ToDo: Non-Windows version
            #assert(false);
        }
    }

    create_info.enabledExtensionCount   = extensions.count;
    create_info.ppEnabledExtensionNames = extensions.data;

    #if DEBUG {
        enabled_layers: [..] *u8;
        {
            array_add(*enabled_layers, "VK_LAYER_KHRONOS_validation");
        }

        debug_create_info := create_info;
        debug_create_info.enabledLayerCount = xx enabled_layers.count;
        debug_create_info.ppEnabledLayerNames = enabled_layers.data;

        result = vkCreateInstance(*debug_create_info, null, *instance);
        if result == .SUCCESS {
            vkCreateDebugReportCallbackEXT  : PFN_vkCreateDebugReportCallbackEXT = xx vkGetInstanceProcAddr(instance, "vkCreateDebugReportCallbackEXT");
            vkDestroyDebugReportCallbackEXT = xx vkGetInstanceProcAddr(instance, "vkDestroyDebugReportCallbackEXT");
            vkDebugReportMessageEXT         : PFN_vkDebugReportMessageEXT = xx vkGetInstanceProcAddr(instance, "vkDebugReportMessageEXT");

            if vkCreateDebugReportCallbackEXT {
                debug_callback_create_info: VkDebugReportCallbackCreateInfoEXT;
                debug_callback_create_info.flags |= .ERROR;
                debug_callback_create_info.flags |= .WARNING;
                debug_callback_create_info.pfnCallback = debug_callback;
                debug_callback_create_info.pUserData = xx *context;

                vkCreateDebugReportCallbackEXT(instance, *debug_callback_create_info, null, *debug_callback_handle);
            }
        }
    }

    if result != .SUCCESS {
        log("Hey, just a heads up, we're not able to do the debug instance, so we're just making a normal one.");
        result = vkCreateInstance(*create_info, null, *instance);
    }

    return result == .SUCCESS;
}


deinit_instance :: () {
    #if DEBUG {
        if vkDestroyDebugReportCallbackEXT && debug_callback_handle {
            vkDestroyDebugReportCallbackEXT(instance, debug_callback_handle, null);
        }
    }
    vkDestroyInstance(instance, null);
}

init_surface :: () -> bool {
    #if OS == .WINDOWS {
        my_hwnd := program_state.window;
        surfaceCreateInfo: VkWin32SurfaceCreateInfoKHR; 
        surfaceCreateInfo.hinstance = GetModuleHandleW(null);
        surfaceCreateInfo.hwnd      = my_hwnd;
        result := vkCreateWin32SurfaceKHR(instance, *surfaceCreateInfo, null, *surface);
        return result == .SUCCESS;
    } else {
        // @TODO: Other platforms
        #assert(false);
        return false;
    }
}

deinit_surface :: () {
    vkDestroySurfaceKHR(instance, surface, null);
}

init_device :: () -> bool {
    // Picking physical device
    //
    MAX_DEVICE_COUNT :: 8;
    MAX_QUEUE_COUNT  :: 4; // ATM there should be at most transfer, graphics, compute, graphics+compute families

    device_handles         : [MAX_DEVICE_COUNT] VkPhysicalDevice;
    queue_family_properties: [MAX_QUEUE_COUNT] VkQueueFamilyProperties;
    physical_device_count  : u32;

    vkEnumeratePhysicalDevices(instance, *physical_device_count, null);
    physical_device_count = min(physical_device_count, MAX_DEVICE_COUNT);
    vkEnumeratePhysicalDevices(instance, *physical_device_count, device_handles.data);

    print("Physical device count: %\n", physical_device_count);

    for i: 0..physical_device_count-1 {
        queue_family_count: u32 = 0;
        vkGetPhysicalDeviceQueueFamilyProperties(device_handles[i], *queue_family_count, null);
        queue_family_count = min(queue_family_count, MAX_QUEUE_COUNT);
        vkGetPhysicalDeviceQueueFamilyProperties(device_handles[i], *queue_family_count, queue_family_properties.data);

        print("Physical device % supports % queues families.\n", i, queue_family_count);

        for j: 0..queue_family_count-1 {
            supports_present := VK_FALSE;
            vkGetPhysicalDeviceSurfaceSupportKHR(device_handles[i], j, surface, *supports_present);

            print("Queue family properites: %.\n", queue_family_properties[j]);

            if supports_present && (queue_family_properties[j].queueFlags & .GRAPHICS) {
                queue_family_index = j;
                physical_device = device_handles[i];
                print("Queue family % supports present and graphics.\n", j);
                break;
            }
        }

        if (physical_device) {
            break;
        }
    }

    vkGetPhysicalDeviceMemoryProperties(physical_device, *memory_properties);
    {
        using memory_properties;
        log("Physical Device Memory");
        for 0..memoryTypeCount-1 {
            log("%", memoryTypes[it]);
        }
    }

    // Logical device
    queue_create_info: VkDeviceQueueCreateInfo;
    queue_create_info.queueFamilyIndex = queue_family_index;
    queue_create_info.queueCount = 1;
    queue_create_info.pQueuePriorities = float.[1.0].data;

    device_create_info: VkDeviceCreateInfo;
    {
        using device_create_info;

        queueCreateInfoCount    = 1;
        pQueueCreateInfos       = *queue_create_info;

        // Device Layers don't exist...
        {
            enabledLayerCount       = 0;
            ppEnabledLayerNames     = null;
        }

        // Device Extensions
        {
            device_extensions: [..] *u8;
            {
                array_add(*device_extensions, VK_KHR_SWAPCHAIN_EXTENSION_NAME.data);
                array_add(*device_extensions, VK_EXT_SHADER_OBJECT_EXTENSION_NAME.data);
                array_add(*device_extensions, VK_KHR_DYNAMIC_RENDERING_EXTENSION_NAME.data);
            }

            enabledExtensionCount   = xx device_extensions.count;
            ppEnabledExtensionNames = device_extensions.data;
        }

        // Enabled Features
        {
            last_feature : *void;
            {
                dynamic_rendering_features : VkPhysicalDeviceDynamicRenderingFeatures;
                {
                    using dynamic_rendering_features;
                    dynamicRendering = VK_TRUE;
                    pNext = null;
                }

                shader_object_features : VkPhysicalDeviceShaderObjectFeaturesEXT;
                {
                    using shader_object_features;
                    shaderObject = VK_TRUE;
                    pNext = *dynamic_rendering_features;
                }

                last_feature = *shader_object_features;
            }

            features2 : VkPhysicalDeviceFeatures2;
            vkGetPhysicalDeviceFeatures2(physical_device, *features2);
            features2.pNext = last_feature;

            pNext = *features2;
        }
    }
    
    result := vkCreateDevice(physical_device, *device_create_info, null, *device);
    return result == .SUCCESS;
}

deinit_device :: () {
    vkDestroyDevice(device, null);
}


MAX_PRESENT_MODE_COUNT :: 6; // At the moment in spec
MAX_SWAPCHAIN_IMAGES   :: 3;
swapchain: VkSwapchainKHR;
swapchainImageCount: u32;
swapchainImages     : [MAX_SWAPCHAIN_IMAGES] VkImage;
swapchainImageViews : [MAX_SWAPCHAIN_IMAGES] VkImageView;
swapchain_extent    : VkExtent2D;
surfaceFormat       : VkSurfaceFormatKHR;

init_swapchain :: () -> bool {
    PRESENT_MODE_MAILBOX_IMAGE_COUNT :u32: 3;
    PRESENT_MODE_DEFAULT_IMAGE_COUNT :u32: 2;

    // Use first available format
    formatCount : u32 = 1;
    vkGetPhysicalDeviceSurfaceFormatsKHR(physical_device, surface, *formatCount, null); // suppress validation layer
    vkGetPhysicalDeviceSurfaceFormatsKHR(physical_device, surface, *formatCount, *surfaceFormat);
    surfaceFormat.format = ifx surfaceFormat.format == .UNDEFINED then .B8G8R8A8_UNORM else surfaceFormat.format;

    presentModeCount : u32 = 0;
    vkGetPhysicalDeviceSurfacePresentModesKHR(physical_device, surface, *presentModeCount, null);
    presentModes: [MAX_PRESENT_MODE_COUNT]VkPresentModeKHR;
    presentModeCount = min(presentModeCount, MAX_PRESENT_MODE_COUNT);
    vkGetPhysicalDeviceSurfacePresentModesKHR(physical_device, surface, *presentModeCount, presentModes.data);

    presentMode : VkPresentModeKHR = .FIFO;   // always supported.
    for 0..presentModeCount-1 {
        if presentModes[it] == .MAILBOX {
            presentMode = .MAILBOX;
            break;
        }
    }
    
    swapchainImageCount = ifx presentMode == .MAILBOX  then PRESENT_MODE_MAILBOX_IMAGE_COUNT else  PRESENT_MODE_DEFAULT_IMAGE_COUNT;

    surfaceCapabilities: VkSurfaceCapabilitiesKHR;
    vkGetPhysicalDeviceSurfaceCapabilitiesKHR(physical_device, surface, *surfaceCapabilities);

    swapchain_extent = surfaceCapabilities.currentExtent;
    if swapchain_extent.width == U32_MAX {
        swapchain_extent.width  = clamp(
            program_state.window_width,
            surfaceCapabilities.minImageExtent.width,
            surfaceCapabilities.maxImageExtent.width
        );
        swapchain_extent.height = clamp(
            program_state.window_height,
            surfaceCapabilities.minImageExtent.height,
            surfaceCapabilities.maxImageExtent.height
        );
    }

    swapChainCreateInfo: VkSwapchainCreateInfoKHR;
    the_surface := surface;  // No way yet to avoid importing this with 'using'. Should fix that!
    {
        swapChainCreateInfo.surface = the_surface;

        using swapChainCreateInfo;
        minImageCount               = swapchainImageCount;
        imageFormat                 = surfaceFormat.format;
        imageColorSpace             = surfaceFormat.colorSpace;
        imageExtent                 = swapchain_extent;
        imageArrayLayers            = 1; // 2 for stereo
        imageUsage                  |= .COLOR_ATTACHMENT;
        imageUsage                  |=  .TRANSFER_DST;
        imageSharingMode            = .EXCLUSIVE;
        preTransform                = surfaceCapabilities.currentTransform;
        compositeAlpha              = .OPAQUE;
        presentMode                 = presentMode;
        clipped                     = VK_TRUE;
    }
    
    result := vkCreateSwapchainKHR(device, *swapChainCreateInfo, null, *swapchain);
    if result != .SUCCESS {
        return false;
    }

    vkGetSwapchainImagesKHR(device, swapchain, *swapchainImageCount, null);
    vkGetSwapchainImagesKHR(device, swapchain, *swapchainImageCount, swapchainImages.data);

    // Create image views of all swapchain images
    {
        for 0..swapchainImageCount-1 {
            create_info : VkImageViewCreateInfo;

            {
                using create_info;
                image = swapchainImages[it];
                viewType = .e2D;
                format = surfaceFormat.format;
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

            result := vkCreateImageView(device, *create_info, null, *swapchainImageViews[it]);

            assert(result == .SUCCESS);
        }
    }

    return true;
}

deinit_swapchain :: () {
    vkDestroySwapchainKHR(device, swapchain, null);
}



FRAME_COUNT :: 2;
frame_index := 0;
commandPool   : VkCommandPool;
command_buffers: [FRAME_COUNT]VkCommandBuffer;
frameFences   : [FRAME_COUNT]VkFence; // Create with VK_FENCE_CREATE_SIGNALED.
imageAvailableSemaphores: [FRAME_COUNT]VkSemaphore;
renderFinishedSemaphores: [FRAME_COUNT]VkSemaphore;


init_render :: () {
    commandPoolCreateInfo: VkCommandPoolCreateInfo;
    commandPoolCreateInfo.flags            = .RESET_COMMAND_BUFFER;
    commandPoolCreateInfo.queueFamilyIndex = queue_family_index;
    vkCreateCommandPool(device, *commandPoolCreateInfo, null, *commandPool);

    commandBufferAllocInfo: VkCommandBufferAllocateInfo;
    commandBufferAllocInfo.commandPool        = commandPool;
    commandBufferAllocInfo.level              = .PRIMARY;
    commandBufferAllocInfo.commandBufferCount = FRAME_COUNT;

    vkAllocateCommandBuffers(device, *commandBufferAllocInfo, command_buffers.data);

    semaphoreCreateInfo: VkSemaphoreCreateInfo;
    vkCreateSemaphore(device, *semaphoreCreateInfo, null, *imageAvailableSemaphores[0]);
    vkCreateSemaphore(device, *semaphoreCreateInfo, null, *imageAvailableSemaphores[1]);
    vkCreateSemaphore(device, *semaphoreCreateInfo, null, *renderFinishedSemaphores[0]);
    vkCreateSemaphore(device, *semaphoreCreateInfo, null, *renderFinishedSemaphores[1]);

    fenceCreateInfo: VkFenceCreateInfo;
    fenceCreateInfo.flags = .SIGNALED;

    vkCreateFence(device, *fenceCreateInfo, null, *frameFences[0]);
    vkCreateFence(device, *fenceCreateInfo, null, *frameFences[1]);
}

deinit_render :: () {
    vkDeviceWaitIdle(device);
    vkDestroyFence(device, frameFences[0], null);
    vkDestroyFence(device, frameFences[1], null);
    vkDestroySemaphore(device, renderFinishedSemaphores[0], null);
    vkDestroySemaphore(device, renderFinishedSemaphores[1], null);
    vkDestroySemaphore(device, imageAvailableSemaphores[0], null);
    vkDestroySemaphore(device, imageAvailableSemaphores[1], null);
    vkDestroyCommandPool(device, commandPool, null);
}



draw_frame :: () {
    //print("Frame %\n", frame_index);

    u64_low, u64_high := get_integer_range(u64);

    frame_index += 1;
    index := frame_index % FRAME_COUNT;
    vkWaitForFences(device, 1, *frameFences[index], VK_TRUE, u64_high);
    vkResetFences(device, 1, *frameFences[index]);

    imageIndex: u32;
    vkAcquireNextImageKHR(device, swapchain, u64_high, imageAvailableSemaphores[index], VK_NULL_HANDLE, *imageIndex);

    beginInfo: VkCommandBufferBeginInfo;
    beginInfo.flags = .ONE_TIME_SUBMIT;

    vkBeginCommandBuffer(command_buffers[index], *beginInfo);
    {
        // Set up some state which is needed throughout this procedure
        swapchainImageSubResourceRange : VkImageSubresourceRange;
        {
            using swapchainImageSubResourceRange;
            aspectMask     = .COLOR;
            baseMipLevel   = 0;
            levelCount     = VK_REMAINING_MIP_LEVELS;
            baseArrayLayer = 0;
            layerCount     = VK_REMAINING_ARRAY_LAYERS;
        }

        // Change layout of image to be optimal for clearing
        {
            imgMemoryBarrier : VkImageMemoryBarrier;
            {
                using imgMemoryBarrier;
                srcAccessMask       = 0;
                dstAccessMask       = .TRANSFER_WRITE;
                oldLayout           = .UNDEFINED;
                newLayout           = .TRANSFER_DST_OPTIMAL;
                srcQueueFamilyIndex = queue_family_index;
                dstQueueFamilyIndex = queue_family_index;
                image               = swapchainImages[imageIndex];
                subresourceRange    = swapchainImageSubResourceRange;
            }

            vkCmdPipelineBarrier(command_buffers[index], .TRANSFER, .TRANSFER, 
                                 0, 0, null, 0, null, 1, *imgMemoryBarrier);
        }


        color_attachment : VkRenderingAttachmentInfoKHR;
        {
            using color_attachment;
            imageView = swapchainImageViews[imageIndex];
            imageLayout = .COLOR_ATTACHMENT_OPTIMAL;
            loadOp = .CLEAR;
            storeOp = .STORE;
        }

        /*
        depthStencilAttachment : VkRenderingAttachmentInfoKHR;
        {
            using depthStencilAttachment;

            // A single depth stencil attachment info can be used, but they can also be specified separately.
            // When both are specified separately, the only requirement is that the image view is identical.			
            imageView = depthStencil.view;
            imageLayout = .VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL;
            loadOp = .VK_ATTACHMENT_LOAD_OP_CLEAR;
            storeOp = .VK_ATTACHMENT_STORE_OP_STORE;
            clearValue.depthStencil = .{ 1.0,  0 }.data;
        }
        */

        rendering_info : VkRenderingInfo;
        {
            using rendering_info;
            renderArea = VkRect2D.{
                offset = .{0, 0},
                extent = swapchain_extent,
            };
            layerCount = 1;
            viewMask = 0;
            colorAttachmentCount = 1;
            pColorAttachments = *color_attachment;
            pDepthAttachment = null;
            pStencilAttachment = null;

        }

        vkCmdBeginRendering(command_buffers[index], *rendering_info);
        {
            // Set up my dynamic state
            {
                vkCmdSetRasterizerDiscardEnable(command_buffers[index], VK_FALSE);
                vkCmdSetPrimitiveRestartEnable(command_buffers[index],  VK_TRUE);

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

                // @TODO: All of these dynamic states... What are they for?
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


                // Viewports
                {
                    viewports : [1] VkViewport;
                    {
                        {
                            using viewports[0];
                            x = 0;                    
                            y = 0;
                            width       = xx swapchain_extent.width;
                            height      = xx swapchain_extent.height;
                            minDepth = 0;
                            maxDepth = 1;
                        }
                    }
                    vkCmdSetViewportWithCount(command_buffers[index], viewports.count, viewports.data);
                }

                // Scissors
                {
                    scissors : [1] VkRect2D;
                    {
                        {
                            using scissors[0];
                            offset = .{0, 0};
                            extent = swapchain_extent;
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

            // Clear frame
            {
                clear_color : VkClearColorValue;
                {
                    // Pick a color with which to clear the screen
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
                            extent = swapchain_extent,
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

                // @TODO(alex): Apparently you don't need this if you disable geometry and tessellation shaders in the devicecreateinfo...
                {
                    unused_stages := VkShaderStageFlagBits.[
                        .TESSELLATION_CONTROL,
                        .TESSELLATION_EVALUATION,
                        .GEOMETRY,
                    ];

                    vkCmdBindShadersEXT(
                        command_buffers[index],
                        unused_stages.count, unused_stages.data, null
                    );
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

            // Draw!
            {
                vkCmdDraw(
                    command_buffers[index],
                    vertexCount = 3,
                    instanceCount = 1,
                    firstVertex = 0,
                    firstInstance = 0
                );
            }
        }
        vkCmdEndRendering(command_buffers[index]);

        // Change layout of image to be optimal for presenting
        imgMemoryBarrier : VkImageMemoryBarrier;
        {
            using imgMemoryBarrier;
            srcAccessMask       = .TRANSFER_WRITE;
            dstAccessMask       = .MEMORY_READ;
            oldLayout           = .TRANSFER_DST_OPTIMAL;
            newLayout           = .PRESENT_SRC_KHR;
            srcQueueFamilyIndex = queue_family_index;
            dstQueueFamilyIndex = queue_family_index;
            image               = swapchainImages[imageIndex];
            subresourceRange    = swapchainImageSubResourceRange;
        }

        // Change layout of image to be optimal for presenting
        vkCmdPipelineBarrier(command_buffers[index], .TRANSFER, .BOTTOM_OF_PIPE,
            0, 0, null, 0, null, 1, *imgMemoryBarrier);
    }
    vkEndCommandBuffer(command_buffers[index]);

    submitInfo: VkSubmitInfo; 
    submitInfo.waitSemaphoreCount   = 1;
    submitInfo.pWaitSemaphores      = *imageAvailableSemaphores[index];
    submitInfo.pWaitDstStageMask    = VkPipelineStageFlags.[.COLOR_ATTACHMENT_OUTPUT].data;
    submitInfo.commandBufferCount   = 1;
    submitInfo.pCommandBuffers      = *command_buffers[index];
    submitInfo.signalSemaphoreCount = 1;
    submitInfo.pSignalSemaphores    = *renderFinishedSemaphores[index];
    vkQueueSubmit(queue, 1, *submitInfo, frameFences[index]);

    // Present
    presentInfo: VkPresentInfoKHR;
    presentInfo.waitSemaphoreCount = 1;
    presentInfo.pWaitSemaphores    = *renderFinishedSemaphores[index];
    presentInfo.swapchainCount     = 1;
    presentInfo.pSwapchains        = *swapchain;
    presentInfo.pImageIndices      = *imageIndex;
    vkQueuePresentKHR(queue, *presentInfo);
}

#import "Basic";
#import "String";
#import "Math";

#import "Vulkan";

#import "Window_Creation";
#import "Input";

#import "System";
#if OS == .WINDOWS {
    #import "Windows";
}

#import "File";

#load "utils.jai";
#load "init.jai";
