// simple2.fx — SSAO (edge-safe: use FAR side at silhouettes)
// Shader Model 3.0

// ========= Globals =========
float4x4 g_matView;
float4x4 g_matProj;

float g_fNear = 1.0f;
float g_fFar = 1000.0f;

float2 g_invSize; // 1 / RT size (pixels)
float g_posRange = 50.0f; // WorldPos encode range (simple.fx)

// AO controls
float g_aoStrength = 1.0f; // 0..2
float g_aoStepWorld = 0.75f; // base radius in world units
float g_aoBias = 0.0002f; // small bias in linear-Z

// Edge handling
float g_edgeZ = 0.006f; // linear-Z guard near edges
float g_originPush = 0.05f; // small lift along +Nv (× g_aoStepWorld)

// ========= Textures / Samplers =========
texture texZ; // RT1: A = linear Z
texture texPos; // RT2: WorldPos encoded 0..1 with g_posRange
texture texAO; // AO buffer (for composite)
texture texColor; // Color buffer (for composite)

sampler sampZ = sampler_state
{
    Texture = (texZ);
    MinFilter = POINT;
    MagFilter = POINT;
    MipFilter = NONE;
    AddressU = CLAMP;
    AddressV = CLAMP;
};
sampler sampPos = sampler_state
{
    Texture = (texPos);
    MinFilter = POINT;
    MagFilter = POINT;
    MipFilter = NONE;
    AddressU = CLAMP;
    AddressV = CLAMP;
};
sampler sampAO = sampler_state
{
    Texture = (texAO);
    MinFilter = POINT;
    MagFilter = POINT;
    MipFilter = NONE;
    AddressU = CLAMP;
    AddressV = CLAMP;
};
sampler sampColor = sampler_state
{
    Texture = (texColor);
    MinFilter = POINT;
    MagFilter = POINT;
    MipFilter = NONE;
    AddressU = CLAMP;
    AddressV = CLAMP;
};

// ========= Helpers =========
float3 DecodeWorldPos(float3 enc)
{
    return (enc * 2.0f - 1.0f) * g_posRange;
}

// D3D9 half-texel aware
float2 NdcToUv(float4 clip)
{
    float2 ndc = clip.xy / clip.w;
    float2 uv;
    uv.x = ndc.x * 0.5f + 0.5f;
    uv.y = -ndc.y * 0.5f + 0.5f;
    return uv + 0.5f * g_invSize;
}

// Low-discrepancy hemisphere dir
float3 HemiDirFromIndex(int i)
{
    float a = frac(0.754877666f * (i + 0.5f));
    float b = frac(0.569840296f * (i + 0.5f));
    float phi = a * 6.2831853f;
    float c = b; // cos(theta) in [0,1]
    float s = sqrt(saturate(1.0f - c * c));
    return float3(cos(phi) * s, sin(phi) * s, c);
}

struct VS_OUT
{
    float4 pos : POSITION;
    float2 uv : TEXCOORD0;
};
VS_OUT VS_Fullscreen(float4 p : POSITION, float2 uv : TEXCOORD0)
{
    VS_OUT o;
    o.pos = p;
    o.uv = uv;
    return o;
}

// ========= Basis (normal + origin + reference Z) =========
struct Basis
{
    float3 Nv;
    float3 vOrigin;
    float zRef;
};
float g_farAdoptMinZ = 0.0001f; // これ以上なら輪郭とみなす（小さすぎは通常面）
float g_farAdoptMaxZ = 0.01f; // これ以上は大きすぎ（別オブジェクト/空）→遠側採用しない

