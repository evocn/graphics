#run,stallable {
    set_build_options_dc(.{do_output = false});
    if !generate() compiler_set_workspace_status(.FAILED);
}

generate :: () -> bool {
    module_directory := path_strip_filename(#file);
    set_working_directory(module_directory);

    make_directory_if_it_does_not_exist("windows");
    if !Build_Cpp.build_cpp_static_lib("windows/cgltf", "source/cgltf.c", target = .WINDOWS, extra = .["/D_CRT_SECURE_NO_WARNINGS"]) return false;

    options : Generate_Bindings_Options;
    {
        using options;
        array_add(*library_search_paths, "windows");
        array_add(*libraries, .{filename = "cgltf"});
        array_add(*source_files, "source/cgltf.h");

        try_to_preserve_comments            = false;
        add_generator_command               = false;
        log_stripped_declarations           = false;
        generate_compile_time_struct_checks = false;
        alias_original_enum_names           = false;
    }

    return generate_bindings(options, "bindings.jai");
}

#import "Basic";
#import "Compiler";
#import "File";
#import "String";
#import "Bindings_Generator";
Build_Cpp :: #import "BuildCpp";
