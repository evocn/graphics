scene_context : struct {
    textures         : [..] Texture;
    materials        : [..] Material;
    materials_offset : VkDeviceSize;

    white_texture       : Texture_Handle;
    flat_normal_texture : Texture_Handle;

    draws                : [..] Draw;
    draws_offset         : VkDeviceSize;
    draw_commands_offset : VkDeviceSize;
    opaque_draw_count    : u32;

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
    source_positions  : Gpu_Pointer(Vector3);
    source_attributes : Gpu_Pointer(Packed_Vertex_Attributes);
    skin_vertices     : Gpu_Pointer(Skin_Vertex);
    draw_index        : u32;
    skeleton_index    : u32;
    kind              : Deformer_Kind;
}

Vertex_Attributes :: struct {
    normal  : Vector3;
    tangent : Vector4;
    uv      : Vector2;
}

Packed_Vertex_Attributes :: struct @Gpu {
    normal  : u32;
    tangent : u32;
    uv      : Vector2;
}

Skin_Vertex :: struct @Gpu {
    joints  : u32;
    weights : u32;
}

Material :: struct @Gpu {
    base_color   : Vector4;
    metallic     : float = 0;
    roughness    : float = 1;
    normal_scale : float = 1;
    alpha_cutoff : float;

    texture                    : Texture_Handle;
    normal_texture             : Texture_Handle;
    metallic_roughness_texture : Texture_Handle;
    sampler                    : Sampler_Handle;
}

Mesh :: struct {
    positions    : Gpu_Pointer(Vector3);
    attributes   : Gpu_Pointer(Packed_Vertex_Attributes);
    indices      : Gpu_Pointer(u32);
    vertex_count : u32;
    index_count  : u32;
}

Draw :: struct {
    mesh           : Mesh;
    material_index : u32;
    transform      : Matrix4x3;
}

Draw_Data :: struct @Gpu {
    transform      : Matrix4x3;
    positions      : Gpu_Pointer(Vector3);
    attributes     : Gpu_Pointer(Packed_Vertex_Attributes);
    indices        : Gpu_Pointer(u32);
    material_index : u32;
}

init_scene :: () {
    white_pixel : u32 = 0xFFFFFFFF;
    scene_context.white_texture = add_texture(create_texture(*white_pixel, 1, 1, .R8G8B8A8_SRGB, "white texture"));

    flat_normal_pixel : u32 = 0xFFFF8080;
    scene_context.flat_normal_texture = add_texture(create_texture(*flat_normal_pixel, 1, 1, .R8G8B8A8_UNORM, "flat normal texture"));
}

build_scene :: () {
    scene_context.materials_offset = upload(scene_context.materials);
    draw_data := NewArray(scene_context.draws.count, Draw_Data,, temp);
    for scene_context.draws {
        draw_data[it_index] = .{
            transform      = it.transform,
            positions      = it.mesh.positions,
            attributes     = it.mesh.attributes,
            indices        = it.mesh.indices,
            material_index = it.material_index,
        };
    }
    scene_context.draws_offset = upload(draw_data);

    draw_commands : [..] VkDrawIndexedIndirectCommand;
    draw_commands.allocator = temp;
    for masked : bool.[false, true] {
        for scene_context.draws {
            if is_masked(it) != masked continue;
            array_add(*draw_commands, .{
                indexCount    = it.mesh.index_count,
                instanceCount = 1,
                firstIndex    = xx ((it.mesh.indices.address - heap_context.buffer.address) / size_of(u32)),
                firstInstance = xx it_index,
            });
        }
        if !masked  scene_context.opaque_draw_count = xx draw_commands.count;
    }
    scene_context.draw_commands_offset = upload(draw_commands);

    if !scene_context.ray_tracing return;

    deformed := NewArray(scene_context.draws.count, bool,, temp);
    for scene_context.deformers  deformed[it.draw_index] = true;

    for scene_context.draws {
        geometry := triangle_geometry(it);
        primitive_count := it.mesh.index_count / 3;
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
            primitive_count := draw.mesh.index_count / 3;
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

add_mesh :: (positions: [] Vector3, attributes: [] Vertex_Attributes, indices: [] u32) -> Mesh {
    assert(positions.count == attributes.count);
    assert(indices.count % 3 == 0);

    packed := NewArray(attributes.count, Packed_Vertex_Attributes,, temp);
    for attributes  packed[it_index] = pack_vertex_attributes(it);

    return .{
        positions    = heap_gpu_pointer(*heap_context.buffer, Vector3,                  upload(positions)),
        attributes   = heap_gpu_pointer(*heap_context.buffer, Packed_Vertex_Attributes, upload(packed)),
        indices      = heap_gpu_pointer(*heap_context.buffer, u32,                      upload(indices)),
        vertex_count = xx positions.count,
        index_count  = xx indices.count,
    };
}

add_draw :: (mesh: Mesh, material_index: u32, transform: Matrix4) {
    array_add(*scene_context.draws, .{mesh = mesh, material_index = material_index, transform = affine(transform)});
}

add_deformable_draw :: (mesh: Mesh, material_index: u32, transform: Matrix4, deformer_in: Deformer) {
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

pack_vertex_attributes :: (attributes: Vertex_Attributes) -> Packed_Vertex_Attributes {
    tangent_sign : u32 = xx ifx attributes.tangent.w < 0 then 1 else 0;
    return .{
        normal  = pack_snorm16x2(octahedral_encode(attributes.normal)),
        tangent = (pack_snorm16x2(octahedral_encode(attributes.tangent.xyz)) & 0xFFFF_FFFE) | tangent_sign,
        uv      = attributes.uv,
    };
}

octahedral_encode :: (n: Vector3) -> Vector2 {
    sign_not_zero :: (x: float) -> float { return ifx x >= 0 then 1.0 else -1.0; }

    p := Vector2.{n.x, n.y} / (abs(n.x) + abs(n.y) + abs(n.z));
    if n.z < 0  p = .{(1 - abs(p.y)) * sign_not_zero(p.x), (1 - abs(p.x)) * sign_not_zero(p.y)};
    return p;
}

pack_snorm16x2 :: (v: Vector2) -> u32 {
    snorm16 :: (x: float) -> u32 {
        quantized := cast(s32) floor(clamp(x, -1, 1) * 32767 + 0.5);
        return cast,no_check(u32) quantized & 0xFFFF;
    }
    return snorm16(v.x) | (snorm16(v.y) << 16);
}

affine :: (m: Matrix4) -> Matrix4x3 {
    result : Matrix4x3;
    for 0..2  result.v[it] = m.v[it];
    return result;
}

is_masked :: (draw: Draw) -> bool {
    return scene_context.materials[draw.material_index].alpha_cutoff != 0;
}

triangle_geometry :: (draw: Draw) -> VkAccelerationStructureGeometryKHR {
    geometry := VkAccelerationStructureGeometryKHR.{geometryType = .TRIANGLES};
    if !is_masked(draw)  geometry.flags = .OPAQUE;
    geometry.geometry.triangles = .{
        vertexFormat             = .R32G32B32_SFLOAT,
        vertexData.deviceAddress = draw.mesh.positions.address,
        vertexStride             = size_of(Vector3),
        maxVertex                = draw.mesh.vertex_count - 1,
        indexType                = .UINT32,
        indexData.deviceAddress  = draw.mesh.indices.address,
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