Basis BuildBasis(float2 uv)
{
    Basis o;

    float zC = tex2D(sampZ, uv).a;
    float3 pC = DecodeWorldPos(tex2D(sampPos, uv).rgb);

    float2 dx = float2(g_invSize.x, 0.0f) * 2;
    float2 dy = float2(0.0f, g_invSize.y) * 2;

    float3 pR = DecodeWorldPos(tex2D(sampPos, uv + dx).rgb);
    float3 pL = DecodeWorldPos(tex2D(sampPos, uv - dx).rgb);
    float3 pU = DecodeWorldPos(tex2D(sampPos, uv - dy).rgb);
    float3 pD = DecodeWorldPos(tex2D(sampPos, uv + dy).rgb);

    float zR = tex2D(sampZ, uv + dx).a;
    float zL = tex2D(sampZ, uv - dx).a;
    float zU = tex2D(sampZ, uv - dy).a;
    float zD = tex2D(sampZ, uv + dy).a;

    // --- “輪郭かつ遠側を採るか” をレンジで判定 ---
    float dzX = abs(zR - zL);
    float dzY = abs(zD - zU);
    bool adoptFarX = (dzX >= g_farAdoptMinZ) && (dzX <= g_farAdoptMaxZ);
    bool adoptFarY = (dzY >= g_farAdoptMinZ) && (dzY <= g_farAdoptMaxZ);

    // 法線用の差分：軸ごとにレンジ内なら FAR 側、そうでなければセンターに近い側
    float3 vx = adoptFarX
              ? ((zR > zL) ? (pR - pC) : (pC - pL))
              : ((abs(zR - zC) <= abs(zL - zC)) ? (pR - pC) : (pC - pL));
    float3 vy = adoptFarY
              ? ((zD > zU) ? (pD - pC) : (pC - pU))
              : ((abs(zD - zC) <= abs(zU - zC)) ? (pD - pC) : (pC - pU));

    float3 Nw = normalize(cross(vx, vy));
    float3 Nv = normalize(mul(float4(Nw, 0), g_matView).xyz);

    // 原点（位置）：どちらかの軸で採用する場合は、その軸の “より遠い方” を使う
    float zFarN = zC;
    float3 pFarN = pC;
    if (adoptFarX)
    {
        float zX = max(zR, zL);
        float3 pX = (zR > zL) ? pR : pL;
        if (zX > zFarN)
        {
            zFarN = zX;
            pFarN = pX;
        }
    }
    if (adoptFarY)
    {
        float zY = max(zD, zU);
        float3 pY = (zD > zU) ? pD : pU;
        if (zY > zFarN)
        {
            zFarN = zY;
            pFarN = pY;
        }
    }

    // 参照Z（zRef）は従来どおり“遠い側”を使って明るいハロを防止（ここはレンジ外でもOK）
    const float kEdge = 0.004f; // 以前の kEdge（シルエット検出） – 必要なら 0.003〜0.006
    float zRef = zC;
    float3 pRef = pC;
    if (abs(zR - zL) > kEdge)
    {
        if (zR > zRef)
        {
            zRef = zR;
            pRef = pR;
        }
        if (zL > zRef)
        {
            zRef = zL;
            pRef = pL;
        }
    }
    if (abs(zD - zU) > kEdge)
    {
        if (zD > zRef)
        {
            zRef = zD;
            pRef = pD;
        }
        if (zU > zRef)
        {
            zRef = zU;
            pRef = pU;
        }
    }

    // 出力（原点はレンジガード付きの選択、それ以外は従来どおり）
    o.Nv = Nv;
    o.vOrigin = mul(float4(pFarN, 1.0f), g_matView).xyz; // 採用しない場合は pC になる
    o.zRef = zRef;
    return o;
}


// ========= AO =========
float4 PS_AO(VS_OUT i) : COLOR0
{
    Basis b = BuildBasis(i.uv);

    float3 Nv = b.Nv;
    float3 vOrigin = b.vOrigin + Nv * (g_originPush * g_aoStepWorld); // small lift along +Nv
    float zRef = b.zRef;

    // TBN
    float3 up = (abs(Nv.z) < 0.999f) ? float3(0, 0, 1) : float3(0, 1, 0);
    float3 T = normalize(cross(up, Nv));
    float3 B = cross(Nv, T);

    int occ = 0;
    const int kSamples = 128;

    [unroll]
    for (int k = 0; k < kSamples; ++k)
    {
        float3 h = HemiDirFromIndex(k);
        float3 dirV = normalize(T * h.x + B * h.y + Nv * h.z);

        float u = ((float) k + 0.5f) / (float) kSamples;
        float radius = g_aoStepWorld * (u * u);

        float3 vSample = vOrigin + dirV * radius;

        float4 clip = mul(float4(vSample, 1.0f), g_matProj);
        if (clip.w <= 0.0f)
            continue;

        float2 suv = NdcToUv(clip);
        if (suv.x < 0.0f || suv.x > 1.0f || suv.y < 0.0f || suv.y > 1.0f)
            continue;

        // Edge guard: sample is valid if it's near the FAR side OR the center depth
        float zImg = tex2D(sampZ, suv).a;
        float zCtr = tex2D(sampZ, i.uv).a;
        if (abs(zImg - zRef) > g_edgeZ && abs(zImg - zCtr) > g_edgeZ)
            continue;

        // Depth test in linear-Z (no plane-based rejection here)
        float zNei = saturate((vSample.z - g_fNear) / (g_fFar - g_fNear));
        if (zImg + g_aoBias < zNei)
        {
            occ++;
        }
    }

    float occl = (float) occ / (float) kSamples;
    float ao = 1.0f - g_aoStrength * occl;
    if (ao < 0.2f)
    {
        ao = 0.2f;
    }
    return float4(saturate(ao).xxx, 1.0f);
}

