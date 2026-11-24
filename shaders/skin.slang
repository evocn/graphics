#include "geometry.slang"

[[vk::push_constant]] Skin_Push_Data push_data;

[shader("compute")]
[numthreads(64, 1, 1)]
void skin_main(uint3 thread_id : SV_DispatchThreadID) {
    uint index = thread_id.x;
    if (index >= push_data.vertex_count) return;

    Skin_Vertex skin = push_data.skin_vertices[index];
    uint4 joints = (skin.joints >> uint4(0, 8, 16, 24)) & 0xFF;
    float4 weights = unpackUnorm4x8ToFloat(skin.weights);

    float3x4 skin_matrix = weights[0] * push_data.joint_matrices[joints[0]];
    for (uint i = 1; i < 4; i++) {
        skin_matrix += weights[i] * push_data.joint_matrices[joints[i]];
    }

    Vertex_Attributes attributes = unpack_attributes(push_data.source_attributes[index]);
    attributes.normal      = normalize(transform_normal(skin_matrix, attributes.normal));
    attributes.tangent.xyz = normalize(transform_direction(skin_matrix, attributes.tangent.xyz));

    push_data.positions[index]  = mul(skin_matrix, float4(push_data.source_positions[index], 1.0));
    push_data.attributes[index] = pack_attributes(attributes);
}
