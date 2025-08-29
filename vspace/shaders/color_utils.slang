module color_utils;

const static float PI = 3.14159265358979323846;

// see link in description for the source of those transfer function
float transfer(float v)
{
    return v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 0.4166666666666667) - 0.055;
}

float3 transfer(float3 v)
{
    return float3(transfer(v.x), transfer(v.y), transfer(v.z));
}

// slightly rearranged vector components so it matches with LCH
public float3 lch2rgb(float3 lch)
{
    lch.y *= 0.34;

    float3 lab = float3(
        lch.x,
        lch.y * cos(lch.z * PI * 2.0),
        lch.y * sin(lch.z * PI * 2.0));

    float3 lms = float3(
        lab.x + 0.3963377774f * lab.y + 0.2158037573f * lab.z,
        lab.x - 0.1055613458f * lab.y - 0.0638541728f * lab.z,
        lab.x - 0.0894841775f * lab.y - 1.2914855480f * lab.z);

    lms = pow(max(lms, float3(0.0)), float3(3.0));

    float3 rgb = float3(
        +4.0767416621f * lms.x - 3.3077115913f * lms.y + 0.2309699292f * lms.z,
        -1.2684380046f * lms.x + 2.6097574011f * lms.y - 0.3413193965f * lms.z,
        -0.0041960863f * lms.x - 0.7034186147f * lms.y + 1.7076147010f * lms.z);

    rgb = transfer(rgb);
    return rgb;
}
