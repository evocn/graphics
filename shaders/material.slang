// Graphics
// Material Shader

////////////////////////////////////////////////////////////////////////////////
// Structs

struct Vertex {
    float3 position;
    float3 color;
    float2 uv;
}

struct Frame_Constants {
    float4x4 view_projection;
    float    time;
}

struct Draw_Data {
    Vertex*                         vertices;
    DescriptorHandle<Texture2D>     texture;
    DescriptorHandle<SamplerState>  sampler;
}

struct Push_Data {
    Frame_Constants*    frame;
    Draw_Data*          draws;
    uint                draw_index;
}
[[vk::push_constant]] Push_Data push_data;

struct Coarse_Vertex {
    float3 color;
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
    Draw_Data draw = push_data.draws[push_data.draw_index];
    Vertex vertex = draw.vertices[vertex_id];

    float3 position = vertex.position;
    float3 color    = vertex.color;

    Vertex_Stage_Output output;
    {
        {
            output.coarse_vertex.color = color;
            output.coarse_vertex.uv = vertex.uv;
        }

        output.sv_position = mul(push_data.frame.view_projection, float4(position, 1.0));
    }

    return output;
}


////////////////////////////////////////////////////////////////////////////////
// Fragment Shader

struct Fragment_Stage_Output {
    float3 color;
}

[shader("fragment")]
Fragment_Stage_Output fragment_main(Coarse_Vertex coarse_vertex : CoarseVertex) : SV_Target {
    Draw_Data draw = push_data.draws[push_data.draw_index];

    float3 color = coarse_vertex.color;
    float4 texture_color = draw.texture.Sample(draw.sampler, coarse_vertex.uv);

    Fragment_Stage_Output output;
    {
        output.color = lerp(texture_color.xyz, color, texture_color.a);
    }
    return output;
}
