#include "generated/shared.slang"

[[vk::push_constant]] Imgui_Push_Data push_data;

struct Coarse_Vertex {
    float4 color;
    float2 uv;
}

struct Vertex_Stage_Output {
    Coarse_Vertex   coarse_vertex   : CoarseVertex;
    float4          sv_position     : SV_Position;
}

float3 linear_from_srgb(float3 c) {
    return select(c <= 0.04045, c / 12.92, pow((c + 0.055) / 1.055, 2.4));
}

[shader("vertex")]
Vertex_Stage_Output vertex_main(uint vertex_id : SV_VertexID) {
    ImDrawVert vertex = push_data.vertices[vertex_id];

    uint c = vertex.col;
    float4 color = float4(c & 0xFF, (c >> 8) & 0xFF, (c >> 16) & 0xFF, (c >> 24) & 0xFF) / 255.0;
    color.rgb = linear_from_srgb(color.rgb);

    Vertex_Stage_Output output;
    {
        output.coarse_vertex.color = color;
        output.coarse_vertex.uv    = vertex.uv;

        output.sv_position = float4(vertex.pos * push_data.scale + push_data.translate, 0.0, 1.0);
    }

    return output;
}

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
