screenshot_context : struct {
    requested      : bool;
    captured       : bool;
    offset         : VkDeviceSize;
    allocated_size : VkDeviceSize;
    extent         : VkExtent2D;
    format         : VkFormat;
}

record_screenshot_copy :: (command_buffer: VkCommandBuffer, swapchain_image: VkImage) {
    screenshot_context.requested = false;
    screenshot_context.extent    = swapchain_context.extent;
    screenshot_context.format    = swapchain_context.surface_format.format;

    size := cast(VkDeviceSize) (4 * screenshot_context.extent.width * screenshot_context.extent.height);
    if size > screenshot_context.allocated_size {
        screenshot_context.offset = heap_allocate(*heap_context.readback, size, 256);
        screenshot_context.allocated_size = size;
    }

    memory_barrier(command_buffer, .COLOR_ATTACHMENT_OUTPUT, .COLOR_ATTACHMENT_WRITE, .COPY, .TRANSFER_READ);

    region := VkDeviceMemoryImageCopyKHR.{
        addressRange     = .{address = heap_address(*heap_context.readback, screenshot_context.offset), size = size},
        addressFlags     = .STORAGE_BUFFER_USAGE,
        imageSubresource = .{aspectMask = .COLOR, layerCount = 1},
        imageLayout      = .GENERAL,
        imageExtent      = .{screenshot_context.extent.width, screenshot_context.extent.height, 1},
    };
    copy_info := VkCopyDeviceMemoryImageInfoKHR.{image = swapchain_image, regionCount = 1, pRegions = *region};
    vkCmdCopyImageToMemoryKHR(command_buffer, *copy_info);

    memory_barrier(command_buffer, .COPY, .TRANSFER_WRITE, .HOST, .HOST_READ);

    screenshot_context.captured = true;
}

save_screenshot :: () {
    pixels := read_screenshot_pixels();
    if !pixels return;
    defer free(pixels);

    path := timestamped_png_path("bin/screenshots");
    written := stbi_write_png(temp_c_string(path), xx screenshot_context.extent.width, xx screenshot_context.extent.height, 4, pixels, xx (4 * screenshot_context.extent.width));
    assert(written != 0, "Unable to write screenshot %", path);

    log("Saved screenshot to %.", path);
}

#scope_file

read_screenshot_pixels :: () -> *u32 {
    Layout :: enum { RGBA8; BGRA8; A2B10G10R10; }
    layout : Layout;
    if screenshot_context.format == {
        case .R8G8B8A8_UNORM;           #through;
        case .R8G8B8A8_SRGB;            layout = .RGBA8;
        case .B8G8R8A8_UNORM;           #through;
        case .B8G8R8A8_SRGB;            layout = .BGRA8;
        case .A2B10G10R10_UNORM_PACK32; layout = .A2B10G10R10;
        case;
            log_error("Can't read a screenshot of swapchain format %.", screenshot_context.format);
            return null;
    }

    pixel_count := screenshot_context.extent.width * screenshot_context.extent.height;
    pixels := cast(*u32) alloc(4 * pixel_count);
    memcpy(pixels, heap_pointer(*heap_context.readback, screenshot_context.offset), 4 * pixel_count);

    for i : 0..pixel_count-1 {
        p := pixels[i];
        r, g, b : u32;
        if layout == {
            case .RGBA8;
                r = p & 0xFF;          g = (p >> 8) & 0xFF;            b = (p >> 16) & 0xFF;
            case .BGRA8;
                r = (p >> 16) & 0xFF;  g = (p >> 8) & 0xFF;            b = p & 0xFF;
            case .A2B10G10R10;
                r = (p & 0x3FF) >> 2;  g = ((p >> 10) & 0x3FF) >> 2;   b = ((p >> 20) & 0x3FF) >> 2;
        }
        pixels[i] = r | (g << 8) | (b << 16) | 0xFF00_0000;
    }

    return pixels;
}
