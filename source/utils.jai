
// Utils

////////////////////////////////////////////////////////////////////////////////

offset_of :: ($T: Type, $member: string) -> u32 {
    for type_info(T).members {
        if it.name == member return cast(u32)it.offset_in_bytes;
    }

    assert(false, "Type '%' does not have member '%'", T, member);
    return 0;
}

////////////////////////////////////////////////////////////////////////////////

error_callback :: (error: s32, description: *u8) #c_call {
    push_context {
        print("Error: %\n\n", to_string(description));
    }
}
