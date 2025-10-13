// simple.fx - 簡素化版
// MRT3: RT0=color, RT1=Z画像, RT2=WorldPos

float4x4 g_matWorldViewProj;
float4x4 g_matWorld;
float4x4 g_matView;
float4x4 g_matProj;

float g_fNear = 1.0f;
float g_fFar = 1000.0f;
float g_vizMax = 100.0f;
float g_vizGamma = 0.25f;

float g_posRange = 50.0f;

bool g_bUseTexture = false;

void VertexShader1(
    in float4 inPosition : POSITION,
    in float4 inNormal : NORMAL0,
    in float4 inTexCood : TEXCOORD0,

    out float4 outPosition : POSITION,
    out float4 outDiffuse : COLOR0,
    out float4 outTexCood : TEXCOORD0,
    out float outViewZ : TEXCOORD1,
    out float3 outWorldPos : TEXCOORD2
)
{
    float4 worldPos = mul(inPosition, g_matWorld);
    outPosition = mul(mul(worldPos, g_matView), g_matProj);

    // 簡単なライティング
//    float lightIntensity = dot(inNormal, float4(-0.3, 1.0, -0.5, 0));
    float lightIntensity = 1.0f;
    outDiffuse.rgb = max(0, lightIntensity) + 0.3;
    outDiffuse.a = 1.0f;

    outTexCood = inTexCood;
    
    float4 vpos = mul(worldPos, g_matView);
    outViewZ = vpos.z;
    outWorldPos = worldPos.xyz;
}

texture g_tex0;
sampler sampTex0 = sampler_state
{
    Texture = (g_tex0);
    MinFilter = POINT;
    MagFilter = POINT;
    MipFilter = POINT;
    AddressU = WRAP;
    AddressV = WRAP;
};

void PixelShaderMRT3(
    in float4 inScreenColor : COLOR0,
    in float2 inTexCood : TEXCOORD0,
    in float inViewZ : TEXCOORD1,
    in float3 inWorldPos : TEXCOORD2,
    out float4 outColor0 : COLOR0, // Color
    out float4 outColor1 : COLOR1, // Z画像
    out float4 outColor2 : COLOR2 // POS画像
)
{
    // 1) 色（テクスチャがあれば乗算、なければ頂点ライトだけ）
    float3 lit = inScreenColor.rgb; // VSの簡易ライト
    float3 base = lit;
    if (g_bUseTexture)                              // ← エフェクトから切り替え
    {
        float3 tex = tex2D(sampTex0, inTexCood).rgb;
        base = tex * lit; // テクスチャ × ライト
    }
    outColor0 = float4(base, 1.0f);


    // RT1: Z画像（RGB=可視化, A=線形Z）
    float linearZ = saturate((inViewZ - g_fNear) / (g_fFar - g_fNear));
    float viz = saturate((inViewZ - g_fNear) / (g_vizMax - g_fNear));
    viz = pow(viz, g_vizGamma);
    outColor1 = float4(viz, viz, viz, linearZ);

    // RT2: World座標を0..1にエンコード
    float3 nrm = inWorldPos / g_posRange;
    float3 enc = saturate(nrm * 0.5 + 0.5);
    outColor2 = float4(enc, 1.0f);
}

technique TechniqueMRT
{
    pass P0
    {
        CullMode = NONE;
        VertexShader = compile vs_3_0 VertexShader1();
        PixelShader = compile ps_3_0 PixelShaderMRT3();
    }
}