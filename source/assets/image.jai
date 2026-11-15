load_image_texture :: (path: string, format: VkFormat) -> Texture_Handle {
    width, height, channels : s32;
    pixels := stbi_load(temp_c_string(path), *width, *height, *channels, 4);
    assert(pixels != null, "Unable to load image %.", path);
    defer stbi_image_free(pixels);

    return add_texture(create_texture(pixels, xx width, xx height, format, path));
}

load_image_texture_from_memory :: (bytes: *u8, size: s64, format: VkFormat, name: string) -> Texture_Handle {
    width, height, channels : s32;
    pixels := stbi_load_from_memory(bytes, xx size, *width, *height, *channels, 4);
    assert(pixels != null, "Unable to decode image %.", name);
    defer stbi_image_free(pixels);

    return add_texture(create_texture(pixels, xx width, xx height, format, name));
}
