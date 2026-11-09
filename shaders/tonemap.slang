#include "generated/shared.slang"

[[vk::push_constant]] Tonemap_Push_Data push_data;

[shader("vertex")]
float4 vertex_main(uint vertex_id : SV_VertexID) : SV_Position {
    float2 uv = float2((vertex_id << 1) & 2, vertex_id & 2);
    return float4(uv * 2.0 - 1.0, 0.0, 1.0);
}

float3 aces_fitted(float3 x) {
    return saturate((x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14));
}

[shader("fragment")]
float4 fragment_main(float4 position : SV_Position) : SV_Target {
    float3 hdr = push_data.hdr.Load(int3(int2(position.xy), 0)).rgb;
    if (push_data.raw != 0) return float4(saturate(hdr), 1.0);
    return float4(aces_fitted(hdr * push_data.exposure), 1.0);
}
