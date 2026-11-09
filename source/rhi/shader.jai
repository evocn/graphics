create_graphics_shaders :: (name: string) -> [2] VkShaderEXT {
    vertex_spirv   := read_spirv(tprint("%-vertex", name));
    fragment_spirv := read_spirv(tprint("%-fragment", name));
    defer free(vertex_spirv);
    defer free(fragment_spirv);

    infos : [2] VkShaderCreateInfoEXT;
    infos[0] = .{
        flags     = .LINK_STAGE | .DESCRIPTOR_HEAP,
        stage     = .VERTEX,
        nextStage = .FRAGMENT,
        codeType  = .SPIRV,
        codeSize  = xx vertex_spirv.count,
        pCode     = vertex_spirv.data,
        pName     = "main",
    };
    infos[1] = .{
        flags     = .LINK_STAGE | .DESCRIPTOR_HEAP,
        stage     = .FRAGMENT,
        codeType  = .SPIRV,
        codeSize  = xx fragment_spirv.count,
        pCode     = fragment_spirv.data,
        pName     = "main",
    };

    shaders : [2] VkShaderEXT;
    result := vkCreateShadersEXT(device, infos.count, infos.data, null, shaders.data);
    assert(result == .SUCCESS);

    set_debug_name(.SHADER_EXT, shaders[0], tprint("% vertex", name));
    set_debug_name(.SHADER_EXT, shaders[1], tprint("% fragment", name));
    return shaders;
}

destroy_graphics_shaders :: (shaders: [2] VkShaderEXT) {
    for shaders  vkDestroyShaderEXT(device, it, null);
}

bind_graphics_shaders :: (command_buffer: VkCommandBuffer, shaders: [2] VkShaderEXT) {
    stages := VkShaderStageFlagBits.[.VERTEX, .FRAGMENT];
    vkCmdBindShadersEXT(command_buffer, stages.count, stages.data, shaders.data);
}

#scope_file

read_spirv :: (name: string) -> string {
    path := tprint("%/%.spv", compiled_shaders_directory, name);
    spirv, success := read_entire_file(path);
    assert(success, "Unable to read shader file %", path);
    return spirv;
}
