// Graphics
// Scene

Vertex :: struct {
    position    : Vector3;
    color       : Vector3;
    uv          : Vector2;
}

vertices := Vertex.[
    .{position = .{-0.5, -0.5,  0.0}, color = .{1, 0, 0}, uv = .{0.0, 0.0}},
    .{position = .{ 0.5,  0.5,  0.0}, color = .{0, 0, 1}, uv = .{1.0, 1.0}},
    .{position = .{-0.5,  0.5,  0.0}, color = .{1, 1, 0}, uv = .{0.0, 1.0}},

    .{position = .{-0.5, -0.5,  0.0}, color = .{1, 0, 0}, uv = .{0.0, 0.0}},
    .{position = .{ 0.5, -0.5,  0.0}, color = .{0, 1, 0}, uv = .{1.0, 0.0}},
    .{position = .{ 0.5,  0.5,  0.0}, color = .{0, 0, 1}, uv = .{1.0, 1.0}},

    // Ground plane at y = +1 (+Y is down), facing up toward the camera.
    .{position = .{-3.0,  1.0,  3.0}, color = .{0.5, 0.5, 0.5}, uv = .{0.0, 0.0}},
    .{position = .{ 3.0,  1.0, -3.0}, color = .{0.5, 0.5, 0.5}, uv = .{6.0, 6.0}},
    .{position = .{-3.0,  1.0, -3.0}, color = .{0.5, 0.5, 0.5}, uv = .{0.0, 6.0}},

    .{position = .{-3.0,  1.0,  3.0}, color = .{0.5, 0.5, 0.5}, uv = .{0.0, 0.0}},
    .{position = .{ 3.0,  1.0,  3.0}, color = .{0.5, 0.5, 0.5}, uv = .{6.0, 0.0}},
    .{position = .{ 3.0,  1.0, -3.0}, color = .{0.5, 0.5, 0.5}, uv = .{6.0, 6.0}},
];

Draw_Data :: struct {
    vertices : VkDeviceAddress;
    texture  : [2] u32;
    sampler  : [2] u32;
}

