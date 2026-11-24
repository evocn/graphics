MANDATORY_COMPILER_VERSION :: Version_Info.{0, 2, 30};

shared_data :: #string DONE

build_settings : struct {
    configuration : enum {
        DEBUG;
        RELEASE;
    }
}

program_title :: "Graphics";

compiled_shaders_directory :: "bin/shaders";

DONE
#run add_build_string(shared_data, w = -1);

root := #filepath;
#run root.count -= 1;

build :: () {
    {
        this_program_options: Build_Options_During_Compile;
        this_program_options.do_output = false;
        this_program_options.write_added_strings = false;

        set_build_options_dc(this_program_options);
    }

    w := compiler_create_workspace("Final Program");
    if !w {
        print("Workspace creation failed.\n");
        return;
    }
    options := get_build_options(w);

    arguments := options.compile_time_command_line;
    {
        for argument: arguments {
            if argument == "build.jai" then continue;
            if argument == {
                case "-debug"; {
                    build_settings.configuration = .DEBUG;
                }
                case "-release"; {
                    build_settings.configuration = .RELEASE;
                }
                case; {
                    log_error("Unknown argument %.\n Exiting.", argument);
                    return;
                }
            }
        }

        log("Build settings: %\n", build_settings);
    }

    {
        success, plugins_to_create := parse_plugin_arguments(arguments);
        init_plugins(plugins_to_create, *plugins, w);
    }

    {
        operator == :: (a: Version_Info, b: Version_Info) -> bool {
            return a.major == b.major && a.minor == b.minor && a.micro == b.micro;
        }

        queried_version_info : Version_Info;
        version_info_string := compiler_get_version_info(*queried_version_info);
        log("Compiling the target program with %\n", version_info_string);

        if queried_version_info != MANDATORY_COMPILER_VERSION {
            log_error("Compile this with version % instead.", MANDATORY_COMPILER_VERSION);
            return;
        }
    }

    {
        options.output_executable_name = program_title;

        options.output_path = "bin";
        options.intermediate_path = "bin/.build";
        options.output_type = .EXECUTABLE;
        options.entry_point_name = "main";

        options.text_output_flags = 0;
        options.text_output_flags |= .OUTPUT_TIMING_INFO;

        if build_settings.configuration == {
            case .DEBUG;    set_optimization(*options, .DEBUG);
            case .RELEASE;  set_optimization(*options, .VERY_OPTIMIZED);
        }

        set_build_options(options, w);
    }

    compilation_failed := false;

    {
        log("Starting compilation now!\n");

        intercept_flags: Intercept_Flags;
        for plugins if it.before_intercept it.before_intercept(it, *intercept_flags);

        compiler_begin_intercept(w, intercept_flags);

        {
            for plugins if it.add_source it.add_source(it);

            {
                add_build_file(tprint("%/source/main.jai", root), w);
            }

            {
                add_build_string(shared_data, w);

                build_configuration_string : string;
                build_configuration_string = tprint("BUILD_TYPE :: build_settings.configuration.%;", build_settings.configuration);
                add_build_string(build_configuration_string, w);
            }
        }

        {
            ctags: CTags;
            defer reset(*ctags);
            ctags.output_filename = "tags";
            ctags.base_path = sprint("%", root);
            defer free(ctags.base_path);

            while true {
                message := compiler_wait_for_message();
                if !message continue;

                if message.workspace == w {
                    process_message(*ctags, message);
                    collect_gpu_structs(message);

                    for plugin : plugins if plugin.message plugin.message(plugin, message);
                }

                if message.kind == .COMPLETE {
                    compilation_failed = (cast(*Message_Complete) message).error_code != .NONE;
                    break;
                }
            }
        }

        compiler_end_intercept(w);

        for plugins if it.finish it.finish(it);
        for plugins if it.shutdown it.shutdown(it);
    }

    if compilation_failed exit(1);

    if !generate_shader_types(tprint("%/%/generated/shared.slang", root, compiled_shaders_directory)) exit(1);
    compile_shaders();

    {
        spirv_paths : [..] string;
        for name : SHADER_NAMES {
            array_add(*spirv_paths, tprint("%/%/%.spv", root, compiled_shaders_directory, name));
        }
        if !check_shader_layouts(spirv_paths) exit(1);
    }

    {
        log("\nCompilation ended on the target workspace. On to publishing work!");

        executable_path := sprint("%/%.exe", options.output_path, options.output_executable_name);
        defer free(executable_path);

        #if OS == .WINDOWS {
            dll_destination := tprint("%/ImGui.dll", options.output_path);
            if !file_exists(dll_destination) {
                for import_root : options.import_path {
                    dll_source := tprint("%/ImGui/windows/ImGui.dll", import_root);
                    if file_exists(dll_source) {
                        success := copy_file(dll_source, dll_destination);
                        assert(success, "Unable to copy % to %", dll_source, dll_destination);
                        log(" + % -> %", dll_source, dll_destination);
                        break;
                    }
                }
                assert(file_exists(dll_destination), "Could not find ImGui/windows/ImGui.dll in any import path.");
            }
        }

        icon_path :: "assets/publishing/icon.png";

        #if OS == .WINDOWS {
            log("\n---\n");
            create_and_apply_manifest_and_icon_files(executable_path, icon_path);
        }
    }
}

#run,stallable build();

#if OS == .WINDOWS {
create_and_apply_manifest_and_icon_files :: (executable_path : string, icon_path : string) {
    #import "Ico_File";
    #import "Windows_Resources";

    log("Creating manifest file for Windows and an icon from the file at %.", icon_path);

    success : bool;

    manifest_options: Manifest_Options;

    success = add_manifest_to_executable(executable_path, manifest_options);

    log("Manifest added: %\n", success);

    ico_data := create_ico_file_from_bitmap_filename(icon_path);
    defer free(ico_data);

    ico_path := sprint("%.ico", path_strip_extension(icon_path));
    defer free(ico_path);
    {
        write_entire_file(ico_path, ico_data);
    }

    success = set_icon_by_data(executable_path, ico_data);
    log("Icon     added: %\n", success);
}
}

#import "Basic";
#import "Compiler";
#import "String";
#import "File";
#import "File_Utilities";

#import "Metaprogram_Plugins";
#import "Iprof";

plugins: [..] *Metaprogram_Plugin;

#import "ctags";

#load "source/tools/shaders/compile-shaders.jai";
#load "source/tools/shaders/generate-shader-types.jai";
#load "source/tools/shaders/check-shader-layouts.jai";
