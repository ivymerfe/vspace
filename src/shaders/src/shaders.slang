struct VertexInput
{
    float3 pos;
    float3 color;
    uint vertexIndex : SV_VertexID;
}

struct VertexOutput
{
    float4 position : SV_Position;
    float3 fragColor : TEXCOORD0;
    float3 blockRelative : BLOCK_RELATIVE;
    float3 faceNormal : FACE_NORMAL;
};

struct SceneConstants
{
    float4x4 mvp;
}

[[vk::push_constant]]
SceneConstants scene;

float3 hsv2rgb(float3 c)
{
    float4 K = float4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
    float3 p = abs(fract(c.xxx + K.xyz) * 6.0 - K.www);
    return c.z * lerp(K.xxx, clamp(p - K.xxx, 0.0, 1.0), c.y);
}

static const float3 BLOCK_VERTICES[36] = {
    // Front face (clockwise)
    float3(-0.5, -0.5, 0.5), float3(0.5, -0.5, 0.5), float3(0.5, 0.5, 0.5),
    float3(0.5, 0.5, 0.5), float3(-0.5, 0.5, 0.5), float3(-0.5, -0.5, 0.5),

    // Back face (counter-clockwise when viewed from front)
    float3(0.5, -0.5, -0.5), float3(-0.5, -0.5, -0.5), float3(-0.5, 0.5, -0.5),
    float3(-0.5, 0.5, -0.5), float3(0.5, 0.5, -0.5), float3(0.5, -0.5, -0.5),

    // Left face (counter-clockwise when viewed from front)
    float3(-0.5, -0.5, -0.5), float3(-0.5, -0.5, 0.5), float3(-0.5, 0.5, 0.5),
    float3(-0.5, 0.5, 0.5), float3(-0.5, 0.5, -0.5), float3(-0.5, -0.5, -0.5),

    // Right face (clockwise when viewed from front)
    float3(0.5, -0.5, 0.5), float3(0.5, -0.5, -0.5), float3(0.5, 0.5, -0.5),
    float3(0.5, 0.5, -0.5), float3(0.5, 0.5, 0.5), float3(0.5, -0.5, 0.5),

    // Top face (clockwise when viewed from above)
    float3(-0.5, 0.5, 0.5), float3(0.5, 0.5, 0.5), float3(0.5, 0.5, -0.5),
    float3(0.5, 0.5, -0.5), float3(-0.5, 0.5, -0.5), float3(-0.5, 0.5, 0.5),

    // Bottom face (counter-clockwise when viewed from above)
    float3(-0.5, -0.5, -0.5), float3(0.5, -0.5, -0.5), float3(0.5, -0.5, 0.5),
    float3(0.5, -0.5, 0.5), float3(-0.5, -0.5, 0.5), float3(-0.5, -0.5, -0.5)
};

static const float3 FACE_NORMALS[6] = {
    float3(0.0, 0.0, 1.0),  // Front face
    float3(0.0, 0.0, -1.0), // Back face
    float3(-1.0, 0.0, 0.0), // Left face
    float3(1.0, 0.0, 0.0),  // Right face
    float3(0.0, 1.0, 0.0),  // Top face
    float3(0.0, -1.0, 0.0)  // Bottom face
};

[shader("vertex")]
VertexOutput vsMain(VertexInput input)
{
    VertexOutput output;
    input.pos.y *= -1;
    float3 blockRelative = BLOCK_VERTICES[input.vertexIndex];
    float3 pos = blockRelative + input.pos;
    output.position = mul(scene.mvp, float4(pos, 1.0));
    output.fragColor = hsv2rgb(input.color);
    output.blockRelative = blockRelative;
    output.faceNormal = FACE_NORMALS[input.vertexIndex / 6];
    return output;
}

struct FragmentOutput
{
    float4 outColor : SV_Target0; // Location 0 color output
};

[shader("pixel")]
FragmentOutput psMain(VertexOutput input)
{
    FragmentOutput output;
    float3 d = abs(input.blockRelative*1.4);
    float k = 4;
    float len = pow(pow(d[0], k) + pow(d[1], k) + pow(d[2], k), 1 / k);
    float dist = 1.2 - len;
    output.outColor = float4(input.fragColor, 1) * saturate(dist);
    return output;
}
