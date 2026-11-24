DEPTH_FORMAT : VkFormat : .D32_SFLOAT;
HDR_FORMAT   : VkFormat : .R16G16B16A16_SFLOAT;

renderer_context : struct {
    light_direction : Vector3;
    sun_intensity   : float = 3.0;
    exposure        : float = 1.0;
    debug_view      : Debug_View;
    animate         := true;
    animation_time  : float;

    material_shaders     : [2] VkShaderEXT;
    depth_shaders        : [2] VkShaderEXT;
    masked_depth_shaders : [2] VkShaderEXT;
    tonemap_shaders      : [2] VkShaderEXT;
    wave_shader          : VkShaderEXT;
    skin_shader          : VkShaderEXT;

    target_heap : Heap;
    depth_image : VkImage;
    depth_view  : VkImageView;
    hdr_image   : VkImage;
    hdr_view    : VkImageView;
    hdr_texture : Texture_Handle;
}

Frame_Constants :: struct @Gpu {
    view_projection : Matrix4;
    tlas_address    : u64;
    light_direction : Vector3;
    sun_intensity   : float;
    camera_position : Vector3;
    debug_view      : Debug_View;
}

Debug_View :: enum u32 {
    LIT;
    BASE_COLOR;
    NORMALS;
    METALLIC_ROUGHNESS;
    SUN_ONLY;
    AMBIENT_ONLY;
}

DEBUG_VIEW_NAMES :: "Lit\0Base color\0Normals\0Metallic (R) / roughness (G)\0Sun only\0Ambient only\0\0";

Push_Data :: struct @Gpu {
    frame      : Gpu_Pointer(Frame_Constants);
    draws      : Gpu_Pointer(Draw_Data);
    materials  : Gpu_Pointer(Material);
}

Tonemap_Push_Data :: struct @Gpu {
    hdr      : Texture_Handle;
    exposure : float;
    raw      : u32;
}

Deform_Push_Data :: struct @Gpu {
    source_positions  : Gpu_Pointer(Vector3);
    source_attributes : Gpu_Pointer(Packed_Vertex_Attributes);
    positions         : Gpu_Pointer(Vector3);
    attributes        : Gpu_Pointer(Packed_Vertex_Attributes);
    skin_vertices     : Gpu_Pointer(Skin_Vertex);
    joint_matrices    : Gpu_Pointer(Matrix4x3);
    vertex_count      : u32;
    time              : float;
}

init_renderer :: () {
    renderer_context.material_shaders     = create_graphics_shaders("material");
    renderer_context.tonemap_shaders      = create_graphics_shaders("tonemap");
    renderer_context.depth_shaders        = create_vertex_only_shaders("material", "depth_vertex_main");
    renderer_context.masked_depth_shaders = create_graphics_shaders("material", "masked_depth_vertex_main", "depth_fragment_main");
    renderer_context.wave_shader          = create_compute_shader("wave", "wave_main");
    renderer_context.skin_shader          = create_compute_shader("skin", "skin_main");

    init_image_heap(*renderer_context.target_heap, "render target heap", 256 * MiB, DEPTH_FORMAT, .DEPTH_STENCIL_ATTACHMENT);
    renderer_context.hdr_texture = .{id = reserve_image_descriptor()};
    create_render_targets();
}

deinit_renderer :: () {
    destroy_render_targets();
    destroy_heap(renderer_context.target_heap);
    destroy_shaders(renderer_context.material_shaders);
    destroy_shaders(renderer_context.tonemap_shaders);
    destroy_shaders(renderer_context.depth_shaders);
    destroy_shaders(renderer_context.masked_depth_shaders);
    destroy_shaders(renderer_context.wave_shader);
    destroy_shaders(renderer_context.skin_shader);
}

resize_render_targets :: () {
    destroy_render_targets();
    create_render_targets();
}

