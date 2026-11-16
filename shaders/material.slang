#include "generated/shared.slang"

[[vk::push_constant]] Push_Data push_data;

RaytracingAccelerationStructure acceleration_structure_from_address(uint64_t address) {
    return spirv_asm {
        result : $$RaytracingAccelerationStructure = OpConvertUToAccelerationStructureKHR $address
    };
}

struct Coarse_Vertex {
    float3 normal;
    float4 tangent;
    float2 uv;
    float3 world_position;
    nointerpolation uint draw_index;
}

struct Vertex_Stage_Output {
    Coarse_Vertex   coarse_vertex   : CoarseVertex;
    float4          sv_position     : SV_Position;
}

float3 transform_normal(float4x4 transform, float3 normal) {
    float3 a = transform[0].xyz;
    float3 b = transform[1].xyz;
    float3 c = transform[2].xyz;
    float3 n = float3(dot(cross(b, c), normal), dot(cross(c, a), normal), dot(cross(a, b), normal));
    return dot(a, cross(b, c)) < 0.0 ? -n : n;
}

[shader("vertex")]
Vertex_Stage_Output vertex_main(uint vertex_id : SV_VertexID, uint draw_index : SV_StartInstanceLocation) {
    Draw_Data draw = push_data.draws[draw_index];
    float3 position = mul(draw.transform, float4(draw.positions[vertex_id], 1.0)).xyz;
    Vertex_Attributes attributes = draw.attributes[vertex_id];

    Vertex_Stage_Output output;
    output.coarse_vertex.normal         = transform_normal(draw.transform, attributes.normal);
    output.coarse_vertex.tangent        = float4(mul((float3x3)draw.transform, attributes.tangent.xyz), attributes.tangent.w);
    output.coarse_vertex.uv             = attributes.uv;
    output.coarse_vertex.world_position = position;
    output.coarse_vertex.draw_index     = draw_index;
    output.sv_position                  = mul(push_data.frame.view_projection, float4(position, 1.0));
    return output;
}

bool shadow_alpha_test(uint draw_index, uint primitive_index, float2 barycentrics) {
    Draw_Data draw = push_data.draws[draw_index];

    float2 uv0 = draw.attributes[draw.indices[primitive_index * 3 + 0]].uv;
    float2 uv1 = draw.attributes[draw.indices[primitive_index * 3 + 1]].uv;
    float2 uv2 = draw.attributes[draw.indices[primitive_index * 3 + 2]].uv;
    float2 uv = uv0 * (1.0 - barycentrics.x - barycentrics.y) + uv1 * barycentrics.x + uv2 * barycentrics.y;

    for (;;) {
        uint material_index = WaveReadLaneFirst(draw.material_index);
        if (material_index == draw.material_index) {
            Material material = push_data.materials[material_index];
            float alpha = material.base_color.a * material.texture.SampleLevel(material.sampler, uv, 0).a;
            return alpha >= material.alpha_cutoff;
        }
    }
}

static const float PI = 3.14159265;

float distribution_ggx(float n_dot_h, float alpha) {
    float alpha2 = alpha * alpha;
    float d = n_dot_h * n_dot_h * (alpha2 - 1.0) + 1.0;
    return alpha2 / (PI * d * d);
}

float visibility_smith_ggx_correlated(float n_dot_v, float n_dot_l, float alpha) {
    float alpha2 = alpha * alpha;
    float v = n_dot_l * sqrt(n_dot_v * n_dot_v * (1.0 - alpha2) + alpha2);
    float l = n_dot_v * sqrt(n_dot_l * n_dot_l * (1.0 - alpha2) + alpha2);
    return 0.5 / max(v + l, 1e-5);
}

float3 fresnel_schlick(float3 f0, float v_dot_h) {
    return f0 + (1.0 - f0) * pow(1.0 - v_dot_h, 5.0);
}

bool unoccluded(float3 world_position, float3 geometric_normal, float3 direction, float max_distance) {
    RaytracingAccelerationStructure tlas = acceleration_structure_from_address(push_data.frame.tlas_address);
    RayDesc ray;
    ray.Origin      = world_position + geometric_normal * 0.01;
    ray.Direction   = direction;
    ray.TMin        = 0.01;
    ray.TMax        = max_distance;

    RayQuery<RAY_FLAG_ACCEPT_FIRST_HIT_AND_END_SEARCH> query;
    query.TraceRayInline(tlas, RAY_FLAG_NONE, 0xFF, ray);
    while (query.Proceed()) {
        if (query.CandidateType() != CANDIDATE_NON_OPAQUE_TRIANGLE) continue;
        if (shadow_alpha_test(query.CandidateInstanceID(), query.CandidatePrimitiveIndex(), query.CandidateTriangleBarycentrics())) {
            query.CommitNonOpaqueTriangleHit();
        }
    }
    return query.CommittedStatus() != COMMITTED_TRIANGLE_HIT;
}

