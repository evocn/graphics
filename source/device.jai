// Graphics
// Device

init_instance :: () {
    result : VkResult;

    {
        using instance_create_info : VkInstanceCreateInfo;
        application_info := VkApplicationInfo.{apiVersion = VK_MAKE_API_VERSION(0, 1, 4, 0)};
        pApplicationInfo = *application_info;

        instance_extensions : [..] *u8;
        array_add(*instance_extensions, VK_KHR_SURFACE_EXTENSION_NAME.data);
        array_add(*instance_extensions, VK_KHR_GET_SURFACE_CAPABILITIES_2_EXTENSION_NAME.data);
        array_add(*instance_extensions, VK_KHR_SURFACE_MAINTENANCE_1_EXTENSION_NAME.data);
        #if OS == .WINDOWS {
            array_add(*instance_extensions, VK_KHR_WIN32_SURFACE_EXTENSION_NAME.data);
        } else {
            #assert(false);
        }

        #if DEVELOPER_TOOLS {
            array_add(*instance_extensions, VK_EXT_DEBUG_UTILS_EXTENSION_NAME.data);
        }

        enabledExtensionCount   = xx instance_extensions.count;
        ppEnabledExtensionNames = instance_extensions.data;

        enabled_layers: [..] *u8;

        #if DEVELOPER_TOOLS {
            array_add(*enabled_layers, "VK_LAYER_KHRONOS_validation");
        }

        enabledLayerCount = xx enabled_layers.count;
        ppEnabledLayerNames = enabled_layers.data;

        #if DEVELOPER_TOOLS {
            validate_sync : VkBool32 = VK_TRUE;
            layer_settings := VkLayerSettingEXT.[
                .{
                    pLayerName   = "VK_LAYER_KHRONOS_validation",
                    pSettingName = "validate_sync",
                    type         = .BOOL32,
                    valueCount   = 1,
                    pValues      = *validate_sync,
                },
            ];

            layer_settings_create_info : VkLayerSettingsCreateInfoEXT;
            layer_settings_create_info.settingCount = xx layer_settings.count;
            layer_settings_create_info.pSettings    = layer_settings.data;

            pNext = *layer_settings_create_info;
        }

        result = vkCreateInstance(*instance_create_info, null, *instance);
        assert(result == .SUCCESS);
    }

    #if DEVELOPER_TOOLS {
        vkCreateDebugUtilsMessengerEXT : PFN_vkCreateDebugUtilsMessengerEXT = xx vkGetInstanceProcAddr(instance, "vkCreateDebugUtilsMessengerEXT");

        if vkCreateDebugUtilsMessengerEXT {
            messenger_create_info : VkDebugUtilsMessengerCreateInfoEXT;
            messenger_create_info.messageSeverity = .WARNING | .ERROR;
            messenger_create_info.messageType     = .GENERAL | .VALIDATION | .PERFORMANCE;
            messenger_create_info.pfnUserCallback = debug_utils_callback;

            result = vkCreateDebugUtilsMessengerEXT(instance, *messenger_create_info, null, *debug_messenger);
            assert(result == .SUCCESS);
        }
        else {
            log_error("Unable to load the debug messenger!");
        }
    }
}


