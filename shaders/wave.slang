#include "geometry.slang"

[[vk::push_constant]] Deform_Push_Data push_data;

static const float AMPLITUDE   = 0.15;
static const float WAVE_NUMBER = 4.0;
static const float SPEED       = 3.0;
static const float BOTTOM      = 1.0;
static const float HEIGHT      = 1.5;

[shader("compute")]
[numthreads(64, 1, 1)]
void wave_main(uint3 thread_id : SV_DispatchThreadID) {
    uint index = thread_id.x;
    if (index >= push_data.vertex_count) return;

    float3 position = push_data.source_positions[index];
    Vertex_Attributes attributes = unpack_attributes(push_data.source_attributes[index]);

    float unclamped_sway = (BOTTOM - position.y) / HEIGHT;
    float sway = saturate(unclamped_sway);
    float sway_dy = unclamped_sway < 1.0 ? -1.0 / HEIGHT : 0.0;
    float amplitude = AMPLITUDE * sway * sway;
    float amplitude_dy = 2.0 * AMPLITUDE * sway * sway_dy;
    float phase = WAVE_NUMBER * position.x - SPEED * push_data.time;

    float offset    = amplitude * sin(phase);
    float offset_dx = amplitude * WAVE_NUMBER * cos(phase);
    float offset_dy = amplitude_dy * sin(phase);

    position.z += offset;
    attributes.normal      = normalize(float3(offset_dx, offset_dy, -1.0));
    attributes.tangent.xyz = normalize(float3(1.0, 0.0, offset_dx));

    push_data.positions[index]  = position;
    push_data.attributes[index] = pack_attributes(attributes);
}