renderer_debug_ui :: () {
    io := ImGui.GetIO();

    OVERLAY_FLAGS :: ImGui.WindowFlags.NoDecoration | .AlwaysAutoResize | .NoSavedSettings | .NoFocusOnAppearing | .NoInputs;

    MARGIN :: 10.0;
    ImGui.SetNextWindowPos(.{MARGIN, MARGIN}, .Always);
    ImGui.SetNextWindowBgAlpha(0.6);
    if ImGui.Begin("##stats", null, OVERLAY_FLAGS) {
        frame_ms := ifx io.Framerate > 0 then 1000.0 / io.Framerate else 0;
        ImGui.Text("% ms (% FPS)",
            formatFloat(frame_ms,     trailing_width = 2, zero_removal = .NO),
            formatFloat(io.Framerate, trailing_width = 1, zero_removal = .NO));
        ImGui.Text("GPU % ms", formatFloat(frame_context.gpu_ms, trailing_width = 2, zero_removal = .NO));
    }
    ImGui.End();

    ImGui.SetNextWindowPos(.{MARGIN, 90}, .FirstUseEver);
    if ImGui.Begin("Lighting", null, .AlwaysAutoResize | .NoSavedSettings) {
        ImGui.SliderFloat("Sun", *renderer_context.sun_intensity, 0, 10);
        ImGui.SliderFloat("Exposure", *renderer_context.exposure, 0.1, 4);
        ImGui.Combo("View", cast(*s32) *renderer_context.debug_view, DEBUG_VIEW_NAMES.data);
        ImGui.Checkbox("Animate", *renderer_context.animate);
    }
    ImGui.End();
}

