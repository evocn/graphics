// Graphics
// Swapchain

swapchain_context : struct {
    MAX_SWAPCHAIN_IMAGES   :: 3;
    DEPTH_FORMAT : VkFormat : .D32_SFLOAT;
    swapchain       : VkSwapchainKHR;
    surface_format  : VkSurfaceFormatKHR;
    extent      : VkExtent2D;
    image_count : u32;
    images      : [MAX_SWAPCHAIN_IMAGES] VkImage;
    views       : [MAX_SWAPCHAIN_IMAGES] VkImageView;

    depth_image     : VkImage;
    depth_view      : VkImageView;

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

    needs_recreation : bool;
}

init_swapchain :: (width: u32, height: u32) {
    result : VkResult;
    using physical_device_context;

    surface_format_count : u32 = ---;
    surface_formats : [..] VkSurfaceFormatKHR;
    defer array_free(surface_formats);
    result = vkGetPhysicalDeviceSurfaceFormatsKHR(physical_device, surface, *surface_format_count, null);
    assert(result == .SUCCESS);
    array_resize(*surface_formats, surface_format_count, initialize=false);

    result = vkGetPhysicalDeviceSurfaceFormatsKHR(physical_device, surface, *surface_format_count, surface_formats.data);
    assert(result == .SUCCESS);

    preferred_formats :: VkFormat.[.B8G8R8A8_SRGB, .R8G8B8A8_SRGB];

    swapchain_context.surface_format = surface_formats[0];
    for preferred : preferred_formats {
        for surface_formats {
            if it.format == preferred && it.colorSpace == .SRGB_NONLINEAR {
                swapchain_context.surface_format = it;
                break preferred;
            }
        }
    }
    log("Swapchain format: % (%).", swapchain_context.surface_format.format, swapchain_context.surface_format.colorSpace);

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
 
    swapchain_context.image_count = ifx chosen_present_mode == .MAILBOX  then PRESENT_MODE_MAILBOX_IMAGE_COUNT else  PRESENT_MODE_DEFAULT_IMAGE_COUNT;

    surface_capabilities: VkSurfaceCapabilitiesKHR;
    vkGetPhysicalDeviceSurfaceCapabilitiesKHR(physical_device, surface, *surface_capabilities);

    swapchain_context.extent = surface_capabilities.currentExtent;
    if swapchain_context.extent.width == U32_MAX {
        swapchain_context.extent.width  = clamp(
            width,
            surface_capabilities.minImageExtent.width,
            surface_capabilities.maxImageExtent.width
        );
        swapchain_context.extent.height = clamp(
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
        minImageCount               = swapchain_context.image_count;
        imageFormat                 = swapchain_context.surface_format.format;
        imageColorSpace             = swapchain_context.surface_format.colorSpace;
        imageExtent                 = swapchain_context.extent;
        imageArrayLayers            = 1;
        imageUsage                  = .COLOR_ATTACHMENT | .TRANSFER_SRC;
        imageSharingMode            = .EXCLUSIVE;
        preTransform                = surface_capabilities.currentTransform;
        compositeAlpha              = .OPAQUE;
        presentMode                 = chosen_present_mode;
        clipped                     = VK_TRUE;
    }
    
    result = vkCreateSwapchainKHR(device, *swapchain_create_info, null, *swapchain_context.swapchain);
    assert(result == .SUCCESS);

    result = vkGetSwapchainImagesKHR(device, swapchain_context.swapchain, *swapchain_context.image_count, null);
    assert(result == .SUCCESS);

    assert(swapchain_context.image_count <= swapchain_context.MAX_SWAPCHAIN_IMAGES,
           "The driver returned % swapchain images, but MAX_SWAPCHAIN_IMAGES is %.",
           swapchain_context.image_count, swapchain_context.MAX_SWAPCHAIN_IMAGES);

    result = vkGetSwapchainImagesKHR(device, swapchain_context.swapchain, *swapchain_context.image_count, swapchain_context.images.data);
    assert(result == .SUCCESS);

    // Create image views of all swapchain images
    {
        for 0..swapchain_context.image_count-1 {
            image_view_create_info : VkImageViewCreateInfo;

            {
                using image_view_create_info;
                image = swapchain_context.images[it];
                viewType = .e2D;
                format = swapchain_context.surface_format.format;
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

            result = vkCreateImageView(device, *image_view_create_info, null, *swapchain_context.views[it]);
            assert(result == .SUCCESS);

            set_debug_name(.IMAGE,      swapchain_context.images[it], tprint("swapchain image %", it));
            set_debug_name(.IMAGE_VIEW, swapchain_context.views[it],  tprint("swapchain view %", it));
        }
    }

    // Depth buffer
    {
        {
            image_create_info : VkImageCreateInfo;
            {
                using image_create_info;
                imageType = .e2D;
                format = swapchain_context.DEPTH_FORMAT;
                extent = .{width = swapchain_context.extent.width, height = swapchain_context.extent.height, depth = 1};
                mipLevels = 1;
                arrayLayers = 1;
                samples = .e1;
                tiling = .OPTIMAL;
                usage = .DEPTH_STENCIL_ATTACHMENT;
                sharingMode = .EXCLUSIVE;
                initialLayout = .UNDEFINED;
            }

            result = vkCreateImage(device, *image_create_info, null, *swapchain_context.depth_image);
            assert(result == .SUCCESS);
        }

        heap_bind_image(*heaps.render_target, swapchain_context.depth_image);

        {
            image_view_create_info : VkImageViewCreateInfo;
            {
                using image_view_create_info;
                image = swapchain_context.depth_image;
                viewType = .e2D;
                format = swapchain_context.DEPTH_FORMAT;

                subresourceRange.aspectMask = .DEPTH;
                subresourceRange.baseMipLevel = 0;
                subresourceRange.levelCount = 1;
                subresourceRange.baseArrayLayer = 0;
                subresourceRange.layerCount = 1;
            }

            result = vkCreateImageView(device, *image_view_create_info, null, *swapchain_context.depth_view);
            assert(result == .SUCCESS);
        }

        set_debug_name(.IMAGE,      swapchain_context.depth_image, "depth image");
        set_debug_name(.IMAGE_VIEW, swapchain_context.depth_view,  "depth view");
    }

    {
        image_create_info := VkImageCreateInfo.{
            imageType     = .e2D,
            format        = swapchain_context.HDR_FORMAT,
            extent        = .{width = swapchain_context.extent.width, height = swapchain_context.extent.height, depth = 1},
            mipLevels     = 1,
            arrayLayers   = 1,
            samples       = .e1,
            tiling        = .OPTIMAL,
            usage         = .COLOR_ATTACHMENT | .SAMPLED,
            sharingMode   = .EXCLUSIVE,
            initialLayout = .UNDEFINED,
        };
        result = vkCreateImage(device, *image_create_info, null, *swapchain_context.hdr_image);
        assert(result == .SUCCESS);

        heap_bind_image(*heaps.render_target, swapchain_context.hdr_image);

        view_create_info := VkImageViewCreateInfo.{
            image            = swapchain_context.hdr_image,
            viewType         = .e2D,
            format           = swapchain_context.HDR_FORMAT,
            subresourceRange = .{aspectMask = .COLOR, levelCount = 1, layerCount = 1},
        };
        result = vkCreateImageView(device, *view_create_info, null, *swapchain_context.hdr_view);
        assert(result == .SUCCESS);

        if !swapchain_context.hdr_texture_allocated {
            swapchain_context.hdr_texture = create_image_descriptor(view_create_info);
            swapchain_context.hdr_texture_allocated = true;
        } else {
            write_image_descriptor(swapchain_context.hdr_texture, view_create_info);
        }

        set_debug_name(.IMAGE,      swapchain_context.hdr_image, "hdr image");
        set_debug_name(.IMAGE_VIEW, swapchain_context.hdr_view,  "hdr view");
    }

    for 0..1 {
        image_create_info := VkImageCreateInfo.{
            imageType     = .e2D,
            format        = swapchain_context.AMBIENT_FORMAT,
            extent        = .{width = swapchain_context.extent.width, height = swapchain_context.extent.height, depth = 1},
            mipLevels     = 1,
            arrayLayers   = 1,
            samples       = .e1,
            tiling        = .OPTIMAL,
            usage         = .STORAGE,
            sharingMode   = .EXCLUSIVE,
            initialLayout = .UNDEFINED,
        };
        result = vkCreateImage(device, *image_create_info, null, *swapchain_context.ambient_images[it]);
        assert(result == .SUCCESS);

        heap_bind_image(*heaps.render_target, swapchain_context.ambient_images[it]);

        view_create_info := VkImageViewCreateInfo.{
            image            = swapchain_context.ambient_images[it],
            viewType         = .e2D,
            format           = swapchain_context.AMBIENT_FORMAT,
            subresourceRange = .{aspectMask = .COLOR, levelCount = 1, layerCount = 1},
        };
        result = vkCreateImageView(device, *view_create_info, null, *swapchain_context.ambient_views[it]);
        assert(result == .SUCCESS);

        if !swapchain_context.ambient_storage_allocated {
            swapchain_context.ambient_storages[it] = create_storage_image_descriptor(view_create_info);
        } else {
            write_storage_image_descriptor(swapchain_context.ambient_storages[it], view_create_info);
        }

        set_debug_name(.IMAGE,      swapchain_context.ambient_images[it], tprint("ambient image %", it));
        set_debug_name(.IMAGE_VIEW, swapchain_context.ambient_views[it],  tprint("ambient view %", it));
    }
    swapchain_context.ambient_storage_allocated = true;
    swapchain_context.ambient_initialized = false;
}

deinit_swapchain :: () {
    for 0..1 {
        vkDestroyImageView(device, swapchain_context.ambient_views[it], null);
        vkDestroyImage(device, swapchain_context.ambient_images[it], null);
    }
    vkDestroyImageView(device, swapchain_context.hdr_view, null);
    vkDestroyImage(device, swapchain_context.hdr_image, null);
    vkDestroyImageView(device, swapchain_context.depth_view, null);
    vkDestroyImage(device, swapchain_context.depth_image, null);
    heap_reset(*heaps.render_target);

    for image_index : 0..swapchain_context.image_count-1 {
        vkDestroyImageView(device, swapchain_context.views[image_index], null);
    }
    vkDestroySwapchainKHR(device, swapchain_context.swapchain, null);
}

recreate_swapchain :: (width: u32, height: u32, present_fences: [] VkFence) -> ready: bool {
    surface_capabilities : VkSurfaceCapabilitiesKHR;
    vkGetPhysicalDeviceSurfaceCapabilitiesKHR(physical_device_context.physical_device, surface, *surface_capabilities);

    if surface_capabilities.currentExtent.width == 0 || surface_capabilities.currentExtent.height == 0 {
        return false;
    }

    vkDeviceWaitIdle(device);

    fence_result := vkWaitForFences(device, xx present_fences.count, present_fences.data, VK_TRUE, U64_MAX);
    assert(fence_result == .SUCCESS);

    deinit_swapchain();
    init_swapchain(width, height);

    swapchain_context.needs_recreation = false;
    return true;
}
