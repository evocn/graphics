create_graphics_shaders :: (name: string, fragment_entry := "fragment_main") -> [2] VkShaderEXT {
    path := tprint("%/%.spv", compiled_shaders_directory, name);
    spirv, success := read_entire_file(path);
    assert(success, "Unable to read shader file %", path);
    defer free(spirv);

    infos := VkShaderCreateInfoEXT.[
        .{flags = .LINK_STAGE | .DESCRIPTOR_HEAP, stage = .VERTEX, nextStage = .FRAGMENT, codeType = .SPIRV, codeSize = xx spirv.count, pCode = spirv.data, pName = "vertex_main"},
        .{flags = .LINK_STAGE | .DESCRIPTOR_HEAP, stage = .FRAGMENT, codeType = .SPIRV, codeSize = xx spirv.count, pCode = spirv.data, pName = temp_c_string(fragment_entry)},
    ];

    shaders : [2] VkShaderEXT;
    result := vkCreateShadersEXT(device_context.device, infos.count, infos.data, null, shaders.data);
    assert(result == .SUCCESS);

    set_debug_name(.SHADER_EXT, shaders[0], tprint("% vertex_main", name));
    set_debug_name(.SHADER_EXT, shaders[1], tprint("% %", name, fragment_entry));
    return shaders;
}

destroy_graphics_shaders :: (shaders: [2] VkShaderEXT) {
    for shaders  vkDestroyShaderEXT(device_context.device, it, null);
}

bind_graphics_shaders :: (command_buffer: VkCommandBuffer, shaders: [2] VkShaderEXT) {
    stages := VkShaderStageFlagBits.[.VERTEX, .FRAGMENT];
    vkCmdBindShadersEXT(command_buffer, stages.count, stages.data, shaders.data);
}