// ========= Composite =========
float4 PS_Composite(VS_OUT i) : COLOR0
{
    float3 col = tex2D(sampColor, i.uv).rgb;
    float ao = tex2D(sampAO, i.uv).r;
    return float4(col * ao, 1.0f);
}

technique TechniqueAO_Create
{
    pass P0
    {
        CullMode = NONE;
        VertexShader = compile vs_3_0 VS_Fullscreen();
        PixelShader = compile ps_3_0 PS_AO();
    }
}

technique TechniqueAO_Composite
{
    pass P0
    {
        CullMode = NONE;
        VertexShader = compile vs_3_0 VS_Fullscreen();
        PixelShader = compile ps_3_0 PS_Composite();
    }
}

// === Bilateral-like separable blur (depth-guided) ===
float g_sigmaPx = 3.0f; // 推奨: 2.0〜3.5
float g_depthReject = 0.0001f;

float GaussianW(int k, float sigma)
{
    float fk = (float) k;
    float denom = 2.0f * sigma * sigma;
    return exp(-(fk * fk) / denom);
}

float4 PS_BlurH(VS_OUT i) : COLOR0
{
    const int R = 50; // 13 taps (±6 + center): SM3.0で安全
    float centerZ = tex2D(sampZ, i.uv).a;
    float centerAO = tex2D(sampAO, i.uv).r;

    float2 stepUV = float2(g_invSize.x, 0.0f);

    float sumAO = centerAO;
    float sumW = 1.0f;

    [unroll]
    for (int k = 1; k <= R; ++k)
    {
        float w = GaussianW(k, g_sigmaPx);

        float2 uvL = i.uv - stepUV * k;
        float2 uvR = i.uv + stepUV * k;

        float zL = tex2D(sampZ, uvL).a;
        float zR = tex2D(sampZ, uvR).a;

        if (abs(zL - centerZ) <= g_depthReject)
        {
            float aoL = tex2D(sampAO, uvL).r;
            sumAO += aoL * w;
            sumW += w;
        }
        if (abs(zR - centerZ) <= g_depthReject)
        {
            float aoR = tex2D(sampAO, uvR).r;
            sumAO += aoR * w;
            sumW += w;
        }
    }

    float ao = sumAO / max(sumW, 1e-6);
    return float4(ao, ao, ao, 1.0f);
}

float4 PS_BlurV(VS_OUT i) : COLOR0
{
    const int R = 50; // 13 taps
    float centerZ = tex2D(sampZ, i.uv).a;
    float centerAO = tex2D(sampAO, i.uv).r;

    float2 stepUV = float2(0.0f, g_invSize.y);

    float sumAO = centerAO;
    float sumW = 1.0f;

    [unroll]
    for (int k = 1; k <= R; ++k)
    {
        float w = GaussianW(k, g_sigmaPx);

        float2 uvD = i.uv + stepUV * k;
        float2 uvU = i.uv - stepUV * k;

        float zD = tex2D(sampZ, uvD).a;
        float zU = tex2D(sampZ, uvU).a;

        if (abs(zD - centerZ) <= g_depthReject)
        {
            float aoD = tex2D(sampAO, uvD).r;
            sumAO += aoD * w;
            sumW += w;
        }
        if (abs(zU - centerZ) <= g_depthReject)
        {
            float aoU = tex2D(sampAO, uvU).r;
            sumAO += aoU * w;
            sumW += w;
        }
    }

    float ao = sumAO / max(sumW, 1e-6);
    return float4(ao, ao, ao, 1.0f);
}

