instance        : VkInstance;
debug_messenger : VkDebugUtilsMessengerEXT;
surface         : VkSurfaceKHR;

physical_device                   : VkPhysicalDevice;
device_limits                     : VkPhysicalDeviceLimits;
memory_properties                 : VkPhysicalDeviceMemoryProperties;
descriptor_heap_properties        : VkPhysicalDeviceDescriptorHeapPropertiesEXT;
acceleration_structure_properties : VkPhysicalDeviceAccelerationStructurePropertiesKHR;

device              : VkDevice;
queue_family_index  : u32;
queue               : VkQueue;

init_instance :: () {
    instance_extensions : [..] *u8;
    array_add(*instance_extensions, VK_KHR_SURFACE_EXTENSION_NAME.data);
    array_add(*instance_extensions, VK_KHR_GET_SURFACE_CAPABILITIES_2_EXTENSION_NAME.data);
    array_add(*instance_extensions, VK_KHR_SURFACE_MAINTENANCE_1_EXTENSION_NAME.data);
    #if OS == .WINDOWS {
        array_add(*instance_extensions, VK_KHR_WIN32_SURFACE_EXTENSION_NAME.data);
    } else {
        #assert(false);
    }

    enabled_layers : [..] *u8;

    application_info := VkApplicationInfo.{apiVersion = VK_MAKE_API_VERSION(0, 1, 4, 0)};
    instance_create_info := VkInstanceCreateInfo.{pApplicationInfo = *application_info};

    #if DEVELOPER_TOOLS {
        array_add(*instance_extensions, VK_EXT_DEBUG_UTILS_EXTENSION_NAME.data);
        array_add(*enabled_layers, "VK_LAYER_KHRONOS_validation");

        validate_sync : VkBool32 = VK_TRUE;
        layer_setting := VkLayerSettingEXT.{
            pLayerName   = "VK_LAYER_KHRONOS_validation",
            pSettingName = "validate_sync",
            type         = .BOOL32,
            valueCount   = 1,
            pValues      = *validate_sync,
        };
        layer_settings_create_info := VkLayerSettingsCreateInfoEXT.{settingCount = 1, pSettings = *layer_setting};
        instance_create_info.pNext = *layer_settings_create_info;
    }

    instance_create_info.enabledExtensionCount   = xx instance_extensions.count;
    instance_create_info.ppEnabledExtensionNames = instance_extensions.data;
    instance_create_info.enabledLayerCount       = xx enabled_layers.count;
    instance_create_info.ppEnabledLayerNames     = enabled_layers.data;

    result := vkCreateInstance(*instance_create_info, null, *instance);
    assert(result == .SUCCESS);

    vk_load_instance_functions(instance);

    #if DEVELOPER_TOOLS {
        messenger_create_info := VkDebugUtilsMessengerCreateInfoEXT.{
            messageSeverity = .WARNING | .ERROR,
            messageType     = .GENERAL | .VALIDATION | .PERFORMANCE,
            pfnUserCallback = debug_utils_callback,
        };
        result = vkCreateDebugUtilsMessengerEXT(instance, *messenger_create_info, null, *debug_messenger);
        assert(result == .SUCCESS);
    }
}

deinit_instance :: () {
    #if DEVELOPER_TOOLS {
        vkDestroyDebugUtilsMessengerEXT(instance, debug_messenger, null);
    }
    vkDestroyInstance(instance, null);
}