draw_frame :: () {
    frame, acquired := begin_frame();
    if !acquired return;

    command_buffer := frame.command_buffer;

    bind_descriptor_heaps(command_buffer);
    deform_pass(command_buffer, frame.heap);
    update_acceleration_structures(command_buffer, frame.heap);

    pipeline_barrier(command_buffer, .[
        image_barrier(renderer_context.depth_image, .EARLY_FRAGMENT_TESTS | .LATE_FRAGMENT_TESTS, .NONE, .EARLY_FRAGMENT_TESTS | .LATE_FRAGMENT_TESTS, .DEPTH_STENCIL_ATTACHMENT_READ | .DEPTH_STENCIL_ATTACHMENT_WRITE, aspect = .DEPTH),
        image_barrier(renderer_context.hdr_image, .FRAGMENT_SHADER, .NONE, .COLOR_ATTACHMENT_OUTPUT, .COLOR_ATTACHMENT_WRITE),
    ]);

    color_attachment := VkRenderingAttachmentInfoKHR.{imageView = renderer_context.hdr_view, imageLayout = .GENERAL, loadOp = .CLEAR, storeOp = .STORE};
    color_attachment.clearValue.color.float32_ = xx srgb(0.1, 0.1, 0.12).component;

    depth_attachment := VkRenderingAttachmentInfoKHR.{imageView = renderer_context.depth_view, imageLayout = .GENERAL, loadOp = .CLEAR, storeOp = .DONT_CARE};
    depth_attachment.clearValue.depthStencil = .{depth = 1};

    rendering_info := VkRenderingInfo.{
        renderArea           = .{extent = swapchain_context.extent},
        layerCount           = 1,
        colorAttachmentCount = 1,
        pColorAttachments    = *color_attachment,
        pDepthAttachment     = *depth_attachment,
    };
    vkCmdBeginRendering(command_buffer, *rendering_info);

    set_draw_state(command_buffer);

    frame_constants_offset := heap_allocate(frame.heap, size_of(Frame_Constants), 256);
    aspect := cast(float) swapchain_context.extent.width / cast(float) swapchain_context.extent.height;

    frame_constants := cast(*Frame_Constants) heap_pointer(frame.heap, frame_constants_offset);
    frame_constants.view_projection = camera_view_projection(aspect);
    frame_constants.tlas_address    = scene_context.tlas.address;
    frame_constants.light_direction = renderer_context.light_direction;
    frame_constants.sun_intensity   = renderer_context.sun_intensity;
    frame_constants.camera_position = camera_context.position;
    frame_constants.debug_view      = renderer_context.debug_view;

    push_data := Push_Data.{
        frame     = heap_gpu_pointer(frame.heap, Frame_Constants, frame_constants_offset),
        draws     = heap_gpu_pointer(*heap_context.buffer, Draw_Data, scene_context.draws_offset),
        materials = heap_gpu_pointer(*heap_context.buffer, Material, scene_context.materials_offset),
    };

    push(command_buffer, push_data);

    index_buffer_info := VkBindIndexBuffer3InfoKHR.{
        addressRange = .{address = heap_context.buffer.address, size = heap_context.buffer.size},
        addressFlags = .STORAGE_BUFFER_USAGE,
        indexType    = .UINT32,
    };
    vkCmdBindIndexBuffer3KHR(command_buffer, *index_buffer_info);

    draw_count   := cast(u32) scene_context.draws.count;
    opaque_count := scene_context.opaque_draw_count;

    no_components : VkColorComponentFlags;
    vkCmdSetColorWriteMaskEXT(command_buffer, 0, 1, *no_components);
    bind_shaders(command_buffer, renderer_context.depth_shaders);
    draw_commands(command_buffer, 0, opaque_count);
    bind_shaders(command_buffer, renderer_context.masked_depth_shaders);
    draw_commands(command_buffer, opaque_count, draw_count - opaque_count);
    vkCmdEndRendering(command_buffer);

    pipeline_barrier(command_buffer, .[
        image_barrier(renderer_context.depth_image, .EARLY_FRAGMENT_TESTS | .LATE_FRAGMENT_TESTS, .DEPTH_STENCIL_ATTACHMENT_WRITE, .EARLY_FRAGMENT_TESTS | .LATE_FRAGMENT_TESTS, .DEPTH_STENCIL_ATTACHMENT_READ | .DEPTH_STENCIL_ATTACHMENT_WRITE, aspect = .DEPTH, old_layout = .GENERAL),
    ]);
    depth_attachment.loadOp = .LOAD;
    vkCmdBeginRendering(command_buffer, *rendering_info);
    set_draw_state(command_buffer);
    push(command_buffer, push_data);
    vkCmdBindIndexBuffer3KHR(command_buffer, *index_buffer_info);

    all_components := VkColorComponentFlags.R | .G | .B | .A;
    vkCmdSetColorWriteMaskEXT(command_buffer, 0, 1, *all_components);
    vkCmdSetDepthWriteEnable(command_buffer, VK_FALSE);
    vkCmdSetDepthCompareOp(command_buffer, .EQUAL);
    bind_shaders(command_buffer, renderer_context.material_shaders);
    draw_commands(command_buffer, 0, draw_count);

    vkCmdEndRendering(command_buffer);

    memory_barrier(command_buffer, .COLOR_ATTACHMENT_OUTPUT, .COLOR_ATTACHMENT_WRITE, .FRAGMENT_SHADER, .SHADER_SAMPLED_READ);

    swapchain_attachment := VkRenderingAttachmentInfoKHR.{
        imageView   = frame.swapchain_view,
        imageLayout = .GENERAL,
        loadOp      = .DONT_CARE,
        storeOp     = .STORE,
    };
    tonemap_rendering_info := VkRenderingInfo.{
        renderArea           = .{extent = swapchain_context.extent},
        layerCount           = 1,
        colorAttachmentCount = 1,
        pColorAttachments    = *swapchain_attachment,
    };
    vkCmdBeginRendering(command_buffer, *tonemap_rendering_info);

    vkCmdSetDepthTestEnable(command_buffer,  VK_FALSE);
    vkCmdSetDepthWriteEnable(command_buffer, VK_FALSE);
    bind_shaders(command_buffer, renderer_context.tonemap_shaders);

    tonemap_push_data := Tonemap_Push_Data.{hdr = renderer_context.hdr_texture, exposure = renderer_context.exposure, raw = xx (renderer_context.debug_view != .LIT)};
    push(command_buffer, tonemap_push_data);

    vkCmdDraw(command_buffer, vertexCount = 3, instanceCount = 1, firstVertex = 0, firstInstance = 0);

    render_imgui(command_buffer, frame.heap);

    vkCmdEndRendering(command_buffer);

    if screenshot_context.requested {
        record_screenshot_copy(command_buffer, frame.swapchain_image);
    }

    end_frame(frame);
}

