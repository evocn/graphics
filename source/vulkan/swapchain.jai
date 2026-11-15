MAX_SWAPCHAIN_IMAGES :: 3;

swapchain_context : struct {
    swapchain        : VkSwapchainKHR;
    surface_format   : VkSurfaceFormatKHR;
    extent           : VkExtent2D;
    image_count      : u32;
    images           : [MAX_SWAPCHAIN_IMAGES] VkImage;
    views            : [MAX_SWAPCHAIN_IMAGES] VkImageView;
    needs_recreation : bool;
}

init_swapchain :: () {
    format_count : u32;
    vkGetPhysicalDeviceSurfaceFormatsKHR(device_context.physical_device, device_context.surface, *format_count, null);
    formats := NewArray(format_count, VkSurfaceFormatKHR,, temp);
    vkGetPhysicalDeviceSurfaceFormatsKHR(device_context.physical_device, device_context.surface, *format_count, formats.data);

    swapchain_context.surface_format = formats[0];
    for preferred : VkFormat.[.B8G8R8A8_SRGB, .R8G8B8A8_SRGB] {
        for formats {
            if it.format == preferred && it.colorSpace == .SRGB_NONLINEAR {
                swapchain_context.surface_format = it;
                break preferred;
            }
        }
    }

    mode_count : u32;
    vkGetPhysicalDeviceSurfacePresentModesKHR(device_context.physical_device, device_context.surface, *mode_count, null);
    modes := NewArray(mode_count, VkPresentModeKHR,, temp);
    vkGetPhysicalDeviceSurfacePresentModesKHR(device_context.physical_device, device_context.surface, *mode_count, modes.data);

    present_mode := VkPresentModeKHR.FIFO;
    if array_find(modes, .MAILBOX)  present_mode = .MAILBOX;

    capabilities : VkSurfaceCapabilitiesKHR;
    vkGetPhysicalDeviceSurfaceCapabilitiesKHR(device_context.physical_device, device_context.surface, *capabilities);

    swapchain_context.extent = capabilities.currentExtent;
    if swapchain_context.extent.width == U32_MAX {
        swapchain_context.extent.width  = clamp(main_context.window_width,  capabilities.minImageExtent.width,  capabilities.maxImageExtent.width);
        swapchain_context.extent.height = clamp(main_context.window_height, capabilities.minImageExtent.height, capabilities.maxImageExtent.height);
    }

    swapchain_create_info := VkSwapchainCreateInfoKHR.{
        surface          = device_context.surface,
        minImageCount    = xx ifx present_mode == .MAILBOX then 3 else 2,
        imageFormat      = swapchain_context.surface_format.format,
        imageColorSpace  = swapchain_context.surface_format.colorSpace,
        imageExtent      = swapchain_context.extent,
        imageArrayLayers = 1,
        imageUsage       = .COLOR_ATTACHMENT | .TRANSFER_SRC,
        imageSharingMode = .EXCLUSIVE,
        preTransform     = capabilities.currentTransform,
        compositeAlpha   = .OPAQUE,
        presentMode      = present_mode,
        clipped          = VK_TRUE,
    };
    result := vkCreateSwapchainKHR(device_context.device, *swapchain_create_info, null, *swapchain_context.swapchain);
    assert(result == .SUCCESS);

    vkGetSwapchainImagesKHR(device_context.device, swapchain_context.swapchain, *swapchain_context.image_count, null);
    assert(swapchain_context.image_count <= MAX_SWAPCHAIN_IMAGES, "The driver returned % swapchain images, but MAX_SWAPCHAIN_IMAGES is %.", swapchain_context.image_count, MAX_SWAPCHAIN_IMAGES);
    vkGetSwapchainImagesKHR(device_context.device, swapchain_context.swapchain, *swapchain_context.image_count, swapchain_context.images.data);

    for 0..swapchain_context.image_count-1 {
        view_create_info := VkImageViewCreateInfo.{
            image            = swapchain_context.images[it],
            viewType         = .e2D,
            format           = swapchain_context.surface_format.format,
            subresourceRange = .{aspectMask = .COLOR, levelCount = 1, layerCount = 1},
        };
        result = vkCreateImageView(device_context.device, *view_create_info, null, *swapchain_context.views[it]);
        assert(result == .SUCCESS);

        set_debug_name(.IMAGE,      swapchain_context.images[it], tprint("swapchain image %", it));
        set_debug_name(.IMAGE_VIEW, swapchain_context.views[it],  tprint("swapchain view %", it));
    }

    log("Swapchain: %x%, % (%), %, % images.", swapchain_context.extent.width, swapchain_context.extent.height, swapchain_context.surface_format.format, swapchain_context.surface_format.colorSpace, present_mode, swapchain_context.image_count);
}

deinit_swapchain :: () {
    for 0..swapchain_context.image_count-1  vkDestroyImageView(device_context.device, swapchain_context.views[it], null);
    vkDestroySwapchainKHR(device_context.device, swapchain_context.swapchain, null);
}
