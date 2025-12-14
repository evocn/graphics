
// Main

////////////////////////////////////////////////////////////////////////////////

DEBUG :: true;

//width                   : u32 = 1280;
//height                  : u32 = 720;
//width                   : u32 = 1920;
//height                  : u32 = 1080;
width                   : u32 = 2560;
height                  : u32 = 1440;
//width                   : u32 = 3840;
//height                  : u32 = 2160;

window                  : Window_Type;

instance                : VkInstance;
debug_callback_handle   : VkDebugReportCallbackEXT;

surface                 : VkSurfaceKHR;

physical_device         : VkPhysicalDevice;
queue_family_index      : u32;
device                  : VkDevice;
queue                   : VkQueue;

shaders                 : [2] VkShaderEXT;

main :: () {
    set_working_directory_to_base_folder :: () {
        executable_path := path_strip_filename(get_path_of_running_executable());
        set_working_directory(tprint("%/../", executable_path));
    }
    set_working_directory_to_base_folder();

    // Create window
    window = create_window(
        xx width, xx height,
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
  
    print_available_vulkan_extensions();

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
            shaderCreateInfos : [2] VkShaderCreateInfoEXT;


            vertexLayout : VkDescriptorSetLayout;
            {
                bindings : [1] VkDescriptorSetLayoutBinding;
                {
                    {
                        using bindings[0];
                        binding = 0;
                        descriptorType = .UNIFORM_BUFFER;
                        descriptorCount = 1;
                        stageFlags = .VERTEX;
                    }
                }

                create_info : VkDescriptorSetLayoutCreateInfo;
                {
                    using create_info;
                    flags = 0;
                    bindingCount = 1;
                    pBindings = bindings.data;
                }

                result := vkCreateDescriptorSetLayout(device, *create_info, null, *vertexLayout);
                assert(result == .SUCCESS);
            }

            {
                using shaderCreateInfos[0];
                flags = .LINK_STAGE;

                stage       = .VERTEX;
                nextStage   = .FRAGMENT;

                codeType    = .SPIRV;
                codeSize    = xx spirv[0].count;
                pCode       = spirv[0].data;

                pName       = "main";

                setLayoutCount = 1;
                pSetLayouts = *vertexLayout;

                pushConstantRangeCount = 0;
                pPushConstantRanges = null;
                pSpecializationInfo = null;
            }

            {
                using shaderCreateInfos[1];
                flags = .LINK_STAGE;

                stage       = .FRAGMENT;
                nextStage   = 0;

                codeType    = .SPIRV;
                codeSize    = xx spirv[1].count;
                pCode       = spirv[1].data;

                pName       = "main";

                setLayoutCount = 0;
                pSetLayouts = null;

                pushConstantRangeCount = 0;
                pPushConstantRanges = null;
                pSpecializationInfo = null;
            }

            result := vkCreateShadersEXT(device, 2, shaderCreateInfos.data, null, shaders.data);

            if (result != .SUCCESS)
            {
                log("fuck!");
            }
        }
    }

    // Dynamic State
    {
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
    app_info.pEngineName        = "graphics engine";
    app_info.engineVersion      = VK_MAKE_VERSION(1, 5, 0);
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
        my_hwnd := window;
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

    // Logical device
    //
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
            }

            enabledExtensionCount   = xx device_extensions.count;
            ppEnabledExtensionNames = device_extensions.data;
        }

        // Enabled Features
        {
            // This is the old way.
            /*
            features : VkPhysicalDeviceFeatures;
            vkGetPhysicalDeviceFeatures(physical_device, *features);
            pEnabledFeatures = *features;
            */

            pEnabledFeatures = null;

            last_feature : *void;
            {
                shader_object_features : VkPhysicalDeviceShaderObjectFeaturesEXT;
                // Enable Shader Object
                {
                    shader_object_features.shaderObject = VK_TRUE;
                    shader_object_features.pNext = null;
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
swapchainExtent: VkExtent2D;
surfaceFormat  : VkSurfaceFormatKHR;

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

    swapchainExtent = surfaceCapabilities.currentExtent;
    if swapchainExtent.width == U32_MAX {
        swapchainExtent.width  = clamp(width, surfaceCapabilities.minImageExtent.width, surfaceCapabilities.maxImageExtent.width);
        swapchainExtent.height = clamp(height, surfaceCapabilities.minImageExtent.height, surfaceCapabilities.maxImageExtent.height);
    }

    swapChainCreateInfo: VkSwapchainCreateInfoKHR;
    the_surface := surface;  // No way yet to avoid importing this with 'using'. Should fix that!
    {
        swapChainCreateInfo.surface = the_surface;

        using swapChainCreateInfo;
        minImageCount               = swapchainImageCount;
        imageFormat                 = surfaceFormat.format;
        imageColorSpace             = surfaceFormat.colorSpace;
        imageExtent                 = swapchainExtent;
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
commandBuffers: [FRAME_COUNT]VkCommandBuffer;
frameFences   : [FRAME_COUNT]VkFence; // Create with VK_FENCE_CREATE_SIGNALED.
imageAvailableSemaphores: [FRAME_COUNT]VkSemaphore;
renderFinishedSemaphores: [FRAME_COUNT]VkSemaphore;


init_render :: () {
    log("init_render\n");

    commandPoolCreateInfo: VkCommandPoolCreateInfo;
    commandPoolCreateInfo.flags            = .RESET_COMMAND_BUFFER;
    commandPoolCreateInfo.queueFamilyIndex = queue_family_index;
    vkCreateCommandPool(device, *commandPoolCreateInfo, null, *commandPool);

    commandBufferAllocInfo: VkCommandBufferAllocateInfo;
    commandBufferAllocInfo.commandPool        = commandPool;
    commandBufferAllocInfo.level              = .PRIMARY;
    commandBufferAllocInfo.commandBufferCount = FRAME_COUNT;

    vkAllocateCommandBuffers(device, *commandBufferAllocInfo, commandBuffers.data);

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
    log("deinit_render\n");

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

    vkBeginCommandBuffer(commandBuffers[index], *beginInfo);
    {
        // Clear frame
        subResourceRange : VkImageSubresourceRange;
        {
            using subResourceRange;
            aspectMask     = .COLOR;
            baseMipLevel   = 0;
            levelCount     = VK_REMAINING_MIP_LEVELS;
            baseArrayLayer = 0;
            layerCount     = VK_REMAINING_ARRAY_LAYERS;
        }

        // Change layout of image to be optimal for clearing
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
            subresourceRange    = subResourceRange;
        }

        vkCmdPipelineBarrier(commandBuffers[index], .TRANSFER, .TRANSFER, 
                             0, 0, null, 0, null, 1, *imgMemoryBarrier);

        clearColor : VkClearColorValue;
        {
            // Pick a color with which to clear the screen
            color1 := Vector4.{1,  1, 0, 1};
            color2 := Vector4.{.5, 0, 1, 1};

            now := seconds_since_init();
            t := cos(cast(float) now) * .5 + .5;
            Clamp(*t, 0, 1);
            color := lerp(color1, color2, t);
            clearColor.float32_ = color.component;
            // clearColor.float32 = float.[1, 1, 0, 1];
        }

        vkCmdClearColorImage(commandBuffers[index], swapchainImages[imageIndex], .TRANSFER_DST_OPTIMAL, *clearColor, 1, *subResourceRange);


        // Try some shader stuff here
        {
            {
                stages := VkShaderStageFlagBits.[
                    .VERTEX,
                    .FRAGMENT,
                ];

                vkCmdBindShadersEXT(commandBuffers[index], stages.count, stages.data, shaders.data);
            }

            // Potentially don't need this if you disable geometry and tessellation shaders in the devicecreateinfo...
            {
                unused_stages := VkShaderStageFlagBits.[
                    .TESSELLATION_CONTROL,
                    .TESSELLATION_EVALUATION,
                    .GEOMETRY,
                ];

                vkCmdBindShadersEXT(commandBuffers[index], unused_stages.count, unused_stages.data, null);
            }

            // Dynamic rendering
            rendering_info : VkRenderingInfo;
            {
                colorAttachment : VkRenderingAttachmentInfoKHR;
                // New structures are used to define the attachments used in dynamic rendering
                {
                    {
                        using colorAttachment;

                        imageView = swapchainImageViews[imageIndex];
                        imageLayout = .COLOR_ATTACHMENT_OPTIMAL;
                        loadOp = .CLEAR;
                        storeOp = .STORE;
                        //clearValue.color = ;
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
                }


                using rendering_info;
                renderArea = .{ .{0, 0}, .{width, height} };
                layerCount = 1;
                colorAttachmentCount = 1;
                pColorAttachments = *colorAttachment;
                pDepthAttachment = null;
                pStencilAttachment = null;
            }

            vkCmdBeginRendering(
                commandBuffers[index],
                *rendering_info,
            );

            vkCmdDraw(commandBuffers[index], 3, 1, 0, 0);
        }

        // Change layout of image to be optimal for presenting
        imgMemoryBarrier.srcAccessMask = .TRANSFER_WRITE;
        imgMemoryBarrier.dstAccessMask = .MEMORY_READ;
        imgMemoryBarrier.oldLayout     = .TRANSFER_DST_OPTIMAL;
        imgMemoryBarrier.newLayout     = .PRESENT_SRC_KHR;
        //imgMemoryBarrier.srcQueueFamilyIndex = queue_family_index;
        //imgMemoryBarrier.dstQueueFamilyIndex = queue_family_index;
        //imgMemoryBarrier.image = swapchainImages[imageIndex];
        //imgMemoryBarrier.subresourceRange = subResourceRange;
        vkCmdPipelineBarrier(commandBuffers[index], .TRANSFER, .BOTTOM_OF_PIPE,
            0, 0, null, 0, null, 1, *imgMemoryBarrier);
    }
    vkEndCommandBuffer(commandBuffers[index]);

    submitInfo: VkSubmitInfo; 
    submitInfo.waitSemaphoreCount   = 1;
    submitInfo.pWaitSemaphores      = *imageAvailableSemaphores[index];
    submitInfo.pWaitDstStageMask    = VkPipelineStageFlags.[.COLOR_ATTACHMENT_OUTPUT].data;
    submitInfo.commandBufferCount   = 1;
    submitInfo.pCommandBuffers      = *commandBuffers[index];
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