#scope_file

draw_commands :: (command_buffer: VkCommandBuffer, first: u32, count: u32) {
    if !count return;

    draw_info := VkDrawIndirect2InfoKHR.{
        addressRange = .{
            address = heap_address(*heap_context.buffer, scene_context.draw_commands_offset + first * size_of(VkDrawIndexedIndirectCommand)),
            size    = count * size_of(VkDrawIndexedIndirectCommand),
            stride  = size_of(VkDrawIndexedIndirectCommand),
        },
        addressFlags = .STORAGE_BUFFER_USAGE,
        drawCount    = count,
    };
    vkCmdDrawIndexedIndirect2KHR(command_buffer, *draw_info);
}

deform_pass :: (command_buffer: VkCommandBuffer, heap: *Heap) {
    if !scene_context.deformers.count return;

    joint_matrices := NewArray(animation_context.skeletons.count, Gpu_Pointer(Matrix4x3),, temp);
    for animation_context.skeletons {
        size := it.joint_matrices.count * size_of(Matrix4x3);
        offset := heap_allocate(heap, xx size, 16);
        memcpy(heap_pointer(heap, offset), it.joint_matrices.data, size);
        joint_matrices[it_index] = heap_gpu_pointer(heap, Matrix4x3, offset);
    }

    memory_barrier(command_buffer, .VERTEX_SHADER | .FRAGMENT_SHADER | .ACCELERATION_STRUCTURE_BUILD_KHR, .NONE, .COMPUTE_SHADER, .SHADER_STORAGE_WRITE);

    for scene_context.deformers {
        mesh := scene_context.draws[it.draw_index].mesh;
        push_data := Deform_Push_Data.{
            source_positions  = it.source_positions,
            source_attributes = it.source_attributes,
            positions         = mesh.positions,
            attributes        = mesh.attributes,
            vertex_count      = mesh.vertex_count,
        };
        if it.kind == {
            case .WAVE;
                bind_shaders(command_buffer, renderer_context.wave_shader);
                push_data.time = renderer_context.animation_time;
            case .SKIN;
                bind_shaders(command_buffer, renderer_context.skin_shader);
                push_data.skin_vertices  = it.skin_vertices;
                push_data.joint_matrices = joint_matrices[it.skeleton_index];
        }
        push(command_buffer, push_data);
        dispatch(command_buffer, mesh.vertex_count, 64);
    }

    memory_barrier(command_buffer, .COMPUTE_SHADER, .SHADER_STORAGE_WRITE, .ACCELERATION_STRUCTURE_BUILD_KHR | .VERTEX_SHADER | .FRAGMENT_SHADER, .SHADER_READ);
}

