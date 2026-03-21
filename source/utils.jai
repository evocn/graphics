
// Utils

////////////////////////////////////////////////////////////////////////////////

get_host_visible_memory_type :: (using memory_properties: VkPhysicalDeviceMemoryProperties) -> index: int
{ 
    index := -1;
    for 0..memoryTypeCount-1 {
        type := memoryTypes[it];
        is_host_visible := type.propertyFlags & .HOST_VISIBLE;
        if is_host_visible {
            index = it;
            break;
        }
    }

    return index;
}

////////////////////////////////////////////////////////////////////////////////

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

debug_callback :: (flags: VkDebugReportFlagsEXT, objType: VkDebugReportObjectTypeEXT, obj: u64, location: u64, code: s32, layerPrefix: *u8, msg: *u8, userData: *void) -> VkBool32 #c_call {
    push_context {
        print("VULKAN VALIDATION: %\n\n", to_string(msg));
    }
    
    return VK_FALSE;
}
