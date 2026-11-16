create_graphics_shaders :: (name: string, fragment_entry := "fragment_main") -> [2] VkShaderEXT {
    spirv := read_spirv(name);
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

create_compute_shader :: (name: string, entry: string) -> VkShaderEXT {
    spirv := read_spirv(name);
    defer free(spirv);

    info := VkShaderCreateInfoEXT.{flags = .DESCRIPTOR_HEAP, stage = .COMPUTE, codeType = .SPIRV, codeSize = xx spirv.count, pCode = spirv.data, pName = temp_c_string(entry)};

    shader : VkShaderEXT;
    result := vkCreateShadersEXT(device_context.device, 1, *info, null, *shader);
    assert(result == .SUCCESS);

    set_debug_name(.SHADER_EXT, shader, tprint("% %", name, entry));
    return shader;
}

destroy_shaders :: (shaders: [2] VkShaderEXT) {
    for shaders  vkDestroyShaderEXT(device_context.device, it, null);
}

destroy_shaders :: (shader: VkShaderEXT) {
    vkDestroyShaderEXT(device_context.device, shader, null);
}

bind_shaders :: (command_buffer: VkCommandBuffer, shaders: [2] VkShaderEXT) {
    stages := VkShaderStageFlagBits.[.VERTEX, .FRAGMENT];
    vkCmdBindShadersEXT(command_buffer, stages.count, stages.data, shaders.data);
}

bind_shaders :: (command_buffer: VkCommandBuffer, shader: VkShaderEXT) {
    stage := VkShaderStageFlagBits.COMPUTE;
    vkCmdBindShadersEXT(command_buffer, 1, *stage, *shader);
}

dispatch :: (command_buffer: VkCommandBuffer, thread_count: u32, group_size: u32) {
    vkCmdDispatch(command_buffer, (thread_count + group_size - 1) / group_size, 1, 1);
}

#scope_file

read_spirv :: (name: string) -> string {
    path := tprint("%/%.spv", compiled_shaders_directory, name);
    spirv, success := read_entire_file(path);
    assert(success, "Unable to read shader file %", path);
    return spirv;
}
