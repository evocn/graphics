// Graphics
// Utils
// April 2025

error_callback :: (error: s32, description: *u8) #c_call {
    new_context: Context;

    TEMPORARY_STORAGE_SIZE :: 1000;
    storage_buf: [TEMPORARY_STORAGE_SIZE] u8;

    storage: Temporary_Storage;
    storage.data = storage_buf.data;
    storage.size = TEMPORARY_STORAGE_SIZE;
    new_context.temporary_storage = *storage;

    //new_context.logger = debug_log_params.main_context.logger;

    push_context new_context {
        print("Error: %\n", to_string(description));
    }
}


debug_callback :: (flags: VkDebugReportFlagsEXT, objType: VkDebugReportObjectTypeEXT, obj: u64, location: u64, code: s32, layerPrefix: *u8, msg: *u8, userData: *void) -> VkBool32 #c_call {
    new_context: Context;
    push_context new_context {
        print("VULKAN VALIDATION: %\n", msg);
    }
    
    return VK_FALSE;
}


print_available_vulkan_extensions :: () {
    extension_count: u32;
    vkEnumerateInstanceExtensionProperties(null, *extension_count, null);
    extension_array := NewArray(extension_count, VkExtensionProperties);
    defer free(extension_array.data);
    vkEnumerateInstanceExtensionProperties(null, *extension_count, extension_array.data);
    print("Available extensions:\n");
    for extension_array print("    % (%)\n", to_string(it.extensionName.data), it.specVersion);
}

vkDestroyDebugReportCallbackEXT : PFN_vkDestroyDebugReportCallbackEXT;