create_render_targets :: () {
    create :: (format: VkFormat, usage: VkImageUsageFlags, aspect: VkImageAspectFlags, name: string) -> VkImage, VkImageView, VkImageViewCreateInfo {
        image_create_info := VkImageCreateInfo.{
            imageType   = .e2D,
            format      = format,
            extent      = .{width = swapchain_context.extent.width, height = swapchain_context.extent.height, depth = 1},
            mipLevels   = 1,
            arrayLayers = 1,
            samples     = .e1,
            tiling      = .OPTIMAL,
            usage       = usage,
        };
        image : VkImage;
        result := vkCreateImage(device_context.device, *image_create_info, null, *image);
        assert(result == .SUCCESS);
        heap_bind_image(*renderer_context.target_heap, image);

        view_create_info := VkImageViewCreateInfo.{
            image            = image,
            viewType         = .e2D,
            format           = format,
            subresourceRange = .{aspectMask = aspect, levelCount = 1, layerCount = 1},
        };
        view : VkImageView;
        result = vkCreateImageView(device_context.device, *view_create_info, null, *view);
        assert(result == .SUCCESS);

        set_debug_name(.IMAGE,      image, name);
        set_debug_name(.IMAGE_VIEW, view,  name);
        return image, view, view_create_info;
    }

    renderer_context.depth_image, renderer_context.depth_view = create(DEPTH_FORMAT, .DEPTH_STENCIL_ATTACHMENT, .DEPTH, "depth");

    hdr_view_info : VkImageViewCreateInfo;
    renderer_context.hdr_image, renderer_context.hdr_view, hdr_view_info = create(HDR_FORMAT, .COLOR_ATTACHMENT | .SAMPLED, .COLOR, "hdr");
    write_image_descriptor(renderer_context.hdr_texture.id, .SAMPLED_IMAGE, hdr_view_info);
}

destroy_render_targets :: () {
    vkDestroyImageView(device_context.device, renderer_context.hdr_view, null);
    vkDestroyImage(device_context.device, renderer_context.hdr_image, null);
    vkDestroyImageView(device_context.device, renderer_context.depth_view, null);
    vkDestroyImage(device_context.device, renderer_context.depth_image, null);
    heap_reset(*renderer_context.target_heap);
}

set_draw_state :: (command_buffer: VkCommandBuffer) {
    vkCmdSetRasterizerDiscardEnable(command_buffer, VK_FALSE);
    vkCmdSetPrimitiveRestartEnable(command_buffer,  VK_FALSE);

    vkCmdSetPrimitiveTopology(command_buffer,       .TRIANGLE_LIST);

    vkCmdSetDepthTestEnable(command_buffer,         VK_TRUE);
    vkCmdSetDepthWriteEnable(command_buffer,        VK_TRUE);
    vkCmdSetDepthCompareOp(command_buffer,          .LESS);
    vkCmdSetDepthBiasEnable(command_buffer,         VK_FALSE);
    vkCmdSetDepthBoundsTestEnable(command_buffer,   VK_FALSE);
    vkCmdSetDepthClampEnableEXT(command_buffer,     VK_FALSE);

    vkCmdSetStencilTestEnable(command_buffer,       VK_FALSE);

    vkCmdSetPolygonModeEXT(command_buffer,          .FILL);
    vkCmdSetFrontFace(command_buffer,               .CLOCKWISE);
    vkCmdSetCullMode(command_buffer,                .NONE);

    vkCmdSetAlphaToOneEnableEXT(command_buffer,     VK_FALSE);
    vkCmdSetAlphaToCoverageEnableEXT(command_buffer,VK_FALSE);
    vkCmdSetLogicOpEnableEXT(command_buffer,        VK_FALSE);

    color_blend_enable : VkBool32 = VK_FALSE;
    vkCmdSetColorBlendEnableEXT(command_buffer, 0, 1, *color_blend_enable);

    color_write_mask := VkColorComponentFlags.R | .G | .B | .A;
    vkCmdSetColorWriteMaskEXT(command_buffer, 0, 1, *color_write_mask);

    vkCmdSetRasterizationSamplesEXT(command_buffer, .e1);
    sample_mask : VkSampleMask = 1;
    vkCmdSetSampleMaskEXT(command_buffer, .e1, *sample_mask);

    viewport := VkViewport.{width = xx swapchain_context.extent.width, height = xx swapchain_context.extent.height, maxDepth = 1};
    vkCmdSetViewportWithCount(command_buffer, 1, *viewport);

    scissor := VkRect2D.{extent = swapchain_context.extent};
    vkCmdSetScissorWithCount(command_buffer, 1, *scissor);

    vkCmdSetVertexInputEXT(command_buffer, 0, null, 0, null);
}