deinit_instance :: () {
    #if DEVELOPER_TOOLS {
        if debug_messenger {
            vkDestroyDebugUtilsMessengerEXT(instance, debug_messenger, null);
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

                flags := queue_family.queueFlags;

                if graphics == -1 && supports_present && (flags & .GRAPHICS) {
                    graphics = queue_family_index;
                }

                if compute == -1 && (flags & (.COMPUTE | .GRAPHICS)) == .COMPUTE {
                    compute = queue_family_index;
                }

                if transfer == -1 && (flags & (.TRANSFER | .GRAPHICS | .COMPUTE)) == .TRANSFER {
                    transfer = queue_family_index;
                }
            }

            assert(graphics != -1, "This GPU exposes no queue family that supports both graphics and present.");

            if compute  == -1 then compute  = graphics;
            if transfer == -1 then transfer = graphics;

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

            queue_priority : float = 1.0;
            queue_create_infos : [3] VkDeviceQueueCreateInfo;
            queue_create_info_count := 0;

            requested_families := int.[
                queue_family_indices.graphics,
                queue_family_indices.compute,
                queue_family_indices.transfer,
            ];

            for family : requested_families {
                already_requested := false;
                for 0..queue_create_info_count-1 {
                    if queue_create_infos[it].queueFamilyIndex == cast(u32) family {
                        already_requested = true;
                        break;
                    }
                }
                if already_requested continue;

                queue_create_infos[queue_create_info_count].queueFamilyIndex = xx family;
                queue_create_infos[queue_create_info_count].queueCount       = 1;
                queue_create_infos[queue_create_info_count].pQueuePriorities = *queue_priority;
                queue_create_info_count += 1;
            }

            queueCreateInfoCount    = xx queue_create_info_count;
            pQueueCreateInfos       = queue_create_infos.data;

            // Device Extensions
            device_extensions :: *u8.[
                VK_KHR_SWAPCHAIN_EXTENSION_NAME.data,
                VK_KHR_DYNAMIC_RENDERING_EXTENSION_NAME.data,
                VK_EXT_SHADER_OBJECT_EXTENSION_NAME.data,
                VK_EXT_DESCRIPTOR_HEAP_EXTENSION_NAME.data,
                VK_KHR_UNIFIED_IMAGE_LAYOUTS_EXTENSION_NAME.data,
                VK_KHR_SHADER_UNTYPED_POINTERS_EXTENSION_NAME.data,
                VK_KHR_DEVICE_ADDRESS_COMMANDS_EXTENSION_NAME.data,
                VK_KHR_SWAPCHAIN_MAINTENANCE_1_EXTENSION_NAME.data,

                VK_KHR_ACCELERATION_STRUCTURE_EXTENSION_NAME.data,
                VK_KHR_DEFERRED_HOST_OPERATIONS_EXTENSION_NAME.data,
                VK_KHR_RAY_QUERY_EXTENSION_NAME.data,
            ];

            enabledExtensionCount   = xx device_extensions.count;
            ppEnabledExtensionNames = device_extensions.data;

            // Properties
            {
                acceleration_structure_properties = .{pNext = null};
                descriptor_heap_properties = .{pNext = *acceleration_structure_properties};
                vulkan_1_4_properties = .{pNext = *descriptor_heap_properties};
                vulkan_1_3_properties = .{pNext = *vulkan_1_4_properties};
                vulkan_1_2_properties = .{pNext = *vulkan_1_3_properties};
                vulkan_1_1_properties = .{pNext = *vulkan_1_2_properties};

                properties2 = .{pNext = *vulkan_1_1_properties};
                vkGetPhysicalDeviceProperties2(physical_device, *properties2);
            }

            // Features
            {
                supported : type_of(features);
                {
                    supported.acceleration_structure_features.pNext = *supported.ray_query_features;
                    supported.swapchain_maintenance_features.pNext  = *supported.acceleration_structure_features;
                    supported.address_commands_features.pNext       = *supported.swapchain_maintenance_features;
                    supported.untyped_pointers_features.pNext       = *supported.address_commands_features;
                    supported.descriptor_heap_features.pNext        = *supported.untyped_pointers_features;
                    supported.unified_image_layout_features.pNext   = *supported.descriptor_heap_features;
                    supported.shader_object_features.pNext          = *supported.unified_image_layout_features;
                    supported.vulkan_1_4_features.pNext             = *supported.shader_object_features;
                    supported.vulkan_1_3_features.pNext             = *supported.vulkan_1_4_features;
                    supported.vulkan_1_2_features.pNext             = *supported.vulkan_1_3_features;
                    supported.vulkan_1_1_features.pNext             = *supported.vulkan_1_2_features;
                    supported.features2.pNext                       = *supported.vulkan_1_1_features;

                    vkGetPhysicalDeviceFeatures2(physical_device, *supported.features2);
                }

                assert(VK_TRUE == supported.features2.features.shaderInt64);
                assert(VK_TRUE == supported.vulkan_1_1_features.shaderDrawParameters);
                assert(VK_TRUE == supported.vulkan_1_2_features.timelineSemaphore);
                assert(VK_TRUE == supported.vulkan_1_2_features.bufferDeviceAddress);
                assert(VK_TRUE == supported.vulkan_1_2_features.runtimeDescriptorArray);
                assert(VK_TRUE == supported.vulkan_1_2_features.scalarBlockLayout);
                assert(VK_TRUE == supported.vulkan_1_3_features.dynamicRendering);
                assert(VK_TRUE == supported.vulkan_1_3_features.synchronization2);
                assert(VK_TRUE == supported.vulkan_1_4_features.maintenance5);
                assert(VK_TRUE == supported.shader_object_features.shaderObject);
                assert(VK_TRUE == supported.unified_image_layout_features.unifiedImageLayouts);
                assert(VK_TRUE == supported.descriptor_heap_features.descriptorHeap);
                assert(VK_TRUE == supported.untyped_pointers_features.shaderUntypedPointers);
                assert(VK_TRUE == supported.address_commands_features.deviceAddressCommands);
                assert(VK_TRUE == supported.swapchain_maintenance_features.swapchainMaintenance1);

                assert(VK_TRUE == supported.acceleration_structure_features.accelerationStructure);
                assert(VK_TRUE == supported.ray_query_features.rayQuery);

                ray_query_features = .{rayQuery = VK_TRUE, pNext = null};
                acceleration_structure_features = .{accelerationStructure = VK_TRUE, pNext = *ray_query_features};
                swapchain_maintenance_features = .{swapchainMaintenance1 = VK_TRUE, pNext = *acceleration_structure_features};
                address_commands_features = .{deviceAddressCommands = VK_TRUE, pNext = *swapchain_maintenance_features};
                untyped_pointers_features = .{shaderUntypedPointers = VK_TRUE, pNext = *address_commands_features};
                descriptor_heap_features = .{descriptorHeap = VK_TRUE, pNext = *untyped_pointers_features};
                unified_image_layout_features = .{unifiedImageLayouts = VK_TRUE, pNext = *descriptor_heap_features};
                shader_object_features = .{shaderObject = VK_TRUE, pNext = *unified_image_layout_features};
                vulkan_1_4_features = .{pNext = *shader_object_features};
                {
                    using vulkan_1_4_features;
                    maintenance5 = VK_TRUE;

                    hostImageCopy = supported.vulkan_1_4_features.hostImageCopy;
                }
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
                    scalarBlockLayout = VK_TRUE;
                }
                vulkan_1_1_features = .{pNext = *vulkan_1_2_features};
                {
                    using vulkan_1_1_features;
                    shaderDrawParameters = VK_TRUE;
                }
                features2 = .{pNext = *vulkan_1_1_features};
                {
                    using features2.features;
                    shaderInt64 = VK_TRUE;
                }
            }

            pNext = *features2;

            result = vkCreateDevice(physical_device, *device_create_info, null, *device);
            assert(result == .SUCCESS);
        }
    }
}

deinit_device :: () {
    vkDestroyDevice(device, null);
}
