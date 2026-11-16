#include "generated/shared.slang"

[[vk::push_constant]] Skin_Push_Data push_data;

float3 transform_normal(float3 a, float3 b, float3 c, float3 normal) {
    float3 n = float3(dot(cross(b, c), normal), dot(cross(c, a), normal), dot(cross(a, b), normal));
    return dot(a, cross(b, c)) < 0.0 ? -n : n;
}

[shader("compute")]
[numthreads(64, 1, 1)]
void skin_main(uint3 thread_id : SV_DispatchThreadID) {
    uint index = thread_id.x;
    if (index >= push_data.vertex_count) return;

    Skin_Vertex skin = push_data.skin_vertices[index];
    uint4 joints = (uint4(skin.joints) >> uint4(0, 8, 16, 24)) & 0xFF;
    float4 weights = float4((uint4(skin.weights) >> uint4(0, 8, 16, 24)) & 0xFF) / 255.0;

    float4 row0 = float4(0.0);
    float4 row1 = float4(0.0);
    float4 row2 = float4(0.0);
    for (uint i = 0; i < 4; i++) {
        uint base = joints[i] * 3;
        row0 += weights[i] * push_data.joint_matrices[base + 0];
        row1 += weights[i] * push_data.joint_matrices[base + 1];
        row2 += weights[i] * push_data.joint_matrices[base + 2];
    }

    float4 position = float4(push_data.source_positions[index], 1.0);
    Vertex_Attributes attributes = push_data.source_attributes[index];

    float3x3 linear = float3x3(row0.xyz, row1.xyz, row2.xyz);
    attributes.normal      = normalize(transform_normal(row0.xyz, row1.xyz, row2.xyz, attributes.normal));
    attributes.tangent.xyz = normalize(mul(linear, attributes.tangent.xyz));

    push_data.positions[index]  = float3(dot(row0, position), dot(row1, position), dot(row2, position));
    push_data.attributes[index] = attributes;
}
