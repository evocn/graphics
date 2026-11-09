MAX_SWAPCHAIN_IMAGES :: 3;

swapchain                  : VkSwapchainKHR;
surface_format             : VkSurfaceFormatKHR;
swapchain_extent           : VkExtent2D;
swapchain_image_count      : u32;
swapchain_images           : [MAX_SWAPCHAIN_IMAGES] VkImage;
swapchain_views            : [MAX_SWAPCHAIN_IMAGES] VkImageView;
swapchain_needs_recreation : bool;

init_swapchain :: () {
    format_count : u32;
    vkGetPhysicalDeviceSurfaceFormatsKHR(physical_device, surface, *format_count, null);
    formats := NewArray(format_count, VkSurfaceFormatKHR,, temp);
    vkGetPhysicalDeviceSurfaceFormatsKHR(physical_device, surface, *format_count, formats.data);

    surface_format = formats[0];
    for preferred : VkFormat.[.B8G8R8A8_SRGB, .R8G8B8A8_SRGB] {
        for formats {
            if it.format == preferred && it.colorSpace == .SRGB_NONLINEAR {
                surface_format = it;
                break preferred;
            }
        }
    }

    mode_count : u32;
    vkGetPhysicalDeviceSurfacePresentModesKHR(physical_device, surface, *mode_count, null);
    modes := NewArray(mode_count, VkPresentModeKHR,, temp);
    vkGetPhysicalDeviceSurfacePresentModesKHR(physical_device, surface, *mode_count, modes.data);

    present_mode := VkPresentModeKHR.FIFO;
    if array_find(modes, .MAILBOX)  present_mode = .MAILBOX;

    capabilities : VkSurfaceCapabilitiesKHR;
    vkGetPhysicalDeviceSurfaceCapabilitiesKHR(physical_device, surface, *capabilities);

    swapchain_extent = capabilities.currentExtent;
    if swapchain_extent.width == U32_MAX {
        swapchain_extent.width  = clamp(window_width,  capabilities.minImageExtent.width,  capabilities.maxImageExtent.width);
        swapchain_extent.height = clamp(window_height, capabilities.minImageExtent.height, capabilities.maxImageExtent.height);
    }

    swapchain_create_info := VkSwapchainCreateInfoKHR.{
        surface          = surface,
        minImageCount    = xx ifx present_mode == .MAILBOX then 3 else 2,
        imageFormat      = surface_format.format,
        imageColorSpace  = surface_format.colorSpace,
        imageExtent      = swapchain_extent,
        imageArrayLayers = 1,
        imageUsage       = .COLOR_ATTACHMENT | .TRANSFER_SRC,
        imageSharingMode = .EXCLUSIVE,
        preTransform     = capabilities.currentTransform,
        compositeAlpha   = .OPAQUE,
        presentMode      = present_mode,
        clipped          = VK_TRUE,
    };
    result := vkCreateSwapchainKHR(device, *swapchain_create_info, null, *swapchain);
    assert(result == .SUCCESS);

    vkGetSwapchainImagesKHR(device, swapchain, *swapchain_image_count, null);
    assert(swapchain_image_count <= MAX_SWAPCHAIN_IMAGES, "The driver returned % swapchain images, but MAX_SWAPCHAIN_IMAGES is %.", swapchain_image_count, MAX_SWAPCHAIN_IMAGES);
    vkGetSwapchainImagesKHR(device, swapchain, *swapchain_image_count, swapchain_images.data);

    for 0..swapchain_image_count-1 {
        view_create_info := VkImageViewCreateInfo.{
            image            = swapchain_images[it],
            viewType         = .e2D,
            format           = surface_format.format,
            subresourceRange = .{aspectMask = .COLOR, levelCount = 1, layerCount = 1},
        };
        result = vkCreateImageView(device, *view_create_info, null, *swapchain_views[it]);
        assert(result == .SUCCESS);

        set_debug_name(.IMAGE,      swapchain_images[it], tprint("swapchain image %", it));
        set_debug_name(.IMAGE_VIEW, swapchain_views[it],  tprint("swapchain view %", it));
    }

    log("Swapchain: %x%, % (%), %, % images.", swapchain_extent.width, swapchain_extent.height, surface_format.format, surface_format.colorSpace, present_mode, swapchain_image_count);
}

deinit_swapchain :: () {
    for 0..swapchain_image_count-1  vkDestroyImageView(device, swapchain_views[it], null);
    vkDestroySwapchainKHR(device, swapchain, null);
}
