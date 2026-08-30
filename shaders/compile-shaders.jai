// Graphics
// Compile Shaders
// Alex Hartford

#import "Process";
#if OS == .WINDOWS {
    #import "Windows";
}

vulkan_sdk_path :: () -> string {
    path := to_string(getenv("VULKAN_SDK"));
    assert(path.count > 0, "VULKAN_SDK is not set. Install the Vulkan SDK, or start your shell from one that defines it.");
    return path;
}

slangc :: (output_filename: string, filename: string, entry_point: string) -> success : bool {
    input_file  := tprint("%.slang", filename);
    output_file := tprint("compiled/%.spv", output_filename);

    process_result := run_command(
        args = ...[
            tprint("%/Bin/slangc.exe", vulkan_sdk_path()),
            input_file,
            tprint("-o %", output_file),
            tprint("-entry %", entry_point),
            "-profile spirv_1_6",
            "-target spirv",
            "-capability spvDescriptorHeapEXT",
        ],
        working_directory = #filepath,
        //capture_and_return_output = false,
        //print_captured_output = false,
        //timeout_ms = -1,
        arg_quoting = Process_Argument_Quoting.NEVER_QUOTE
    );

    if process_result.exit_code == 0 {
        log("% -> %", input_file, output_file);
        return true;
    }
    else {
        log("% failed to compile via slangc.", filename);
        return false;
    }
}

compile_shaders :: () {
    print("\nCompiling shaders!\n");

    assert(slangc("material-vertex",   "material", "vertex_main"));
    assert(slangc("material-fragment", "material", "fragment_main"));

    print("Compiled all shaders.\n\n");
}
