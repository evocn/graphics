gpu_structs : [..] *Type_Info_Struct;

Generated_Layout :: struct {
    name   : string;
    size   : s64;
    fields : [..] Generated_Field;
}

Generated_Field :: struct {
    name   : string;
    offset : s64;
}

generated_layouts : [..] Generated_Layout;

collect_gpu_structs :: (message: *Message) {
    if message.kind != .TYPECHECKED return;

    typechecked := cast(*Message_Typechecked) message;
    for typechecked.structs {
        info := it.expression.defined_type;
        if !info continue;

        if array_find(info.notes, "Gpu") then array_add_if_unique(*gpu_structs, info);
    }
}

generate_shader_types :: (path: string) -> success: bool {
    builder : String_Builder;
    emitted : [..] *Type_Info_Struct;
    defer array_free(emitted);

    for gpu_structs {
        if !emit_struct(*builder, *emitted, it) return false;
    }

    make_directory_if_it_does_not_exist(path_strip_filename(path), recursive = true);
    if !write_entire_file(path, *builder) {
        log_error("Unable to write %.", path);
        return false;
    }

    log("Generated % (% structs).", path, emitted.count);
    return true;
}

#scope_file

emit_struct :: (builder: *String_Builder, emitted: *[..] *Type_Info_Struct, info: *Type_Info_Struct) -> success: bool {
    if array_find(emitted.*, info) return true;

    for member : info.members {
        if member.flags & .CONSTANT continue;

        dependency := struct_dependency(member.type);
        if dependency && !emit_struct(builder, emitted, dependency) return false;
    }

    array_add(emitted, info);

    layout := array_add(*generated_layouts);
    layout.name = info.name;
    layout.size = info.runtime_size;

    print_to_builder(builder, "struct % {\n", info.name);

    cursor := 0;
    for member : info.members {
        if member.flags & .CONSTANT continue;

        if member.offset_in_bytes > cursor {
            if !emit_padding(builder, layout, cursor, member.offset_in_bytes - cursor) return false;
        }

        slang_type, array_suffix, success := slang_type_of(member.type);
        if !success {
            log_error("%.% has no Slang equivalent.", info.name, member.name);
            return false;
        }

        print_to_builder(builder, "    % %%;\n", slang_type, member.name, array_suffix);
        array_add(*layout.fields, .{member.name, member.offset_in_bytes});
        cursor = member.offset_in_bytes + member.type.runtime_size;
    }

    if info.runtime_size > cursor {
        if !emit_padding(builder, layout, cursor, info.runtime_size - cursor) return false;
    }

    append(builder, "}\n\n");
    return true;
}

emit_padding :: (builder: *String_Builder, layout: *Generated_Layout, offset: s64, bytes: s64) -> success: bool {
    if bytes % 4 != 0 {
        log_error("% needs % bytes of padding, which isn't a multiple of 4.", layout.name, bytes);
        return false;
    }

    name := tprint("padding%", offset);
    print_to_builder(builder, "    uint %[%];\n", name, bytes / 4);
    array_add(*layout.fields, .{name, offset});
    return true;
}

struct_dependency :: (type: *Type_Info) -> *Type_Info_Struct {
    if type.type == .ARRAY return struct_dependency((cast(*Type_Info_Array) type).element_type);
    if type.type != .STRUCT return null;

    info := cast(*Type_Info_Struct) type;
    if is_gpu_pointer(info) return struct_dependency(gpu_pointer_target(info));
    if builtin_slang_name(info).count > 0 return null;
    return info;
}

slang_type_of :: (type: *Type_Info) -> slang_type: string, array_suffix: string, success: bool {
    if type.type == {
        case .INTEGER;
            signed := (cast(*Type_Info_Integer) type).signed;
            if type.runtime_size == {
                case 4; return ifx signed then "int"     else "uint",     "", true;
                case 8; return ifx signed then "int64_t" else "uint64_t", "", true;
            }

        case .FLOAT;
            if type.runtime_size == {
                case 4; return "float",  "", true;
                case 8; return "double", "", true;
            }

        case .ARRAY;
            array := cast(*Type_Info_Array) type;
            if array.array_type != .FIXED return "", "", false;

            element, element_suffix, success := slang_type_of(array.element_type);
            if !success || element_suffix.count > 0 return "", "", false;
            return element, tprint("[%]", array.array_count), true;

        case .STRUCT;
            info := cast(*Type_Info_Struct) type;

            if is_gpu_pointer(info) {
                target, target_suffix, success := slang_type_of(gpu_pointer_target(info));
                if !success || target_suffix.count > 0 return "", "", false;
                return tprint("%*", target), "", true;
            }

            builtin := builtin_slang_name(info);
            if builtin.count > 0 return builtin, "", true;

            return info.name, "", true;
    }

    return "", "", false;
}

builtin_slang_name :: (info: *Type_Info_Struct) -> string {
    if info.name == {
        case "Vector2"; return "float2";
        case "ImVec2";  return "float2";
        case "Vector3"; return "float3";
        case "Vector4"; return "float4";
        case "ImVec4";  return "float4";
        case "Matrix4"; return "float4x4";

        case "Texture_Handle"; return "DescriptorHandle<Texture2D>";
        case "Sampler_Handle"; return "DescriptorHandle<SamplerState>";
        case "Storage_Image_Handle"; return "DescriptorHandle<RWTexture2D<float4>>";
    }
    return "";
}

is_gpu_pointer :: (info: *Type_Info_Struct) -> bool {
    return info.polymorph_source_struct != null && info.polymorph_source_struct.name == "Gpu_Pointer";
}

gpu_pointer_target :: (info: *Type_Info_Struct) -> *Type_Info {
    parameter := info.specified_parameters[0];
    target := (cast(*Type) (info.constant_storage.data + parameter.offset_into_constant_storage)).*;
    return cast(*Type_Info) target;
}
