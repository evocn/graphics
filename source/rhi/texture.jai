Texture :: struct {
    image  : VkImage;
    handle : Texture_Handle;
}

create_texture :: (command_buffer: VkCommandBuffer, pixels: *void, width: u32, height: u32, format: VkFormat, name: string) -> Texture {
    result : VkResult;
    texture : Texture;

    size := cast(VkDeviceSize) (4 * width * height);

    use_host_image_copy := false;
    {
        using physical_device_context;

        if vulkan_1_4_features.hostImageCopy {
            format_properties_3 : VkFormatProperties3;
            format_properties_2 := VkFormatProperties2.{pNext = *format_properties_3};
            vkGetPhysicalDeviceFormatProperties2(physical_device, format, *format_properties_2);
            format_supports_host_copy := (format_properties_3.optimalTilingFeatures & .HOST_IMAGE_TRANSFER) != 0;

            has_dedicated_transfer_family := queue_family_indices.transfer != queue_family_indices.graphics;

            use_host_image_copy = format_supports_host_copy && !has_dedicated_transfer_family;
        }
    }

    {
        image_create_info := VkImageCreateInfo.{
            imageType     = .e2D,
            format        = format,
            extent        = .{width = width, height = height, depth = 1},
            mipLevels     = 1,
            arrayLayers   = 1,
            samples       = .e1,
            tiling        = .OPTIMAL,
            usage         = ifx use_host_image_copy then .SAMPLED | .HOST_TRANSFER else .SAMPLED | .TRANSFER_DST,
            sharingMode   = .EXCLUSIVE,
            initialLayout = .UNDEFINED,
        };

        result = vkCreateImage(device, *image_create_info, null, *texture.image);
        assert(result == .SUCCESS);
    }

    heap_bind_image(*heaps.image, texture.image);
    set_debug_name(.IMAGE, texture.image, name);

    subresource_range := VkImageSubresourceRange.{
        aspectMask = .COLOR,
        levelCount = VK_REMAINING_MIP_LEVELS,
        layerCount = VK_REMAINING_ARRAY_LAYERS,
    };

    if use_host_image_copy {
        {
            using host_image_layout_transition_info : VkHostImageLayoutTransitionInfo;
            image = texture.image;
            oldLayout = .UNDEFINED;
            newLayout = .GENERAL;
            subresourceRange = subresource_range;

            result = vkTransitionImageLayout(device, 1, *host_image_layout_transition_info);
            assert(result == .SUCCESS);
        }

        {
            region : VkMemoryToImageCopy;
            {
                using region;
                pHostPointer = pixels;
                imageSubresource = .{
                    aspectMask = .COLOR,
                    layerCount = VK_REMAINING_ARRAY_LAYERS,
                };
                imageExtent = .{width, height, 1};
            }

            using copy_memory_to_image_info : VkCopyMemoryToImageInfo;
            dstImage = texture.image;
            dstImageLayout = .GENERAL;
            regionCount = 1;
            pRegions = *region;

            result = vkCopyMemoryToImage(device, *copy_memory_to_image_info);
            assert(result == .SUCCESS);
        }
    }
    else {
        staging_offset := heap_allocate(*heaps.scratch, size, 256);
        memcpy(heap_pointer(*heaps.scratch, staging_offset), pixels, xx size);

        {
            image_memory_barrier : VkImageMemoryBarrier2;
            {
                using image_memory_barrier;
                srcStageMask        = .NONE;
                srcAccessMask       = .NONE;
                dstStageMask        = .COPY;
                dstAccessMask       = .TRANSFER_WRITE;
                oldLayout           = .UNDEFINED;
                newLayout           = .GENERAL;
                srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
                dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
                image               = texture.image;
                subresourceRange    = subresource_range;
            }

            dependency_info : VkDependencyInfo;
            {
                using dependency_info;
                imageMemoryBarrierCount = 1;
                pImageMemoryBarriers    = *image_memory_barrier;
            }

            vkCmdPipelineBarrier2(command_buffer, *dependency_info);
        }

        {
            region : VkDeviceMemoryImageCopyKHR;
            {
                using region;
                addressRange = .{
                    address = heap_address(*heaps.scratch, staging_offset),
                    size    = size,
                };
                addressFlags = .STORAGE_BUFFER_USAGE;
                imageSubresource = .{
                    aspectMask = .COLOR,
                    layerCount = VK_REMAINING_ARRAY_LAYERS,
                };
                imageLayout = .GENERAL;
                imageExtent = .{width, height, 1};
            }

            using copy_info : VkCopyDeviceMemoryImageInfoKHR;
            image = texture.image;
            regionCount = 1;
            pRegions = *region;

            vkCmdCopyMemoryToImageKHR(command_buffer, *copy_info);
        }
    }

    {
        view_create_info := VkImageViewCreateInfo.{
            image            = texture.image,
            viewType         = .e2D,
            format           = format,
            subresourceRange = subresource_range,
        };

        texture.handle = create_image_descriptor(view_create_info);
    }

    log("Uploaded % (%x%) via %.", name, width, height, ifx use_host_image_copy then "host image copy" else "device copy");

    return texture;
}

destroy_texture :: (texture: Texture) {
    vkDestroyImage(device, texture.image, null);
}
