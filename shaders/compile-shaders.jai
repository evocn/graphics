
// Compile Shaders

////////////////////////////////////////////////////////////////////////////////

slangc :: (output_filename: string, filename: string, entry_point: string) -> success : bool {
    input_file  := tprint("%/%.slang", source_shaders_directory, filename);
    output_file := tprint("%/%.spv", compiled_shaders_directory, output_filename);

    process_result := run_command(
        args = ...[
            "slangc.exe",
            input_file,
            tprint("-o %", output_file),
            tprint("-entry %", entry_point),
            "-profile glsl_460",
            "-target spirv",
        ],
        //working_directory = #filepath,
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

    {
        success := make_directory_if_it_does_not_exist(compiled_shaders_directory, recursive = true);
        if !success {
            log("Could not make the directory for compiled shaders: %", compiled_shaders_directory);
            return;
        }
    }

    success : bool;
    success = slangc("debug-fragment", "debug", "fragmentMain");
    success = slangc("debug-vertex", "debug", "vertexMain");

    print("Compiled all shaders.\n\n");
}

#import "Process";
#import "File";
