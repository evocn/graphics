Gpu_Pointer :: struct (T: Type) {
    address : VkDeviceAddress;
}

Texture_Handle :: struct {
    id      : u32;
    padding : u32;
}

Sampler_Handle :: struct {
    id      : u32;
    padding : u32;
}

arena_gpu_pointer :: ($T: Type, offset: VkDeviceSize) -> Gpu_Pointer(T) {
    return .{address = arena_address(offset)};
}