technique TechniqueAO_BlurH
{
    pass P0
    {
        CullMode = NONE;
        VertexShader = compile vs_3_0 VS_Fullscreen();
        PixelShader = compile ps_3_0 PS_BlurH();
    }
}
technique TechniqueAO_BlurV
{
    pass P0
    {
        CullMode = NONE;
        VertexShader = compile vs_3_0 VS_Fullscreen();
        PixelShader = compile ps_3_0 PS_BlurV();
    }
}
// ======== SSGI params ========
float g_ssgiStrength = 0.5f; // 出力への寄与
float g_ssgiDepthReject = 0.003f; // Z差が大きすぎるサンプルを捨てる
float g_ssgiRadiusScale = 1.0f; // 半径倍率（g_aoStepWorld × これ）

// 近傍の色を半球サンプルで集計して “間接光” を見立てる
float4 PS_SSGI(VS_OUT i) : COLOR0
{
    // 中心の元色
    float3 baseColor = tex2D(sampColor, i.uv).rgb;

    // 基準（法線・原点・参照Z）
    Basis basis = BuildBasis(i.uv);

    float3 normalV = basis.Nv;
    float3 originV = basis.vOrigin + normalV * (g_originPush * g_aoStepWorld);
    float refZ = basis.zRef;

    // TBN を構築（半球をローカル空間に）
    float3 upV = (abs(normalV.z) < 0.999f) ? float3(0, 0, 1) : float3(0, 1, 0);
    float3 tangentV = normalize(cross(upV, normalV));
    float3 bitangentV = cross(normalV, tangentV);

    // 集計
    float3 accumColor = 0.0f;
    float accumWeight = 0.0f;

    const int kSamplesSSGI = 64; // SM3.0 安全圏。必要なら 96〜128 に増やす

    [unroll]
    for (int sampleIndex = 0; sampleIndex < kSamplesSSGI; ++sampleIndex)
    {
        // 低相関半球方向
        float3 hemi = HemiDirFromIndex(sampleIndex);
        float3 dirV = normalize(tangentV * hemi.x + bitangentV * hemi.y + normalV * hemi.z);

        // 半径は二乗分布（近距離寄り密度）
        float u = ((float) sampleIndex + 0.5f) / (float) kSamplesSSGI;
        float radius = g_aoStepWorld * g_ssgiRadiusScale * (u * u);

        float3 sampleV = originV + dirV * radius;

        // 画面投影
        float4 clip = mul(float4(sampleV, 1.0f), g_matProj);
        if (clip.w <= 0.0f)
        {
            continue;
        }
        float2 suv = NdcToUv(clip);
        if (suv.x < 0.0f || suv.x > 1.0f || suv.y < 0.0f || suv.y > 1.0f)
        {
            continue;
        }

        // Z ガード：縁の遠側 or 中心Z に近いならOK
        float zImg = tex2D(sampZ, suv).a; // 画像の線形Z
        float zCtr = tex2D(sampZ, i.uv).a; // 中心の線形Z
        float zExp = saturate((sampleV.z - g_fNear) / (g_fFar - g_fNear)); // 期待Z

        bool nearEdgeOK = (abs(zImg - refZ) <= g_edgeZ) || (abs(zImg - zCtr) <= g_edgeZ);
        bool expectOK = (abs(zImg - zExp) <= g_ssgiDepthReject);

        if (!(nearEdgeOK && expectOK))
        {
            continue; // 別面/別物体への飛び越えを排除
        }

        // 重み：面に沿った方向ほど強く、距離で減衰
        float cosineWeight = saturate(dot(normalV, dirV));
        float distAtten = 1.0f / (1.0f + (radius * radius));
        float weight = cosineWeight * distAtten;

        // 色サンプル
        float3 sampleColor = tex2D(sampColor, suv).rgb;

        accumColor += sampleColor * weight;
        accumWeight += weight;
    }

    float3 indirect = (accumWeight > 1e-6f) ? (accumColor / accumWeight) : 0.0f;

    // 出力：元色 + 簡易間接光（お好みで AO を掛けても良い）
    float3 outColor = baseColor + indirect * g_ssgiStrength;
    return float4(saturate(outColor), 1.0f);
}

technique TechniqueSSGI
{
    pass P0
    {
        CullMode = NONE;
        VertexShader = compile vs_3_0 VS_Fullscreen();
        PixelShader = compile ps_3_0 PS_SSGI();
    }
}

