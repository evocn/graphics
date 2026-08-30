// Graphics
// ImGui Shader

////////////////////////////////////////////////////////////////////////////////
// Structs

// Matches ImGui.ImDrawVert: pos, uv, packed RGBA8 color.
struct ImDrawVert {
    float2 position;
    float2 uv;
    uint   color;
}

struct Push_Data {
    ImDrawVert*                     vertices;
    float2                          scale;
    float2                          translate;
    DescriptorHandle<Texture2D>     texture;
    DescriptorHandle<SamplerState>  sampler;
}
[[vk::push_constant]] Push_Data push_data;

struct Coarse_Vertex {
    float4 color;
    float2 uv;
}

////////////////////////////////////////////////////////////////////////////////
// Vertex Shader

struct Vertex_Stage_Output {
    Coarse_Vertex   coarse_vertex   : CoarseVertex;
    float4          sv_position     : SV_Position;
}

[shader("vertex")]
Vertex_Stage_Output vertex_main(uint vertex_id : SV_VertexID) {
    ImDrawVert vertex = push_data.vertices[vertex_id];

    uint c = vertex.color;
    float4 color = float4(c & 0xFF, (c >> 8) & 0xFF, (c >> 16) & 0xFF, (c >> 24) & 0xFF) / 255.0;

    Vertex_Stage_Output output;
    {
        output.coarse_vertex.color = color;
        output.coarse_vertex.uv    = vertex.uv;

        output.sv_position = float4(vertex.position * push_data.scale + push_data.translate, 0.0, 1.0);
    }

    return output;
}

////////////////////////////////////////////////////////////////////////////////
// Fragment Shader

struct Fragment_Stage_Output {
    float4 color;
}

[shader("fragment")]
Fragment_Stage_Output fragment_main(Coarse_Vertex coarse_vertex : CoarseVertex) : SV_Target {
    Fragment_Stage_Output output;
    {
        output.color = coarse_vertex.color * push_data.texture.Sample(push_data.sampler, coarse_vertex.uv);
    }
    return output;
}
