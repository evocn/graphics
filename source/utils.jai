
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

////////////////////////////////////////////////////////////////////////////////

srgb :: (r: float, g: float, b: float, a: float = 1.0) -> Vector4 {
    linear :: (c: float) -> float {
        if c <= 0.04045  return c / 12.92;
        return pow((c + 0.055) / 1.055, 2.4);
    }
    return .{linear(r), linear(g), linear(b), a};
}
