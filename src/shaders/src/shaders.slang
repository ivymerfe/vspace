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
    float3 blockRelative : BLOCK_RELATIVE;
};

struct SceneConstants
{
    float4x4 mvp;
}

[[vk::push_constant]]
SceneConstants scene;

float3 hsv2rgb(float3 c) {
    float4 K = float4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
    float3 p = abs(fract(c.xxx + K.xyz) * 6.0 - K.www);
    return c.z * lerp(K.xxx, clamp(p - K.xxx, 0.0, 1.0), c.y);
}

static const float3 BLOCK_VERTICES[36] = {
    // Front face (clockwise)
    float3(-0.5, -0.5,  0.5), float3( 0.5, -0.5,  0.5), float3( 0.5,  0.5,  0.5),
    float3( 0.5,  0.5,  0.5), float3(-0.5,  0.5,  0.5), float3(-0.5, -0.5,  0.5),
    
    // Back face (counter-clockwise when viewed from front)
    float3( 0.5, -0.5, -0.5), float3(-0.5, -0.5, -0.5), float3(-0.5,  0.5, -0.5),
    float3(-0.5,  0.5, -0.5), float3( 0.5,  0.5, -0.5), float3( 0.5, -0.5, -0.5),
    
    // Left face (counter-clockwise when viewed from front)
    float3(-0.5, -0.5, -0.5), float3(-0.5, -0.5,  0.5), float3(-0.5,  0.5,  0.5),
    float3(-0.5,  0.5,  0.5), float3(-0.5,  0.5, -0.5), float3(-0.5, -0.5, -0.5),
    
    // Right face (clockwise when viewed from front)
    float3( 0.5, -0.5,  0.5), float3( 0.5, -0.5, -0.5), float3( 0.5,  0.5, -0.5),
    float3( 0.5,  0.5, -0.5), float3( 0.5,  0.5,  0.5), float3( 0.5, -0.5,  0.5),
    
    // Top face (clockwise when viewed from above)
    float3(-0.5,  0.5,  0.5), float3( 0.5,  0.5,  0.5), float3( 0.5,  0.5, -0.5),
    float3( 0.5,  0.5, -0.5), float3(-0.5,  0.5, -0.5), float3(-0.5,  0.5,  0.5),
    
    // Bottom face (counter-clockwise when viewed from above)
    float3(-0.5, -0.5, -0.5), float3( 0.5, -0.5, -0.5), float3( 0.5, -0.5,  0.5),
    float3( 0.5, -0.5,  0.5), float3(-0.5, -0.5,  0.5), float3(-0.5, -0.5, -0.5)
};

[shader("vertex")]
VertexOutput vsMain(VertexInput input)
{
    VertexOutput output;
    input.pos.y *= -1;
    float3 blockRelative = BLOCK_VERTICES[input.vertexIndex];
    float3 pos = blockRelative + input.pos;
    output.position = mul(scene.mvp, float4(pos, 1.0));
    output.fragColor = input.color;
    output.blockRelative = blockRelative;
    return output;
}

struct FragmentInput
{
    float4 position : SV_Position;
    float3 fragColor : TEXCOORD0; // Location 0 interpolated input
    float3 blockRelative : BLOCK_RELATIVE;
};

struct FragmentOutput
{
    float4 outColor : SV_Target0; // Location 0 color output
};

[shader("pixel")]
FragmentOutput psMain(FragmentInput input)
{
    FragmentOutput output;
    float dist = 1 - length(input.blockRelative);
    output.outColor = float4(hsv2rgb(input.fragColor), 1) * dist;
    return output;
}
