Texture :: struct {
    image  : VkImage;
    handle : Texture_Handle;
}

create_texture :: (pixels: *void, width: u32, height: u32, format: VkFormat, name: string, generate_mips := true) -> Texture {
    texture : Texture;

    size := cast(VkDeviceSize) (4 * width * height);

    mip_levels : u32 = 1;
    if generate_mips {
        while (max(width, height) >> mip_levels) > 0  mip_levels += 1;
    }

    image_create_info := VkImageCreateInfo.{
        imageType   = .e2D,
        format      = format,
        extent      = .{width = width, height = height, depth = 1},
        mipLevels   = mip_levels,
        arrayLayers = 1,
        samples     = .e1,
        tiling      = .OPTIMAL,
        usage       = .SAMPLED | .TRANSFER_SRC | .TRANSFER_DST,
    };
    result := vkCreateImage(device_context.device, *image_create_info, null, *texture.image);
    assert(result == .SUCCESS);

    heap_bind_image(*heap_context.image, texture.image);
    set_debug_name(.IMAGE, texture.image, name);

    subresource_range := VkImageSubresourceRange.{
        aspectMask = .COLOR,
        levelCount = VK_REMAINING_MIP_LEVELS,
        layerCount = VK_REMAINING_ARRAY_LAYERS,
    };

    staging_offset := heap_allocate(*heap_context.scratch, size, 256);
    memcpy(heap_pointer(*heap_context.scratch, staging_offset), pixels, xx size);

    pipeline_barrier(frame_context.init_command_buffer, .[image_barrier(texture.image, .NONE, .NONE, .ALL_TRANSFER, .TRANSFER_WRITE)]);

    region := VkDeviceMemoryImageCopyKHR.{
        addressRange     = .{address = heap_address(*heap_context.scratch, staging_offset), size = size},
        addressFlags     = .STORAGE_BUFFER_USAGE,
        imageSubresource = .{aspectMask = .COLOR, layerCount = 1},
        imageLayout      = .GENERAL,
        imageExtent      = .{width, height, 1},
    };
    copy_info := VkCopyDeviceMemoryImageInfoKHR.{image = texture.image, regionCount = 1, pRegions = *region};
    vkCmdCopyMemoryToImageKHR(frame_context.init_command_buffer, *copy_info);

    for level : 1..mip_levels - 1 {
        memory_barrier(frame_context.init_command_buffer, .ALL_TRANSFER, .TRANSFER_WRITE, .ALL_TRANSFER, .TRANSFER_READ);

        source_width  := max(width  >> (level - 1), 1);
        source_height := max(height >> (level - 1), 1);
        blit := VkImageBlit2.{
            srcSubresource = .{aspectMask = .COLOR, mipLevel = level - 1, layerCount = 1},
            dstSubresource = .{aspectMask = .COLOR, mipLevel = level,     layerCount = 1},
        };
        blit.srcOffsets[1] = .{xx source_width, xx source_height, 1};
        blit.dstOffsets[1] = .{xx max(source_width / 2, 1), xx max(source_height / 2, 1), 1};

        blit_info := VkBlitImageInfo2.{
            srcImage       = texture.image,
            srcImageLayout = .GENERAL,
            dstImage       = texture.image,
            dstImageLayout = .GENERAL,
            regionCount    = 1,
            pRegions       = *blit,
            filter         = .LINEAR,
        };
        vkCmdBlitImage2(frame_context.init_command_buffer, *blit_info);
    }
    memory_barrier(frame_context.init_command_buffer, .ALL_TRANSFER, .TRANSFER_WRITE, .FRAGMENT_SHADER, .SHADER_SAMPLED_READ);

    view_create_info := VkImageViewCreateInfo.{
        image            = texture.image,
        viewType         = .e2D,
        format           = format,
        subresourceRange = subresource_range,
    };
    texture.handle = .{id = reserve_image_descriptor()};
    write_image_descriptor(texture.handle.id, .SAMPLED_IMAGE, view_create_info);

    log("Uploaded % (%x%, % mips).", name, width, height, mip_levels);
    return texture;
}

destroy_texture :: (texture: Texture) {
    vkDestroyImage(device_context.device, texture.image, null);
}
