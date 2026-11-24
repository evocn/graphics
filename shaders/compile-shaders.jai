#import "Process";
#if OS == .WINDOWS {
    #import "Windows";
}

vulkan_sdk_path :: () -> string {
    path := to_string(getenv("VULKAN_SDK"));
    assert(path.count > 0, "VULKAN_SDK is not set. Install the Vulkan SDK, or start your shell from one that defines it.");
    return path;
}

slangc :: (name: string) -> success: bool {
    input_file  := tprint("%.slang", name);
    output_file := tprint("%/%/%.spv", root, compiled_shaders_directory, name);

    process_result := run_command(args = ...[
            tprint("%/Bin/slangc.exe", vulkan_sdk_path()),
            input_file,
            "-o", output_file,
            "-I", tprint("%/%", root, compiled_shaders_directory),
            "-fvk-use-entrypoint-name",
            "-profile", "spirv_1_6",
            "-target", "spirv",
            "-matrix-layout-row-major",
            "-capability", "spvDescriptorHeapEXT",
            "-capability", "spvRayQueryKHR",
            "-capability", "spvGroupNonUniformBallot",
        ],
        working_directory = #filepath,
    );

    if process_result.exit_code != 0 {
        log("% failed to compile via slangc.", input_file);
        return false;
    }
    log("% -> %", input_file, output_file);
    return true;
}

SHADER_NAMES :: string.["material", "tonemap", "imgui", "wave", "skin"];

compile_shaders :: () {
    make_directory_if_it_does_not_exist(tprint("%/%", root, compiled_shaders_directory), recursive = true);
    for SHADER_NAMES  assert(slangc(it));
}
