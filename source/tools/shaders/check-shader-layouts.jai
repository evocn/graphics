check_shader_layouts :: (spirv_paths: [] string) -> success: bool {
    success := true;
    checked := 0;

    for path : spirv_paths {
        spirv, read := read_entire_file(path);
        if !read {
            log_error("Unable to read %.", path);
            return false;
        }

        module, parsed := parse_spirv(spirv);
        if !parsed {
            log_error("% is not valid SPIR-V.", path);
            return false;
        }

        for spirv_struct : module.structs {
            layout := find_layout(spirv_struct.name);
            if !layout continue;
            checked += 1;

            for member : spirv_struct.members {
                if member.index >= layout.fields.count {
                    log_error("%: %.% has a member Jai doesn't know about.", path, layout.name, member.name);
                    success = false;
                    continue;
                }

                field := layout.fields[member.index];
                if field.name != member.name {
                    log_error("%: member % of % is % in Slang but % in Jai.", path, member.index, layout.name, member.name, field.name);
                    success = false;
                }
                else if field.offset != member.offset {
                    log_error("%: %.% is at offset % in Slang but % in Jai.", path, layout.name, member.name, member.offset, field.offset);
                    success = false;
                }
            }

            if spirv_struct.members.count != layout.fields.count {
                log_error("%: % has % members in Slang and % in Jai.", path, layout.name, spirv_struct.members.count, layout.fields.count);
                success = false;
            }
        }

        for pointer : module.pointers {
            target := find_struct(module, pointer.target);
            if !target continue;

            layout := find_layout(target.name);
            if !layout continue;

            if pointer.array_stride != layout.size {
                log_error("%: % pointers step by % bytes in Slang, but size_of(%) is % in Jai.",
                    path, layout.name, pointer.array_stride, layout.name, layout.size);
                success = false;
            }
        }
    }

    if success then log("Checked % struct layouts against Jai.", checked);
    return success;
}

#scope_file

Spirv_Module :: struct {
    structs  : [..] Spirv_Struct;
    pointers : [..] Spirv_Pointer;
}

Spirv_Struct :: struct {
    id      : u32;
    name    : string;
    members : [..] Spirv_Member;
}

Spirv_Member :: struct {
    index  : s64;
    name   : string;
    offset : s64 = -1;
}

Spirv_Pointer :: struct {
    id           : u32;
    target       : u32;
    array_stride : s64 = -1;
}

SPIRV_MAGIC :: 0x07230203;

OP_NAME             :: 5;
OP_MEMBER_NAME      :: 6;
OP_TYPE_STRUCT      :: 30;
OP_TYPE_POINTER     :: 32;
OP_DECORATE         :: 71;
OP_MEMBER_DECORATE  :: 72;

DECORATION_ARRAY_STRIDE :: 6;
DECORATION_OFFSET       :: 35;

STORAGE_CLASS_PHYSICAL_STORAGE_BUFFER :: 5349;

LAYOUT_SUFFIXES :: string.["_natural", "_std430", "_std140", "_scalar"];

parse_spirv :: (spirv: string) -> Spirv_Module, success: bool {
    module : Spirv_Module;

    words := cast(*u32) spirv.data;
    word_count := spirv.count / 4;
    if word_count < 5 || words[0] != SPIRV_MAGIC return module, false;

    names : [..] struct { id: u32; name: string; };

    cursor := 5;
    while cursor < word_count {
        opcode := words[cursor] & 0xFFFF;
        length := cast(s64) (words[cursor] >> 16);
        if length == 0 || cursor + length > word_count return module, false;

        operands := words + cursor + 1;

        if opcode == {
            case OP_NAME;
                array_add(*names, .{operands[0], spirv_string(operands + 1)});

            case OP_TYPE_STRUCT;
                spirv_struct := array_add(*module.structs);
                spirv_struct.id = operands[0];

            case OP_TYPE_POINTER;
                if operands[1] == STORAGE_CLASS_PHYSICAL_STORAGE_BUFFER {
                    array_add(*module.pointers, .{id = operands[0], target = operands[2]});
                }
        }

        cursor += length;
    }

    for *spirv_struct : module.structs {
        for names if it.id == spirv_struct.id then spirv_struct.name = strip_layout_suffix(it.name);
    }

    cursor = 5;
    while cursor < word_count {
        opcode := words[cursor] & 0xFFFF;
        length := cast(s64) (words[cursor] >> 16);
        operands := words + cursor + 1;

        if opcode == {
            case OP_MEMBER_NAME;
                spirv_struct := find_struct(module, operands[0]);
                if spirv_struct then find_member(spirv_struct, operands[1]).name = spirv_string(operands + 2);

            case OP_MEMBER_DECORATE;
                spirv_struct := find_struct(module, operands[0]);
                if spirv_struct && operands[2] == DECORATION_OFFSET {
                    find_member(spirv_struct, operands[1]).offset = operands[3];
                }

            case OP_DECORATE;
                if operands[1] == DECORATION_ARRAY_STRIDE {
                    for *module.pointers if it.id == operands[0] then it.array_stride = operands[2];
                }
        }

        cursor += length;
    }

    return module, true;
}

spirv_string :: (words: *u32) -> string {
    return to_string(cast(*u8) words);
}

strip_layout_suffix :: (name: string) -> string {
    for LAYOUT_SUFFIXES {
        if ends_with(name, it) return slice(name, 0, name.count - it.count);
    }
    return name;
}

find_struct :: (module: Spirv_Module, id: u32) -> *Spirv_Struct {
    for *module.structs if it.id == id return it;
    return null;
}

find_member :: (spirv_struct: *Spirv_Struct, index: u32) -> *Spirv_Member {
    for *spirv_struct.members if it.index == index return it;

    member := array_add(*spirv_struct.members);
    member.index = index;
    return member;
}

find_layout :: (name: string) -> *Generated_Layout {
    for *generated_layouts if it.name == name return it;
    return null;
}