init_surface :: () {
    #if OS == .WINDOWS {
        surface_create_info := VkWin32SurfaceCreateInfoKHR.{hinstance = GetModuleHandleW(null), hwnd = window};
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
    physical_device_count : u32;
    vkEnumeratePhysicalDevices(instance, *physical_device_count, null);
    physical_devices := NewArray(physical_device_count, VkPhysicalDevice,, temp);
    vkEnumeratePhysicalDevices(instance, *physical_device_count, physical_devices.data);

    chosen_is_discrete := false;
    for candidate : physical_devices {
        properties : VkPhysicalDeviceProperties;
        vkGetPhysicalDeviceProperties(candidate, *properties);
        is_discrete := properties.deviceType == .DISCRETE_GPU;
        log("GPU %: % (%).", it_index, to_string(properties.deviceName.data), properties.deviceType);

        family_count : u32;
        vkGetPhysicalDeviceQueueFamilyProperties(candidate, *family_count, null);
        families := NewArray(family_count, VkQueueFamilyProperties,, temp);
        vkGetPhysicalDeviceQueueFamilyProperties(candidate, *family_count, families.data);

        for family : families {
            supports_present : VkBool32;
            vkGetPhysicalDeviceSurfaceSupportKHR(candidate, xx it_index, surface, *supports_present);
            if !supports_present || !(family.queueFlags & .GRAPHICS) continue;

            if !physical_device || (is_discrete && !chosen_is_discrete) {
                physical_device    = candidate;
                queue_family_index = xx it_index;
                chosen_is_discrete = is_discrete;
            }
            break;
        }
    }
    assert(physical_device != null, "No GPU has a queue family that supports both graphics and present.");

    acceleration_structure_properties = .{};
    descriptor_heap_properties = .{pNext = *acceleration_structure_properties};
    properties2 := VkPhysicalDeviceProperties2.{pNext = *descriptor_heap_properties};
    vkGetPhysicalDeviceProperties2(physical_device, *properties2);
    device_limits = properties2.properties.limits;
    log("Using %, queue family %.", to_string(properties2.properties.deviceName.data), queue_family_index);

    vkGetPhysicalDeviceMemoryProperties(physical_device, *memory_properties);

    Features :: struct {
        features2                       : VkPhysicalDeviceFeatures2;
        vulkan_1_1_features             : VkPhysicalDeviceVulkan11Features;
        vulkan_1_2_features             : VkPhysicalDeviceVulkan12Features;
        vulkan_1_3_features             : VkPhysicalDeviceVulkan13Features;
        vulkan_1_4_features             : VkPhysicalDeviceVulkan14Features;
        shader_object_features          : VkPhysicalDeviceShaderObjectFeaturesEXT;
        unified_image_layout_features   : VkPhysicalDeviceUnifiedImageLayoutsFeaturesKHR;
        descriptor_heap_features        : VkPhysicalDeviceDescriptorHeapFeaturesEXT;
        untyped_pointers_features       : VkPhysicalDeviceShaderUntypedPointersFeaturesKHR;
        address_commands_features       : VkPhysicalDeviceDeviceAddressCommandsFeaturesKHR;
        swapchain_maintenance_features  : VkPhysicalDeviceSwapchainMaintenance1FeaturesKHR;
        acceleration_structure_features : VkPhysicalDeviceAccelerationStructureFeaturesKHR;
        ray_query_features              : VkPhysicalDeviceRayQueryFeaturesKHR;
    }

    chain :: (using features: *Features) {
        features2.pNext                       = *vulkan_1_1_features;
        vulkan_1_1_features.pNext             = *vulkan_1_2_features;
        vulkan_1_2_features.pNext             = *vulkan_1_3_features;
        vulkan_1_3_features.pNext             = *vulkan_1_4_features;
        vulkan_1_4_features.pNext             = *shader_object_features;
        shader_object_features.pNext          = *unified_image_layout_features;
        unified_image_layout_features.pNext   = *descriptor_heap_features;
        descriptor_heap_features.pNext        = *untyped_pointers_features;
        untyped_pointers_features.pNext       = *address_commands_features;
        address_commands_features.pNext       = *swapchain_maintenance_features;
        swapchain_maintenance_features.pNext  = *acceleration_structure_features;
        acceleration_structure_features.pNext = *ray_query_features;
    }

    supported : Features;
    chain(*supported);
    vkGetPhysicalDeviceFeatures2(physical_device, *supported.features2);

    enabled : Features;
    chain(*enabled);
    enabled.features2.features.shaderInt64                        = VK_TRUE;
    enabled.features2.features.fragmentStoresAndAtomics           = VK_TRUE;
    enabled.features2.features.samplerAnisotropy                  = VK_TRUE;
    enabled.features2.features.multiDrawIndirect                  = VK_TRUE;
    enabled.features2.features.drawIndirectFirstInstance          = VK_TRUE;
    enabled.vulkan_1_1_features.shaderDrawParameters              = VK_TRUE;
    enabled.vulkan_1_2_features.timelineSemaphore                 = VK_TRUE;
    enabled.vulkan_1_2_features.bufferDeviceAddress               = VK_TRUE;
    enabled.vulkan_1_2_features.runtimeDescriptorArray            = VK_TRUE;
    enabled.vulkan_1_2_features.scalarBlockLayout                 = VK_TRUE;
    enabled.vulkan_1_3_features.dynamicRendering                  = VK_TRUE;
    enabled.vulkan_1_3_features.synchronization2                  = VK_TRUE;
    enabled.vulkan_1_3_features.shaderDemoteToHelperInvocation    = VK_TRUE;
    enabled.vulkan_1_4_features.maintenance5                      = VK_TRUE;
    enabled.shader_object_features.shaderObject                   = VK_TRUE;
    enabled.unified_image_layout_features.unifiedImageLayouts     = VK_TRUE;
    enabled.descriptor_heap_features.descriptorHeap               = VK_TRUE;
    enabled.untyped_pointers_features.shaderUntypedPointers       = VK_TRUE;
    enabled.address_commands_features.deviceAddressCommands       = VK_TRUE;
    enabled.swapchain_maintenance_features.swapchainMaintenance1  = VK_TRUE;
    enabled.acceleration_structure_features.accelerationStructure = VK_TRUE;
    enabled.ray_query_features.rayQuery                           = VK_TRUE;

    {
        supported_bytes := cast(*VkBool32) *supported;
        enabled_bytes   := cast(*VkBool32) *enabled;
        for 0..size_of(Features) / size_of(VkBool32) - 1 {
            if enabled_bytes[it] == VK_TRUE  assert(supported_bytes[it] == VK_TRUE, "The GPU lacks a required feature (Features word %).", it);
        }
    }

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

    queue_priority : float = 1.0;
    queue_create_info := VkDeviceQueueCreateInfo.{
        queueFamilyIndex = queue_family_index,
        queueCount       = 1,
        pQueuePriorities = *queue_priority,
    };

    device_create_info := VkDeviceCreateInfo.{
        pNext                   = *enabled.features2,
        queueCreateInfoCount    = 1,
        pQueueCreateInfos       = *queue_create_info,
        enabledExtensionCount   = device_extensions.count,
        ppEnabledExtensionNames = device_extensions.data,
    };
    result := vkCreateDevice(physical_device, *device_create_info, null, *device);
    assert(result == .SUCCESS);

    vk_load_device_functions(device);
    vkGetDeviceQueue(device, queue_family_index, 0, *queue);
}

deinit_device :: () {
    vkDestroyDevice(device, null);
}

debug_utils_callback :: (severity: VkDebugUtilsMessageSeverityFlagBitsEXT, types: VkDebugUtilsMessageTypeFlagsEXT, callback_data: *VkDebugUtilsMessengerCallbackDataEXT, user_data: *void) -> VkBool32 #c_call {
    push_context {
        print("VULKAN %: %\n\n", severity, to_string(callback_data.pMessage));
    }
    return VK_FALSE;
}

set_debug_name :: (object_type: VkObjectType, handle: *void, name: string) {
    #if DEVELOPER_TOOLS {
        if handle == null return;

        name_info := VkDebugUtilsObjectNameInfoEXT.{
            objectType   = object_type,
            objectHandle = cast(u64) handle,
            pObjectName  = temp_c_string(name),
        };
        vkSetDebugUtilsObjectNameEXT(device, *name_info);
    }
}
