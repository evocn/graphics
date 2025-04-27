// Graphics
// Debug Shader
// April 2025

////////////////////////////////////////////////////////////////////////////////
// Inputs
cbuffer Uniforms
{
    float4x4 modelViewProjection;
}

// Per-vertex attributes to be assembled from bound vertex buffers.
struct Vertex
{
    float3 position : POSITION;
    float3 color    : COLOR;
};

////////////////////////////////////////////////////////////////////////////////
// Struct definitions
struct CoarseVertex
{
    float3 color;
};


////////////////////////////////////////////////////////////////////////////////
// Vertex Shader
struct VertexStageOutput
{
    CoarseVertex    coarseVertex    : CoarseVertex;
    float4          sv_position     : SV_Position;
};

[shader("vertex")]
VertexStageOutput vertexMain(
    Vertex vertex
)
{
    VertexStageOutput output;

    float3 position = vertex.position;
    float3 color    = vertex.color;

    output.coarseVertex.color = color;
    output.sv_position = mul(modelViewProjection, float4(position, 1.0));

    return output;
}


////////////////////////////////////////////////////////////////////////////////
// Fragment Shader
struct FragmentStageOutput
{
    float4 color;
};

[shader("fragment")]
FragmentStageOutput fragmentMain(
    CoarseVertex coarseVertex : CoarseVertex
) : SV_Target
{
    float3 color = coarseVertex.color;

    FragmentStageOutput output;
    output.color = float4(color, 1.0);
    return output;
}