init_data :: () {
    result : VkResult;

    texture_width  := cast(u32) program_state.texture_datas[0].width;
    texture_height := cast(u32) program_state.texture_datas[0].height;
    texture_format : VkFormat = .R8G8B8A8_UNORM;

    use_host_image_copy := false;
    {
        using physical_device_context;

        if vulkan_1_4_features.hostImageCopy {
            format_properties_3 : VkFormatProperties3;
            format_properties_2 := VkFormatProperties2.{pNext = *format_properties_3};
            vkGetPhysicalDeviceFormatProperties2(physical_device, texture_format, *format_properties_2);
            format_supports_host_copy := (format_properties_3.optimalTilingFeatures & .HOST_IMAGE_TRANSFER) != 0;

            has_dedicated_transfer_family := queue_family_indices.transfer != queue_family_indices.graphics;

            use_host_image_copy = format_supports_host_copy && !has_dedicated_transfer_family;
        }
    }

    log("Uploading textures via %.\n", ifx use_host_image_copy then "host image copy" else "device copy");

    // Staging data for the texture upload.
    if !use_host_image_copy {
        using program_state;

        staging_size   = cast(u64, size_of(u32) * texture_datas[0].width * texture_datas[0].height);
        staging_offset = arena_suballocate(staging_size, 256);

        memcpy(arena_pointer(staging_offset), texture_datas[0].bytes, xx staging_size);
    }

    // Texture
    {
        // Image
        {
            image_create_info : VkImageCreateInfo;
            {
                using image_create_info;
                imageType = .e2D;
                format = texture_format;
                extent = .{width = texture_width, height = texture_height, depth = 1};
                mipLevels = 1;
                arrayLayers = 1;
                samples = .e1;
                tiling = .OPTIMAL;
                usage = .SAMPLED | .TRANSFER_DST;
                if use_host_image_copy then usage = .SAMPLED | .HOST_TRANSFER;
                sharingMode = .EXCLUSIVE;
                initialLayout = .UNDEFINED;
            }

            // Create
            {
                result = vkCreateImage(device, *image_create_info, null, *texture.image);
                assert(result == .SUCCESS);
            }

            // Bind Memory
            {
                memory_requirements : VkMemoryRequirements;
                vkGetImageMemoryRequirements(device, texture.image, *memory_requirements);

                {
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

                    set_debug_name(.IMAGE,         texture.image,  "texture");
                    set_debug_name(.DEVICE_MEMORY, texture.memory, "texture memory");
                }
            }

            if use_host_image_copy {
                {
                    using host_image_layout_transition_info : VkHostImageLayoutTransitionInfo;
                    image = texture.image;
                    oldLayout = .UNDEFINED;
                    newLayout = .GENERAL;
                    subresourceRange = .{
                        aspectMask = .COLOR,
                        levelCount = VK_REMAINING_MIP_LEVELS,
                        layerCount = VK_REMAINING_ARRAY_LAYERS,
                    };

                    result = vkTransitionImageLayout(device, 1, *host_image_layout_transition_info);
                    assert(result == .SUCCESS);
                }

                {
                    region : VkMemoryToImageCopy;
                    {
                        using region;
                        pHostPointer = program_state.texture_datas[0].bytes;
                        imageSubresource = .{
                            aspectMask = .COLOR,
                            layerCount = VK_REMAINING_ARRAY_LAYERS,
                        };
                        imageExtent = .{texture_width, texture_height, 1};
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
                {
                    subresource_range : VkImageSubresourceRange;
                    {
                        using subresource_range;
                        aspectMask     = .COLOR;
                        levelCount     = VK_REMAINING_MIP_LEVELS;
                        layerCount     = VK_REMAINING_ARRAY_LAYERS;
                    }

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

                    vkCmdPipelineBarrier2(command_buffers[0], *dependency_info);
                }

                // Copy from the arena's staging region, addressed directly.
                {
                    region : VkDeviceMemoryImageCopyKHR;
                    {
                        using region;
                        addressRange = .{
                            address = arena_address(staging_offset),
                            size    = staging_size,
                        };
                        addressFlags = .STORAGE_BUFFER_USAGE;
                        imageSubresource = .{
                            aspectMask = .COLOR,
                            layerCount = VK_REMAINING_ARRAY_LAYERS,
                        };
                        imageLayout = .GENERAL;
                        imageExtent = .{texture_width, texture_height, 1};
                    }

                    using copy_info : VkCopyDeviceMemoryImageInfoKHR;
                    image = texture.image;
                    regionCount = 1;
                    pRegions = *region;

                    vkCmdCopyMemoryToImageKHR(command_buffers[0], *copy_info);
                }
            }
        }

        {
            {
                view_create_info : VkImageViewCreateInfo;
                {
                    using view_create_info;
                    image    = texture.image;
                    viewType = .e2D;
                    format   = .R8G8B8A8_UNORM;
                    subresourceRange = .{
                        aspectMask = .COLOR,
                        levelCount = VK_REMAINING_MIP_LEVELS,
                        layerCount = VK_REMAINING_ARRAY_LAYERS,
                    };
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
                    address = arena_pointer(resource_heap_offset + first_image_id * image_descriptor_stride),
                    size    = image_descriptor_stride,
                };

                result = vkWriteResourceDescriptorsEXT(device, 1, *resource_descriptor_info, *destination);
                assert(result == .SUCCESS);
            }

            {
                sampler_create_info : VkSamplerCreateInfo;
                {
                    using sampler_create_info;
                    magFilter    = .NEAREST;
                    minFilter    = .NEAREST;
                    mipmapMode   = .NEAREST;
                    addressModeU = .REPEAT;
                    addressModeV = .REPEAT;
                    addressModeW = .REPEAT;
                    maxLod       = VK_LOD_CLAMP_NONE;
                    borderColor  = .INT_OPAQUE_BLACK;
                }

                destination := VkHostAddressRangeEXT.{
                    address = arena_pointer(sampler_heap_offset + first_sampler_id * sampler_descriptor_stride),
                    size    = sampler_descriptor_stride,
                };

                result = vkWriteSamplerDescriptorsEXT(device, 1, *sampler_create_info, *destination);
                assert(result == .SUCCESS);
            }
        }
    }

    // Vertex data lives in the arena and is bound by address.
    {
        vertex_size   = size_of(type_of(vertices));
        vertex_offset = arena_suballocate(vertex_size, 256);

        memcpy(arena_pointer(vertex_offset), *vertices, xx vertex_size);
    }

    {
        draw_data_offset = arena_suballocate(size_of(Draw_Data), 256);

        draw_data := cast(*Draw_Data) arena_pointer(draw_data_offset);
        draw_data.vertices = arena_address(vertex_offset);
        draw_data.texture  = .[first_image_id,   0];
        draw_data.sampler  = .[first_sampler_id, 0];
    }
}

deinit_data :: () {
    vkDestroyImage(device, texture.image, null);
    vkFreeMemory(device, texture.memory, null);
}
