scene_context : struct {
    textures         : [..] Texture;
    materials        : [..] Material;
    materials_offset : VkDeviceSize;

    white_texture       : Texture_Handle;
    flat_normal_texture : Texture_Handle;

    draws                : [..] Draw_Data;
    draws_offset         : VkDeviceSize;
    draw_commands_offset : VkDeviceSize;

    deformers : [..] Deformer;

    ray_tracing : bool = true;
    blases      : [..] Acceleration_Structure;
    tlas        : Acceleration_Structure;
}

Deformer_Kind :: enum u8 {
    WAVE;
    SKIN;
}

Deformer :: struct {
    kind              : Deformer_Kind;
    draw_index        : u32;
    source_positions  : Gpu_Pointer(Vector3);
    source_attributes : Gpu_Pointer(Vertex_Attributes);
    skin_vertices     : Gpu_Pointer(Skin_Vertex);
    skeleton_index    : u32;
}

Vertex_Attributes :: struct @Gpu {
    normal  : Vector3;
    tangent : Vector4;
    uv      : Vector2;
}

Skin_Vertex :: struct @Gpu {
    joints  : u32;
    weights : u32;
}

Material :: struct @Gpu {
    base_color   : Vector4;
    texture      : Texture_Handle;
    sampler      : Sampler_Handle;
    alpha_cutoff : float;

    normal_texture             : Texture_Handle;
    metallic_roughness_texture : Texture_Handle;
    normal_scale               : float = 1;
    metallic                   : float = 0;
    roughness                  : float = 1;
}

Draw_Data :: struct @Gpu {
    transform      : Matrix4;
    positions      : Gpu_Pointer(Vector3);
    attributes     : Gpu_Pointer(Vertex_Attributes);
    indices        : Gpu_Pointer(u32);
    material_index : u32;
    vertex_count   : u32;
    index_count    : u32;
}

init_scene :: () {
    white_pixel : u32 = 0xFFFFFFFF;
    scene_context.white_texture = add_texture(create_texture(*white_pixel, 1, 1, .R8G8B8A8_SRGB, "white texture"));

    flat_normal_pixel : u32 = 0xFFFF8080;
    scene_context.flat_normal_texture = add_texture(create_texture(*flat_normal_pixel, 1, 1, .R8G8B8A8_UNORM, "flat normal texture"));
}

build_scene :: () {
    scene_context.materials_offset = upload(scene_context.materials);
    scene_context.draws_offset     = upload(scene_context.draws);

    draw_commands := NewArray(scene_context.draws.count, VkDrawIndexedIndirectCommand,, temp);
    for scene_context.draws {
        draw_commands[it_index] = .{
            indexCount    = it.index_count,
            instanceCount = 1,
            firstIndex    = xx ((it.indices.address - heap_context.buffer.address) / size_of(u32)),
            firstInstance = xx it_index,
        };
    }
    scene_context.draw_commands_offset = upload(draw_commands);

    if !scene_context.ray_tracing return;

    deformed := NewArray(scene_context.draws.count, bool,, temp);
    for scene_context.deformers  deformed[it.draw_index] = true;

    for scene_context.draws {
        geometry := triangle_geometry(it);
        primitive_count := it.index_count / 3;
        flags := ifx deformed[it_index] then VkBuildAccelerationStructureFlagsKHR.PREFER_FAST_BUILD | .ALLOW_UPDATE else .PREFER_FAST_TRACE;
        blas := create_acceleration_structure(.BOTTOM_LEVEL, flags, .[geometry], .[primitive_count]);
        record_acceleration_structure_build(upload_context.command_buffer, blas, .BUILD, .[geometry], .[primitive_count], *heap_context.scratch);
        array_add(*scene_context.blases, blas);
    }
    memory_barrier(upload_context.command_buffer, .ACCELERATION_STRUCTURE_BUILD_KHR, .ACCELERATION_STRUCTURE_WRITE_KHR, .ACCELERATION_STRUCTURE_BUILD_KHR, .ACCELERATION_STRUCTURE_READ_KHR);

    instance_count := cast(u32) scene_context.draws.count;
    scene_context.tlas = create_acceleration_structure(.TOP_LEVEL, .PREFER_FAST_BUILD, .[instance_geometry(0)], .[instance_count]);
}

update_acceleration_structures :: (command_buffer: VkCommandBuffer, heap: *Heap) {
    if !scene_context.ray_tracing return;

    memory_barrier(command_buffer, .FRAGMENT_SHADER, .NONE, .ACCELERATION_STRUCTURE_BUILD_KHR, .ACCELERATION_STRUCTURE_WRITE_KHR);

    if scene_context.deformers.count {
        for scene_context.deformers {
            draw := scene_context.draws[it.draw_index];
            geometry := triangle_geometry(draw);
            primitive_count := draw.index_count / 3;
            record_acceleration_structure_build(command_buffer, scene_context.blases[it.draw_index], .UPDATE, .[geometry], .[primitive_count], heap);
        }
        memory_barrier(command_buffer, .ACCELERATION_STRUCTURE_BUILD_KHR, .ACCELERATION_STRUCTURE_WRITE_KHR, .ACCELERATION_STRUCTURE_BUILD_KHR, .ACCELERATION_STRUCTURE_READ_KHR);
    }

    tlas_geometry := instance_geometry(write_tlas_instances(heap));
    instance_count := cast(u32) scene_context.draws.count;
    record_acceleration_structure_build(command_buffer, scene_context.tlas, .BUILD, .[tlas_geometry], .[instance_count], heap);

    memory_barrier(command_buffer, .ACCELERATION_STRUCTURE_BUILD_KHR, .ACCELERATION_STRUCTURE_WRITE_KHR, .FRAGMENT_SHADER, .ACCELERATION_STRUCTURE_READ_KHR);
}

