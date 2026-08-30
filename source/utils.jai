
// Utils

////////////////////////////////////////////////////////////////////////////////

select_memory_type :: (memory_properties: VkPhysicalDeviceMemoryProperties, type_bits : u32, requirements_mask : VkMemoryPropertyFlagBits) -> success: bool, memory_type_index: u32
{
    for i : 0..memory_properties.memoryTypeCount-1 {
        bit : u32 = cast(u32) (1 << i);
        if (type_bits & bit) == 0 continue;

        if (memory_properties.memoryTypes[i].propertyFlags & requirements_mask) == requirements_mask {
            return true, i;
        }
    }
    return false, 0;
}

////////////////////////////////////////////////////////////////////////////////

align_up :: (size : u64, power_of_two_alignment : u64) -> aligned: u64 {
    return (size + (power_of_two_alignment - 1)) & ~(power_of_two_alignment - 1);
}

offset_of :: ($T: Type, $member: string) -> u32 {
    for type_info(T).members {
        if it.name == member return cast(u32)it.offset_in_bytes;
    }

    assert(false, "Type '%' does not have member '%'", T, member);
    return 0;
}

////////////////////////////////////////////////////////////////////////////////

log_physical_device_properties :: (using physical_device_properties : VkPhysicalDeviceProperties) {
    log("================================================");
    log("Name: %", cast(string, deviceName));
    //log("Vendor: %", vendorID);
    //log("Device: %", deviceID);
    log("Type: %", deviceType);
    log("API Version: %.%.%", VK_API_VERSION_MAJOR(apiVersion), VK_API_VERSION_MINOR(apiVersion), VK_API_VERSION_PATCH(apiVersion));
    log("================================================");
}

////////////////////////////////////////////////////////////////////////////////

error_callback :: (error: s32, description: *u8) #c_call {
    push_context {
        print("Error: %\n\n", to_string(description));
    }
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

        name_info : VkDebugUtilsObjectNameInfoEXT;
        name_info.objectType   = object_type;
        name_info.objectHandle = cast(u64) handle;
        name_info.pObjectName  = temp_c_string(name);

        vkSetDebugUtilsObjectNameEXT(device, *name_info);
    }
}
