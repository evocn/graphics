// Graphics
// Material Shader

struct Push_Data {
    DescriptorHandle<Texture2D>     texture;
    DescriptorHandle<SamplerState>  sampler;
}
[[vk::push_constant]] Push_Data push_data;

////////////////////////////////////////////////////////////////////////////////
// Structs

struct Coarse_Vertex {
    float3 color;
    float2 uv;
}

////////////////////////////////////////////////////////////////////////////////
// Vertex Shader

struct Vertex {
    float3 position : POSITION;
    float3 color    : COLOR;
    float2 uv       : TEXCOORD;
}

struct Vertex_Stage_Output {
    Coarse_Vertex   coarse_vertex   : CoarseVertex;
    float4          sv_position     : SV_Position;
}

[shader("vertex")]
Vertex_Stage_Output vertex_main(Vertex vertex) {
    float3 position = vertex.position;
    float3 color    = vertex.color;

    Vertex_Stage_Output output;
    {
        {
            output.coarse_vertex.color = color;
            output.coarse_vertex.uv = vertex.uv;
        }

        output.sv_position = float4(position, 1.0);
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
    float3 color = coarse_vertex.color;
    float4 texture_color = push_data.texture.Sample(push_data.sampler, coarse_vertex.uv);

    Fragment_Stage_Output output;
    {
        output.color = lerp(texture_color.xyz, color, texture_color.a);
    }
    return output;
}
