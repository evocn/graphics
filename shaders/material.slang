// Graphics
// Material Shader

////////////////////////////////////////////////////////////////////////////////
// Structs

#include "generated/shared.slang"

[[vk::push_constant]] Push_Data push_data;

// RaytracingAccelerationStructure makes Slang declare SPV_KHR_ray_tracing,
// which requires the ray-tracing-pipeline device extension...
// Doing this only emits SPV_KHR_ray_query. So dumb...
RaytracingAccelerationStructure acceleration_structure_from_address(uint64_t address) {
    return spirv_asm {
        result : $$RaytracingAccelerationStructure = OpConvertUToAccelerationStructureKHR $address
    };
}

struct Coarse_Vertex {
    float3 normal;
    float2 uv;
    float3 world_position;
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
    float3 position = mul(draw.transform, float4(draw.positions[vertex_id], 1.0)).xyz;
    Vertex_Attributes attributes = draw.attributes[vertex_id];

    Vertex_Stage_Output output;
    {
        {
            output.coarse_vertex.normal = mul((float3x3)draw.transform, attributes.normal);
            output.coarse_vertex.uv = attributes.uv;
            output.coarse_vertex.world_position = position;
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

[shader("fragment")]
Fragment_Stage_Output fragment_main(Coarse_Vertex coarse_vertex : CoarseVertex, bool is_front_face : SV_IsFrontFace) : SV_Target {
    Draw_Data draw = push_data.draws[push_data.draw_index];

    Material material = push_data.materials[draw.material_index];
    float4 texture_color = material.texture.Sample(material.sampler, coarse_vertex.uv);
    if (material.base_color.a * texture_color.a < material.alpha_cutoff) discard;
    float3 color = material.base_color.rgb * texture_color.rgb;
    float3 world_position = coarse_vertex.world_position;

    float3 normal = normalize(coarse_vertex.normal);
    if (!is_front_face) normal = -normal;

    float3 to_light = -push_data.frame.light_direction;
    float n_dot_l = dot(normal, to_light);

    float shadow = 0.0;
    if (n_dot_l > 0.0) {
        RaytracingAccelerationStructure tlas = acceleration_structure_from_address(push_data.frame.tlas_address);
        RayDesc ray;
        ray.Origin      = world_position + normal * 0.01;
        ray.Direction   = to_light;
        ray.TMin        = 0.01;
        ray.TMax        = 10000.0;

        RayQuery<RAY_FLAG_ACCEPT_FIRST_HIT_AND_END_SEARCH> query;
        query.TraceRayInline(tlas, RAY_FLAG_NONE, 0xFF, ray);
        while (query.Proceed()) {
            if (query.CandidateType() != CANDIDATE_NON_OPAQUE_TRIANGLE) continue;
            if (shadow_alpha_test(query.CandidateInstanceID(), query.CandidatePrimitiveIndex(), query.CandidateTriangleBarycentrics())) {
                query.CommitNonOpaqueTriangleHit();
            }
        }
        shadow = (query.CommittedStatus() == COMMITTED_TRIANGLE_HIT) ? 0.0 : 1.0;
    }

    float sky = saturate(0.5 - 0.5 * normal.y);
    float3 ambient = lerp(float3(0.06, 0.05, 0.04), float3(0.16, 0.18, 0.22), sky);
    float3 sun = float3(1.0, 0.95, 0.85) * saturate(n_dot_l) * shadow;

    Fragment_Stage_Output output;
    {
        output.color = color * (ambient + sun);
    }
    return output;
}
