create_graphics_shaders :: (name: string, fragment_entry := "fragment_main") -> [2] VkShaderEXT {
    spirv := read_spirv(name);
    defer free(spirv);

    infos := VkShaderCreateInfoEXT.[
        .{flags = .LINK_STAGE | .DESCRIPTOR_HEAP, stage = .VERTEX, nextStage = .FRAGMENT, codeType = .SPIRV, codeSize = xx spirv.count, pCode = spirv.data, pName = "vertex_main"},
        .{flags = .LINK_STAGE | .DESCRIPTOR_HEAP, stage = .FRAGMENT, codeType = .SPIRV, codeSize = xx spirv.count, pCode = spirv.data, pName = temp_c_string(fragment_entry)},
    ];

    shaders : [2] VkShaderEXT;
    create_shaders(tprint("%.%", name, fragment_entry), spirv, infos, shaders);

    set_debug_name(.SHADER_EXT, shaders[0], tprint("% vertex_main", name));
    set_debug_name(.SHADER_EXT, shaders[1], tprint("% %", name, fragment_entry));
    return shaders;
}

create_compute_shader :: (name: string, entry: string) -> VkShaderEXT {
    spirv := read_spirv(name);
    defer free(spirv);

    infos := VkShaderCreateInfoEXT.[
        .{flags = .DESCRIPTOR_HEAP, stage = .COMPUTE, codeType = .SPIRV, codeSize = xx spirv.count, pCode = spirv.data, pName = temp_c_string(entry)},
    ];

    shaders : [1] VkShaderEXT;
    create_shaders(tprint("%.%", name, entry), spirv, infos, shaders);

    set_debug_name(.SHADER_EXT, shaders[0], tprint("% %", name, entry));
    return shaders[0];
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

push :: (command_buffer: VkCommandBuffer, data: $T) {
    value := data;
    info := VkPushDataInfoEXT.{data = .{address = *value, size = size_of(T)}};
    vkCmdPushDataEXT(command_buffer, *info);
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

shader_cache_directory :: "bin/shader_cache";

SHADER_CACHE_MAGIC     :: 0x31424853;
SHADER_BINARY_ALIGNMENT :: 16;

Shader_Cache_Header :: struct {
    magic          : u32;
    binary_version : u32;
    binary_uuid    : [VK_UUID_SIZE] u8;
    source_hash    : u64;
    binary_sizes   : [2] s64;
}

#assert size_of(Shader_Cache_Header) % SHADER_BINARY_ALIGNMENT == 0;

Aligned_Buffer :: struct {
    allocation : *void;
    data       : *u8;
}

aligned_alloc :: (size: s64) -> Aligned_Buffer {
    buffer : Aligned_Buffer;
    buffer.allocation = alloc(size + SHADER_BINARY_ALIGNMENT - 1);
    buffer.data = cast(*u8) align_forward(cast(s64) buffer.allocation, SHADER_BINARY_ALIGNMENT);
    return buffer;
}

create_shaders :: (cache_name: string, spirv: string, infos: [] VkShaderCreateInfoEXT, shaders: [] VkShaderEXT) {
    assert(infos.count == shaders.count && infos.count <= 2);

    path := tprint("%/%.bin", shader_cache_directory, cache_name);
    hash := source_hash(spirv, infos);

    if load_shader_binaries(path, hash, infos, shaders) return;

    result := vkCreateShadersEXT(device_context.device, xx infos.count, infos.data, null, shaders.data);
    assert(result == .SUCCESS);

    save_shader_binaries(path, hash, shaders);
}

source_hash :: (spirv: string, infos: [] VkShaderCreateInfoEXT) -> u64 {
    hash := fnv1a_hash(spirv.data, spirv.count);
    for infos {
        entry := to_string(it.pName);
        hash = fnv1a_hash(cast(u64) it.stage, hash);
        hash = fnv1a_hash(cast(u64) it.nextStage, hash);
        hash = fnv1a_hash(cast(u64) it.flags, hash);
        hash = fnv1a_hash(entry.data, entry.count, hash);
    }
    return hash;
}

load_shader_binaries :: (path: string, hash: u64, infos: [] VkShaderCreateInfoEXT, shaders: [] VkShaderEXT) -> bool {
    file, read := read_entire_file(path, log_errors = false);
    if !read return false;
    defer free(file);

    if file.count < size_of(Shader_Cache_Header) return false;

    buffer := aligned_alloc(file.count);
    defer free(buffer.allocation);
    memcpy(buffer.data, file.data, file.count);

    header := cast(*Shader_Cache_Header) buffer.data;
    properties := *device_context.shader_object_properties;
    if header.magic != SHADER_CACHE_MAGIC                                                       return false;
    if header.source_hash != hash                                                               return false;
    if header.binary_version != properties.shaderBinaryVersion                                 return false;
    if memcmp(header.binary_uuid.data, properties.shaderBinaryUUID.data, VK_UUID_SIZE) != 0   return false;

    binary_infos : [2] VkShaderCreateInfoEXT;
    offset := size_of(Shader_Cache_Header);
    for infos {
        size := header.binary_sizes[it_index];
        if size <= 0 || offset + size > file.count return false;

        binary_infos[it_index] = it;
        binary_infos[it_index].codeType = .BINARY;
        binary_infos[it_index].codeSize = xx size;
        binary_infos[it_index].pCode    = buffer.data + offset;
        offset += align_forward(size, SHADER_BINARY_ALIGNMENT);
    }

    result := vkCreateShadersEXT(device_context.device, xx infos.count, binary_infos.data, null, shaders.data);
    if result == .SUCCESS {
        log("Loaded shader binary %.", path);
        return true;
    }

    for * shaders {
        if it.*  vkDestroyShaderEXT(device_context.device, it.*, null);
        it.* = null;
    }
    log("Shader binary % was rejected (%), compiling from SPIR-V.", path, result);
    return false;
}

save_shader_binaries :: (path: string, hash: u64, shaders: [] VkShaderEXT) {
    properties := *device_context.shader_object_properties;
    header := Shader_Cache_Header.{magic = SHADER_CACHE_MAGIC, binary_version = properties.shaderBinaryVersion, binary_uuid = properties.shaderBinaryUUID, source_hash = hash};

    binaries : [2] Aligned_Buffer;
    defer for binaries  free(it.allocation);

    for shaders {
        size : u64;
        result := vkGetShaderBinaryDataEXT(device_context.device, it, *size, null);
        if result != .SUCCESS {
            log_error("Unable to query the shader binary size for % (%).", path, result);
            return;
        }

        binaries[it_index] = aligned_alloc(xx size);
        result = vkGetShaderBinaryDataEXT(device_context.device, it, *size, binaries[it_index].data);
        if result != .SUCCESS {
            log_error("Unable to read the shader binary for % (%).", path, result);
            return;
        }
        header.binary_sizes[it_index] = xx size;
    }

    padding : [SHADER_BINARY_ALIGNMENT] u8;
    builder : String_Builder;
    append(*builder, cast(*u8) *header, size_of(Shader_Cache_Header));
    for shaders {
        size := header.binary_sizes[it_index];
        append(*builder, binaries[it_index].data, size);
        append(*builder, padding.data, align_forward(size, SHADER_BINARY_ALIGNMENT) - size);
    }

    make_directory_if_it_does_not_exist(shader_cache_directory, recursive = true);
    if !write_entire_file(path, *builder)  log_error("Unable to write shader binary %.", path);
}
