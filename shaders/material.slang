// Graphics
// Material Shader

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
            output.coarse_vertex.uv = float2(0.0, 0.0);
        }

        output.sv_position = float4(position, 1.0);
    }

    return output;
}


////////////////////////////////////////////////////////////////////////////////
// Fragment Shader

uniform StructuredBuffer<DescriptorHandle<Texture2D>> textures;
uniform StructuredBuffer<DescriptorHandle<Sampler2D>> samplers;
uniform int sampler_index;

struct Fragment_Stage_Output {
    float3 color;
}

[shader("fragment")]
Fragment_Stage_Output fragment_main(Coarse_Vertex coarse_vertex : CoarseVertex) : SV_Target {
    float3 color = coarse_vertex.color;
    float4 texture_color = samplers[sampler_index].Sample(coarse_vertex.uv);

    Fragment_Stage_Output output;
    {
        output.color = lerp(texture_color.xyz, color, 0.5);
    }
    return output;
}
