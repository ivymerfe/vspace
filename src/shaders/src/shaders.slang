struct VertexInput
{
    float3 pos;
    float3 color;
    uint vertexIndex : SV_VertexID;
}

struct VertexOutput
{
    float4 position : SV_Position;
    float3 fragColor : TEXCOORD0; // Will match fragment input
};

struct SceneConstants
{
    float time;
}

[[vk::push_constant]]
SceneConstants scene;

float3 hsv2rgb(float3 c) {
    float4 K = float4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
    float3 p = abs(fract(c.xxx + K.xyz) * 6.0 - K.www);
    return c.z * lerp(K.xxx, clamp(p - K.xxx, 0.0, 1.0), c.y);
}

[shader("vertex")]
VertexOutput vsMain(VertexInput input)
{
    VertexOutput output;
    output.position = float4(input.pos, 1.0);
    output.fragColor = input.color*hsv2rgb(float3(cos(scene.time)*cos(scene.time), 0.9, 0.9)), 0.8;
    return output;
}

struct FragmentInput
{
    float4 position : SV_Position;
    float3 fragColor : TEXCOORD0; // Location 0 interpolated input
};

struct FragmentOutput
{
    float4 outColor : SV_Target0; // Location 0 color output
};

[shader("pixel")]
FragmentOutput psMain(FragmentInput input)
{
    FragmentOutput output;
    output.outColor = float4(input.fragColor, 1);
    return output;
}