deinit_scene :: () {
    destroy_acceleration_structure(scene_context.tlas);
    for scene_context.blases  destroy_acceleration_structure(it);
    array_free(scene_context.blases);
    array_free(scene_context.deformers);
    array_free(scene_context.draws);
    array_free(scene_context.materials);
    for scene_context.textures  destroy_texture(it);
    array_free(scene_context.textures);
}

add_texture :: (texture: Texture) -> Texture_Handle {
    array_add(*scene_context.textures, texture);
    return texture.handle;
}

add_material :: (material_in: Material) -> u32 {
    material := material_in;
    if material.texture.id == 0                     material.texture = scene_context.white_texture;
    if material.normal_texture.id == 0              material.normal_texture = scene_context.flat_normal_texture;
    if material.metallic_roughness_texture.id == 0  material.metallic_roughness_texture = scene_context.white_texture;
    array_add(*scene_context.materials, material);
    return xx (scene_context.materials.count - 1);
}

add_mesh :: (positions: [] Vector3, attributes: [] Vertex_Attributes, indices: [] u32) -> Draw_Data {
    assert(positions.count == attributes.count);
    assert(indices.count % 3 == 0);

    return .{
        transform    = Matrix4_Identity,
        positions    = heap_gpu_pointer(*heap_context.buffer, Vector3,           upload(positions)),
        attributes   = heap_gpu_pointer(*heap_context.buffer, Vertex_Attributes, upload(attributes)),
        indices      = heap_gpu_pointer(*heap_context.buffer, u32,               upload(indices)),
        vertex_count = xx positions.count,
        index_count  = xx indices.count,
    };
}

add_draw :: (mesh: Draw_Data, material_index: u32, transform: Matrix4) {
    draw := mesh;
    draw.material_index = material_index;
    draw.transform      = transform;
    array_add(*scene_context.draws, draw);
}

add_deformable_draw :: (mesh: Draw_Data, material_index: u32, transform: Matrix4, deformer_in: Deformer) {
    deformer := deformer_in;
    deformer.draw_index        = xx scene_context.draws.count;
    deformer.source_positions  = mesh.positions;
    deformer.source_attributes = mesh.attributes;
    array_add(*scene_context.deformers, deformer);

    deformed := mesh;
    deformed.positions  = duplicate(mesh.positions,  mesh.vertex_count);
    deformed.attributes = duplicate(mesh.attributes, mesh.vertex_count);
    add_draw(deformed, material_index, transform);
}

add_skin_vertices :: (skin_vertices: [] Skin_Vertex) -> Gpu_Pointer(Skin_Vertex) {
    return heap_gpu_pointer(*heap_context.buffer, Skin_Vertex, upload(skin_vertices));
}

#scope_file

duplicate :: (source: Gpu_Pointer($T), count: u32) -> Gpu_Pointer(T) {
    size := count * size_of(T);
    offset := heap_allocate(*heap_context.buffer, xx size, 256);
    memcpy(heap_pointer(*heap_context.buffer, offset), heap_pointer(*heap_context.buffer, source.address - heap_context.buffer.address), size);
    return heap_gpu_pointer(*heap_context.buffer, T, offset);
}

triangle_geometry :: (draw: Draw_Data) -> VkAccelerationStructureGeometryKHR {
    geometry := VkAccelerationStructureGeometryKHR.{geometryType = .TRIANGLES};
    if scene_context.materials[draw.material_index].alpha_cutoff == 0  geometry.flags = .OPAQUE;
    geometry.geometry.triangles = .{
        vertexFormat             = .R32G32B32_SFLOAT,
        vertexData.deviceAddress = draw.positions.address,
        vertexStride             = size_of(Vector3),
        maxVertex                = draw.vertex_count - 1,
        indexType                = .UINT32,
        indexData.deviceAddress  = draw.indices.address,
    };
    return geometry;
}

write_tlas_instances :: (heap: *Heap) -> VkDeviceAddress {
    assert(scene_context.draws.count < 1 << 24);
    size := cast(VkDeviceSize) (scene_context.draws.count * size_of(VkAccelerationStructureInstanceKHR));
    offset := heap_allocate(heap, size, 16);
    instances : [] VkAccelerationStructureInstanceKHR = .{scene_context.draws.count, heap_pointer(heap, offset)};
    for scene_context.draws {
        instance := *instances[it_index];
        for row : 0..2  for column : 0..3  instance.transform.matrix[row][column] = it.transform.v[row].component[column];
        instance.__bitmask0 = cast(u32) it_index | (0xFF << 24);
        instance.__bitmask1 = cast(u32) VkGeometryInstanceFlagsKHR.TRIANGLE_FACING_CULL_DISABLE << 24;
        instance.accelerationStructureReference = scene_context.blases[it_index].address;
    }
    return heap_address(heap, offset);
}

upload :: (array: [] $T) -> VkDeviceSize {
    size := array.count * size_of(T);
    offset := heap_allocate(*heap_context.buffer, xx size, 256);
    memcpy(heap_pointer(*heap_context.buffer, offset), array.data, size);
    return offset;
}
