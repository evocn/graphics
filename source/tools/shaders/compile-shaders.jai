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
    input_file   := tprint("%.slang", name);
    output_file  := tprint("%/%/%.spv", root, compiled_shaders_directory, name);
    depfile      := tprint("%/%/%.d", root, compiled_shaders_directory, name);
    command_file := tprint("%/%/%.command", root, compiled_shaders_directory, name);

    args := string.[
        tprint("%/Bin/slangc.exe", vulkan_sdk_path()),
        input_file,
        "-o", output_file,
        "-depfile", depfile,
        "-I", tprint("%/%", root, compiled_shaders_directory),
        "-fvk-use-entrypoint-name",
        "-profile", "spirv_1_6",
        "-target", "spirv",
        "-matrix-layout-row-major",
        "-capability", "spvDescriptorHeapEXT",
        "-capability", "spvRayQueryKHR",
        "-capability", "spvGroupNonUniformBallot",
    ];
    command := join(..args, " ",, temp);

    if is_up_to_date(output_file, depfile, command_file, command) {
        log("% is up to date.", input_file);
        return true;
    }

    process_result := run_command(..args, working_directory = tprint("%/shaders", root));

    if process_result.exit_code != 0 {
        log("% failed to compile via slangc.", input_file);
        file_delete(command_file);
        return false;
    }
    write_entire_file(command_file, command);
    log("% -> %", input_file, output_file);
    return true;
}

SHADER_NAMES :: string.["material", "tonemap", "imgui", "skin"];

compile_shaders :: () {
    make_directory_if_it_does_not_exist(tprint("%/%", root, compiled_shaders_directory), recursive = true);
    for SHADER_NAMES  assert(slangc(it));
}

#scope_file

is_up_to_date :: (output_file: string, depfile: string, command_file: string, command: string) -> bool {
    output_time, _, output_exists := file_modtime_and_size(output_file);
    if !output_exists return false;

    previous_command, command_read := read_entire_file(command_file, log_errors = false);
    if !command_read || previous_command != command return false;

    dependencies, dependencies_read := read_entire_file(depfile, log_errors = false);
    if !dependencies_read return false;

    found_dependency := false;
    for parse_depfile(dependencies) {
        dependency_time, _, dependency_exists := file_modtime_and_size(it);
        if !dependency_exists || dependency_time > output_time return false;
        found_dependency = true;
    }
    return found_dependency;
}

parse_depfile :: (text: string) -> [] string {
    paths : [..] string;
    paths.allocator = temp;

    token : String_Builder;
    token.allocator = temp;
    seen_target := false;

    finish_token :: () #expand {
        word := builder_to_string(*token,, temp);
        if word && seen_target  array_add(*paths, word);
    }

    i := 0;
    while i < text.count {
        c := text[i];
        if c == #char "\\" && i + 1 < text.count {
            next := text[i + 1];
            if next == #char "\n" || next == #char "\r" {
                finish_token();
            } else {
                append(*token, next);
            }
            i += 2;
            continue;
        }
        if c == #char " " || c == #char "\t" || c == #char "\n" || c == #char "\r" {
            finish_token();
        } else if c == #char ":" && !seen_target && (i + 1 == text.count || text[i + 1] == #char " ") {
            seen_target = true;
            builder_to_string(*token,, temp);
        } else {
            append(*token, c);
        }
        i += 1;
    }
    finish_token();
    return paths;
}
