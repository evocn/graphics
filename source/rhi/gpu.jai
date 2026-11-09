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

Storage_Image_Handle :: struct {
    id      : u32;
    padding : u32;
}
