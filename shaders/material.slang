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
    Vertex vertex = draw.vertices[vertex_id];

    float3 position = vertex.position;

    Vertex_Stage_Output output;
    {
        {
            output.coarse_vertex.uv = vertex.uv;
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

    float2 uv0 = draw.vertices[primitive_index * 3 + 0].uv;
    float2 uv1 = draw.vertices[primitive_index * 3 + 1].uv;
    float2 uv2 = draw.vertices[primitive_index * 3 + 2].uv;
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
Fragment_Stage_Output fragment_main(Coarse_Vertex coarse_vertex : CoarseVertex) : SV_Target {
    Draw_Data draw = push_data.draws[push_data.draw_index];

    Material material = push_data.materials[draw.material_index];
    float4 texture_color = material.texture.Sample(material.sampler, coarse_vertex.uv);
    if (material.base_color.a * texture_color.a < material.alpha_cutoff) discard;
    float3 color = material.base_color.rgb * texture_color.rgb;
    float3 world_position = coarse_vertex.world_position;

    // Shadows
    float shadow;
    {
        RaytracingAccelerationStructure tlas = acceleration_structure_from_address(push_data.frame.tlas_address);
        RayDesc ray;
        ray.Origin      = world_position;
        ray.Direction   = -push_data.frame.light_direction;
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
        shadow = (query.CommittedStatus() == COMMITTED_TRIANGLE_HIT) ? 0.2 : 1.0;
    }

    Fragment_Stage_Output output;
    {
        output.color = color * shadow;
    }
    return output;
}