[shader("fragment")]
void depth_fragment_main(Coarse_Vertex coarse_vertex : CoarseVertex) {
    Draw_Data draw = push_data.draws[coarse_vertex.draw_index];
    Material material = push_data.materials[draw.material_index];
    if (material.alpha_cutoff == 0.0) return;
    float alpha = material.base_color.a * material.texture.Sample(material.sampler, coarse_vertex.uv).a;
    if (alpha < material.alpha_cutoff) discard;
}

[earlydepthstencil]
[shader("fragment")]
float4 fragment_main(Coarse_Vertex coarse_vertex : CoarseVertex, bool is_front_face : SV_IsFrontFace) : SV_Target {
    Draw_Data draw = push_data.draws[coarse_vertex.draw_index];

    Material material = push_data.materials[draw.material_index];
    float2 uv = coarse_vertex.uv;
    float4 texture_color = material.texture.Sample(material.sampler, uv);
    float3 base_color = material.base_color.rgb * texture_color.rgb;
    float3 world_position = coarse_vertex.world_position;

    float3 geometric_normal = normalize(coarse_vertex.normal);
    float3 tangent = normalize(coarse_vertex.tangent.xyz - geometric_normal * dot(geometric_normal, coarse_vertex.tangent.xyz));
    float3 bitangent = cross(geometric_normal, tangent) * coarse_vertex.tangent.w;
    if (!is_front_face) {
        geometric_normal = -geometric_normal;
        tangent = -tangent;
        bitangent = -bitangent;
    }

    float3 normal_sample = material.normal_texture.Sample(material.sampler, uv).xyz * 2.0 - 1.0;
    normal_sample.xy *= material.normal_scale;
    float3 normal = normalize(tangent * normal_sample.x + bitangent * normal_sample.y + geometric_normal * normal_sample.z);

    float4 metallic_roughness = material.metallic_roughness_texture.Sample(material.sampler, uv);
    float metallic = saturate(material.metallic * metallic_roughness.b);
    float roughness = clamp(material.roughness * metallic_roughness.g, 0.045, 1.0);
    float alpha = roughness * roughness;

    float3 to_light = -push_data.frame.light_direction;
    float3 to_camera = normalize(push_data.frame.camera_position - world_position);

    float3 diffuse_color = base_color * (1.0 - metallic);
    float3 f0 = lerp(float3(0.04), base_color, metallic);

    float3 sun = float3(0.0);
    float n_dot_l = dot(normal, to_light);
    if (n_dot_l > 0.0 && dot(geometric_normal, to_light) > 0.0 && unoccluded(world_position, geometric_normal, to_light, 10000.0)) {
        float3 half_vector = normalize(to_light + to_camera);
        float n_dot_v = max(dot(normal, to_camera), 1e-4);
        float n_dot_h = saturate(dot(normal, half_vector));
        float v_dot_h = saturate(dot(to_camera, half_vector));

        float3 fresnel = fresnel_schlick(f0, v_dot_h);
        float3 specular = fresnel * distribution_ggx(n_dot_h, alpha) * visibility_smith_ggx_correlated(n_dot_v, n_dot_l, alpha);
        float3 diffuse = (1.0 - fresnel) * diffuse_color / PI;

        float3 sun_irradiance = float3(1.0, 0.95, 0.85) * push_data.frame.sun_intensity * PI;
        sun = (diffuse + specular) * sun_irradiance * n_dot_l;
    }

    float sky = saturate(0.5 - 0.5 * normal.y);
    float3 ambient = lerp(float3(0.12, 0.1, 0.08), float3(0.3, 0.34, 0.42), sky);
    float3 ambient_light = ambient * (diffuse_color + f0);

    switch (push_data.frame.debug_view) {
        case 1:  return float4(base_color, 1.0);
        case 2:  return float4(normal * 0.5 + 0.5, 1.0);
        case 3:  return float4(metallic, roughness, 0.0, 1.0);
        case 4:  return float4(sun, 1.0);
        case 5:  return float4(ambient_light, 1.0);
        default: return float4(ambient_light + sun, 1.0);
    }
}
