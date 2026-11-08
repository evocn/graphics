Texture :: struct {
    image  : VkImage;
    memory : VkDeviceMemory;
    handle : Texture_Handle;
}

TEXTURE_FORMAT :: VkFormat.R8G8B8A8_UNORM;

create_texture :: (command_buffer: VkCommandBuffer, pixels: *void, width: u32, height: u32, name: string) -> Texture {
    result : VkResult;
    texture : Texture;

    size := cast(VkDeviceSize) (4 * width * height);

    use_host_image_copy := false;
    {
        using physical_device_context;

        if vulkan_1_4_features.hostImageCopy {
            format_properties_3 : VkFormatProperties3;
            format_properties_2 := VkFormatProperties2.{pNext = *format_properties_3};
            vkGetPhysicalDeviceFormatProperties2(physical_device, TEXTURE_FORMAT, *format_properties_2);
            format_supports_host_copy := (format_properties_3.optimalTilingFeatures & .HOST_IMAGE_TRANSFER) != 0;

            has_dedicated_transfer_family := queue_family_indices.transfer != queue_family_indices.graphics;

            use_host_image_copy = format_supports_host_copy && !has_dedicated_transfer_family;
        }
    }

    {
        image_create_info : VkImageCreateInfo;
        {
            using image_create_info;
            imageType = .e2D;
            format = TEXTURE_FORMAT;
            extent = .{width = width, height = height, depth = 1};
            mipLevels = 1;
            arrayLayers = 1;
            samples = .e1;
            tiling = .OPTIMAL;
            usage = ifx use_host_image_copy then .SAMPLED | .HOST_TRANSFER else .SAMPLED | .TRANSFER_DST;
            sharingMode = .EXCLUSIVE;
            initialLayout = .UNDEFINED;
        }

        result = vkCreateImage(device, *image_create_info, null, *texture.image);
        assert(result == .SUCCESS);
    }

    {
        memory_requirements : VkMemoryRequirements;
        vkGetImageMemoryRequirements(device, texture.image, *memory_requirements);

        success, memory_type_index := select_memory_type(physical_device_context.memory_properties, memory_requirements.memoryTypeBits, .DEVICE_LOCAL);
        assert(success);
        assert(memory_type_index != -1);

        {
            using allocate_info : VkMemoryAllocateInfo;
            allocationSize = memory_requirements.size;
            memoryTypeIndex = xx memory_type_index;

            result = vkAllocateMemory(device, *allocate_info, null, *texture.memory);
            assert(result == .SUCCESS);
        }
        result = vkBindImageMemory(device, texture.image, texture.memory, 0);
        assert(result == .SUCCESS);

        set_debug_name(.IMAGE,         texture.image,  name);
        set_debug_name(.DEVICE_MEMORY, texture.memory, tprint("% memory", name));
    }

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
        staging_offset := arena_suballocate(size, 256);
        memcpy(arena_pointer(staging_offset), pixels, xx size);

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
                    address = arena_address(staging_offset),
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

    texture.handle = .{id = take_image_id()};
    {
        view_create_info : VkImageViewCreateInfo;
        {
            using view_create_info;
            image    = texture.image;
            viewType = .e2D;
            format   = TEXTURE_FORMAT;
            subresourceRange = subresource_range;
        }

        image_descriptor_info : VkImageDescriptorInfoEXT;
        {
            using image_descriptor_info;
            pView  = *view_create_info;
            layout = .GENERAL;
        }

        resource_descriptor_info : VkResourceDescriptorInfoEXT;
        {
            using resource_descriptor_info;
            type = .SAMPLED_IMAGE;
            data.pImage = *image_descriptor_info;
        }

        destination := VkHostAddressRangeEXT.{
            address = arena_pointer(resource_heap_offset + texture.handle.id * image_descriptor_stride),
            size    = image_descriptor_stride,
        };

        result = vkWriteResourceDescriptorsEXT(device, 1, *resource_descriptor_info, *destination);
        assert(result == .SUCCESS);
    }

    log("Uploaded % (%x%) via %.", name, width, height, ifx use_host_image_copy then "host image copy" else "device copy");

    return texture;
}

destroy_texture :: (texture: Texture) {
    vkDestroyImage(device, texture.image, null);
    vkFreeMemory(device, texture.memory, null);
}

create_sampler :: (sampler_create_info: VkSamplerCreateInfo) -> Sampler_Handle {
    id := take_sampler_id();

    info := sampler_create_info;
    destination := VkHostAddressRangeEXT.{
        address = arena_pointer(sampler_heap_offset + id * sampler_descriptor_stride),
        size    = sampler_descriptor_stride,
    };

    result := vkWriteSamplerDescriptorsEXT(device, 1, *info, *destination);
    assert(result == .SUCCESS);

    return .{id = id};
}
