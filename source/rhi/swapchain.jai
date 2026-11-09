MAX_SWAPCHAIN_IMAGES :: 3;

swapchain                  : VkSwapchainKHR;
surface_format             : VkSurfaceFormatKHR;
swapchain_extent           : VkExtent2D;
swapchain_image_count      : u32;
swapchain_images           : [MAX_SWAPCHAIN_IMAGES] VkImage;
swapchain_views            : [MAX_SWAPCHAIN_IMAGES] VkImageView;
swapchain_needs_recreation : bool;

DEPTH_FORMAT : VkFormat : .D32_SFLOAT;
depth_image : VkImage;
depth_view  : VkImageView;

HDR_FORMAT : VkFormat : .R16G16B16A16_SFLOAT;
hdr_image             : VkImage;
hdr_view              : VkImageView;
hdr_texture           : Texture_Handle;
hdr_texture_allocated : bool;

AMBIENT_FORMAT : VkFormat : .R16G16B16A16_SFLOAT;
ambient_images            : [2] VkImage;
ambient_views             : [2] VkImageView;
ambient_storages          : [2] Storage_Image_Handle;
ambient_storage_allocated : bool;
ambient_initialized       : bool;

init_swapchain :: (width: u32, height: u32) {
    result : VkResult;

    surface_format_count : u32 = ---;
    surface_formats : [..] VkSurfaceFormatKHR;
    defer array_free(surface_formats);
    result = vkGetPhysicalDeviceSurfaceFormatsKHR(physical_device, surface, *surface_format_count, null);
    assert(result == .SUCCESS);
    array_resize(*surface_formats, surface_format_count, initialize=false);

    result = vkGetPhysicalDeviceSurfaceFormatsKHR(physical_device, surface, *surface_format_count, surface_formats.data);
    assert(result == .SUCCESS);

    preferred_formats :: VkFormat.[.B8G8R8A8_SRGB, .R8G8B8A8_SRGB];

    surface_format = surface_formats[0];
    for preferred : preferred_formats {
        for surface_formats {
            if it.format == preferred && it.colorSpace == .SRGB_NONLINEAR {
                surface_format = it;
                break preferred;
            }
        }
    }
    log("Swapchain format: % (%).", surface_format.format, surface_format.colorSpace);

    present_mode_count : u32 = ---;
    present_modes: [..] VkPresentModeKHR;
    defer array_free(present_modes);
    vkGetPhysicalDeviceSurfacePresentModesKHR(physical_device, surface, *present_mode_count, null);
    array_resize(*present_modes, present_mode_count, initialize=false);
    vkGetPhysicalDeviceSurfacePresentModesKHR(physical_device, surface, *present_mode_count, present_modes.data);

    chosen_present_mode : VkPresentModeKHR = .FIFO; // always supported.
    for present_mode : present_modes {
        if present_mode == .MAILBOX {
            chosen_present_mode = .MAILBOX;
            break;
        }
    }

    PRESENT_MODE_MAILBOX_IMAGE_COUNT : u32 : 3;
    PRESENT_MODE_DEFAULT_IMAGE_COUNT : u32 : 2;
 
    swapchain_image_count = ifx chosen_present_mode == .MAILBOX  then PRESENT_MODE_MAILBOX_IMAGE_COUNT else  PRESENT_MODE_DEFAULT_IMAGE_COUNT;

    surface_capabilities: VkSurfaceCapabilitiesKHR;
    vkGetPhysicalDeviceSurfaceCapabilitiesKHR(physical_device, surface, *surface_capabilities);

    swapchain_extent = surface_capabilities.currentExtent;
    if swapchain_extent.width == U32_MAX {
        swapchain_extent.width  = clamp(
            width,
            surface_capabilities.minImageExtent.width,
            surface_capabilities.maxImageExtent.width
        );
        swapchain_extent.height = clamp(
            height,
            surface_capabilities.minImageExtent.height,
            surface_capabilities.maxImageExtent.height
        );
    }

    swapchain_create_info: VkSwapchainCreateInfoKHR;
    the_surface := surface;  // No way yet to avoid importing this with 'using'. Should fix that!
    {
        swapchain_create_info.surface = the_surface;

        using swapchain_create_info;
        minImageCount               = swapchain_image_count;
        imageFormat                 = surface_format.format;
        imageColorSpace             = surface_format.colorSpace;
        imageExtent                 = swapchain_extent;
        imageArrayLayers            = 1;
        imageUsage                  = .COLOR_ATTACHMENT | .TRANSFER_SRC;
        imageSharingMode            = .EXCLUSIVE;
        preTransform                = surface_capabilities.currentTransform;
        compositeAlpha              = .OPAQUE;
        presentMode                 = chosen_present_mode;
        clipped                     = VK_TRUE;
    }
    
    result = vkCreateSwapchainKHR(device, *swapchain_create_info, null, *swapchain);
    assert(result == .SUCCESS);

    result = vkGetSwapchainImagesKHR(device, swapchain, *swapchain_image_count, null);
    assert(result == .SUCCESS);

    assert(swapchain_image_count <= MAX_SWAPCHAIN_IMAGES,
           "The driver returned % swapchain images, but MAX_SWAPCHAIN_IMAGES is %.",
           swapchain_image_count, MAX_SWAPCHAIN_IMAGES);

    result = vkGetSwapchainImagesKHR(device, swapchain, *swapchain_image_count, swapchain_images.data);
    assert(result == .SUCCESS);

    // Create image views of all swapchain images
    {
        for 0..swapchain_image_count-1 {
            image_view_create_info : VkImageViewCreateInfo;

            {
                using image_view_create_info;
                image = swapchain_images[it];
                viewType = .e2D;
                format = surface_format.format;
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

            result = vkCreateImageView(device, *image_view_create_info, null, *swapchain_views[it]);
            assert(result == .SUCCESS);

            set_debug_name(.IMAGE,      swapchain_images[it], tprint("swapchain image %", it));
            set_debug_name(.IMAGE_VIEW, swapchain_views[it],  tprint("swapchain view %", it));
        }
    }

    // Depth buffer
    {
        {
            image_create_info : VkImageCreateInfo;
            {
                using image_create_info;
                imageType = .e2D;
                format = DEPTH_FORMAT;
                extent = .{width = swapchain_extent.width, height = swapchain_extent.height, depth = 1};
                mipLevels = 1;
                arrayLayers = 1;
                samples = .e1;
                tiling = .OPTIMAL;
                usage = .DEPTH_STENCIL_ATTACHMENT;
                sharingMode = .EXCLUSIVE;
                initialLayout = .UNDEFINED;
            }

            result = vkCreateImage(device, *image_create_info, null, *depth_image);
            assert(result == .SUCCESS);
        }

        heap_bind_image(*render_target_heap, depth_image);

        {
            image_view_create_info : VkImageViewCreateInfo;
            {
                using image_view_create_info;
                image = depth_image;
                viewType = .e2D;
                format = DEPTH_FORMAT;

                subresourceRange.aspectMask = .DEPTH;
                subresourceRange.baseMipLevel = 0;
                subresourceRange.levelCount = 1;
                subresourceRange.baseArrayLayer = 0;
                subresourceRange.layerCount = 1;
            }

            result = vkCreateImageView(device, *image_view_create_info, null, *depth_view);
            assert(result == .SUCCESS);
        }

        set_debug_name(.IMAGE,      depth_image, "depth image");
        set_debug_name(.IMAGE_VIEW, depth_view,  "depth view");
    }

    {
        image_create_info := VkImageCreateInfo.{
            imageType     = .e2D,
            format        = HDR_FORMAT,
            extent        = .{width = swapchain_extent.width, height = swapchain_extent.height, depth = 1},
            mipLevels     = 1,
            arrayLayers   = 1,
            samples       = .e1,
            tiling        = .OPTIMAL,
            usage         = .COLOR_ATTACHMENT | .SAMPLED,
            sharingMode   = .EXCLUSIVE,
            initialLayout = .UNDEFINED,
        };
        result = vkCreateImage(device, *image_create_info, null, *hdr_image);
        assert(result == .SUCCESS);

        heap_bind_image(*render_target_heap, hdr_image);

        view_create_info := VkImageViewCreateInfo.{
            image            = hdr_image,
            viewType         = .e2D,
            format           = HDR_FORMAT,
            subresourceRange = .{aspectMask = .COLOR, levelCount = 1, layerCount = 1},
        };
        result = vkCreateImageView(device, *view_create_info, null, *hdr_view);
        assert(result == .SUCCESS);

        if !hdr_texture_allocated {
            hdr_texture = create_image_descriptor(view_create_info);
            hdr_texture_allocated = true;
        } else {
            write_image_descriptor(hdr_texture, view_create_info);
        }

        set_debug_name(.IMAGE,      hdr_image, "hdr image");
        set_debug_name(.IMAGE_VIEW, hdr_view,  "hdr view");
    }

    for 0..1 {
        image_create_info := VkImageCreateInfo.{
            imageType     = .e2D,
            format        = AMBIENT_FORMAT,
            extent        = .{width = swapchain_extent.width, height = swapchain_extent.height, depth = 1},
            mipLevels     = 1,
            arrayLayers   = 1,
            samples       = .e1,
            tiling        = .OPTIMAL,
            usage         = .STORAGE,
            sharingMode   = .EXCLUSIVE,
            initialLayout = .UNDEFINED,
        };
        result = vkCreateImage(device, *image_create_info, null, *ambient_images[it]);
        assert(result == .SUCCESS);

        heap_bind_image(*render_target_heap, ambient_images[it]);

        view_create_info := VkImageViewCreateInfo.{
            image            = ambient_images[it],
            viewType         = .e2D,
            format           = AMBIENT_FORMAT,
            subresourceRange = .{aspectMask = .COLOR, levelCount = 1, layerCount = 1},
        };
        result = vkCreateImageView(device, *view_create_info, null, *ambient_views[it]);
        assert(result == .SUCCESS);

        if !ambient_storage_allocated {
            ambient_storages[it] = create_storage_image_descriptor(view_create_info);
        } else {
            write_storage_image_descriptor(ambient_storages[it], view_create_info);
        }

        set_debug_name(.IMAGE,      ambient_images[it], tprint("ambient image %", it));
        set_debug_name(.IMAGE_VIEW, ambient_views[it],  tprint("ambient view %", it));
    }
    ambient_storage_allocated = true;
    ambient_initialized = false;
}

deinit_swapchain :: () {
    for 0..1 {
        vkDestroyImageView(device, ambient_views[it], null);
        vkDestroyImage(device, ambient_images[it], null);
    }
    vkDestroyImageView(device, hdr_view, null);
    vkDestroyImage(device, hdr_image, null);
    vkDestroyImageView(device, depth_view, null);
    vkDestroyImage(device, depth_image, null);
    heap_reset(*render_target_heap);

    for image_index : 0..swapchain_image_count-1 {
        vkDestroyImageView(device, swapchain_views[image_index], null);
    }
    vkDestroySwapchainKHR(device, swapchain, null);
}

recreate_swapchain :: (width: u32, height: u32, present_fences: [] VkFence) -> ready: bool {
    surface_capabilities : VkSurfaceCapabilitiesKHR;
    vkGetPhysicalDeviceSurfaceCapabilitiesKHR(physical_device, surface, *surface_capabilities);

    if surface_capabilities.currentExtent.width == 0 || surface_capabilities.currentExtent.height == 0 {
        return false;
    }

    vkDeviceWaitIdle(device);

    fence_result := vkWaitForFences(device, xx present_fences.count, present_fences.data, VK_TRUE, U64_MAX);
    assert(fence_result == .SUCCESS);

    deinit_swapchain();
    init_swapchain(width, height);

    swapchain_needs_recreation = false;
    return true;
}
