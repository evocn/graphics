#include "generated/shared.slang"

struct Vertex_Attributes {
    float3 normal;
    float4 tangent;
    float2 uv;
}

float2 sign_not_zero(float2 v) {
    return select(v >= 0.0, float2(1.0), float2(-1.0));
}

float2 octahedral_encode(float3 n) {
    float2 p = n.xy / (abs(n.x) + abs(n.y) + abs(n.z));
    return n.z < 0.0 ? (1.0 - abs(p.yx)) * sign_not_zero(p) : p;
}

float3 octahedral_decode(float2 p) {
    float3 n = float3(p, 1.0 - abs(p.x) - abs(p.y));
    float fold = saturate(-n.z);
    n.xy -= fold * sign_not_zero(n.xy);
    return normalize(n);
}

uint pack_snorm16x2(float2 v) {
    int2 quantized = int2(round(clamp(v, -1.0, 1.0) * 32767.0));
    return (uint(quantized.x) & 0xFFFF) | (uint(quantized.y) << 16);
}

float2 unpack_snorm16x2(uint bits) {
    int2 quantized = int2(int(bits << 16) >> 16, int(bits) >> 16);
    return max(float2(quantized) / 32767.0, -1.0);
}

Vertex_Attributes unpack_attributes(Packed_Vertex_Attributes packed) {
    Vertex_Attributes attributes;
    attributes.normal  = octahedral_decode(unpack_snorm16x2(packed.normal));
    attributes.tangent = float4(octahedral_decode(unpack_snorm16x2(packed.tangent)), (packed.tangent & 1) != 0 ? -1.0 : 1.0);
    attributes.uv      = packed.uv;
    return attributes;
}

Packed_Vertex_Attributes pack_attributes(Vertex_Attributes attributes) {
    Packed_Vertex_Attributes packed;
    packed.normal  = pack_snorm16x2(octahedral_encode(attributes.normal));
    packed.tangent = (pack_snorm16x2(octahedral_encode(attributes.tangent.xyz)) & ~1u) | (attributes.tangent.w < 0.0 ? 1u : 0u);
    packed.uv      = attributes.uv;
    return packed;
}

float3 transform_direction(float3x4 transform, float3 direction) {
    return mul((float3x3)transform, direction);
}

float3 transform_normal(float3x4 transform, float3 normal) {
    float3 a = transform[0].xyz;
    float3 b = transform[1].xyz;
    float3 c = transform[2].xyz;
    float3 n = float3(dot(cross(b, c), normal), dot(cross(c, a), normal), dot(cross(a, b), normal));
    return dot(a, cross(b, c)) < 0.0 ? -n : n;
}
