// Graphics
// Utils
// April 2025

error_callback :: (error: s32, description: *u8) #c_call {
    push_context {
        print("Error: %\n", to_string(description));
    }
}

debug_callback :: (flags: VkDebugReportFlagsEXT, objType: VkDebugReportObjectTypeEXT, obj: u64, location: u64, code: s32, layerPrefix: *u8, msg: *u8, userData: *void) -> VkBool32 #c_call {
    push_context {
        print("VULKAN VALIDATION: %\n", to_string(msg));
    }
    
    return VK_FALSE;
}


print_available_vulkan_extensions :: () {
    extension_count: u32;
    vkEnumerateInstanceExtensionProperties(null, *extension_count, null);
    extension_array := NewArray(extension_count, VkExtensionProperties);
    defer free(extension_array.data);
    vkEnumerateInstanceExtensionProperties(null, *extension_count, extension_array.data);
    print("Instance extensions:\n");
    for extension_array print("    % (%)\n", to_string(it.extensionName.data), it.specVersion);
}
