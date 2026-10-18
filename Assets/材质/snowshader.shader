Shader "Custom/snowshader"
{
    Properties
    {
        [MainTexture] _BaseMap("Base Map", 2D) = "white" {}
        [Normal]_NormalMap("Normal Map", 2D) = "bump" {}
        [NoScaleOffset] _AOMap("AO Map", 2D) = "white" {}
        _footprintsMap("foot Map", 2D) = "black" {}
        _Roungness("roungness", Range(0, 1)) = 0.1
        _DepthScale("Depth Scale", Range(0, 2)) = 0.5
        _MaxDepth("Max Depth (m)", Range(0, 1)) = 0.2
    }

    SubShader
    {
        Tags { "RenderType" = "Opaque" "RenderPipeline" = "UniversalPipeline" }

        Pass
        {
            HLSLPROGRAM

            #pragma vertex vert
            #pragma hull HullProgram
            #pragma domain DomainProgram
            #pragma fragment frag
            #pragma target 4.6
            #pragma multi_compile _ _MAIN_LIGHT_SHADOWS _MAIN_LIGHT_SHADOWS_CASCADE _MAIN_LIGHT_SHADOWS_SCREEN
            #pragma multi_compile_fragment _ _REFLECTION_PROBE_BLENDING
            #pragma multi_compile_fragment _ _REFLECTION_PROBE_BOX_PROJECTION

            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Shadows.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/GlobalIllumination.hlsl"

            CBUFFER_START(UnityPerMaterial)
            float _Roungness;
            float _DepthScale;
            float _MaxDepth;
            CBUFFER_END

            float4 _HeightMapCameraParams;

            struct Attributes
            {
                float4 positionOS : POSITION;
                float3 normal     : NORMAL;
                float4 tangentOS  : TANGENT;
                float2 uv         : TEXCOORD0;
            };

            struct Varyings
            {
                float4 positionCS : SV_POSITION;
                float2 uv         : TEXCOORD0;
                float3 positionWS : TEXCOORD1;
                float3 normalOS   : TEXCOORD2;   // 物体空间法线
                float4 tangentOS  : TEXCOORD3;   // 物体空间切线（w 是副切线符号）
                noperspective float2 screenUV : TEXCOORD5;
            };

            struct TessFactors
            {
                float edge[3] : SV_TessFactor;
                float inside  : SV_InsideTessFactor;
            };

            TEXTURE2D(_BaseMap);
            SAMPLER(sampler_BaseMap);
            TEXTURE2D(_NormalMap);
            SAMPLER(sampler_NormalMap);
            TEXTURE2D(_AOMap);
            SAMPLER(sampler_AOMap);
            TEXTURE2D(_footprintsMap);
            SAMPLER(sampler_footprintsMap);
            TEXTURE2D(_TerrainHeightMap);
            SAMPLER(sampler_TerrainHeightMap);

            // ---------------- BRDF ----------------

            float My_D_GGX(float NdotH, float roughness)
            {
                float alpha  = roughness * roughness;
                float alpha2 = alpha * alpha;
                float d = (NdotH * NdotH) * (alpha2 - 1.0) + 1.0;
                return alpha2 / (PI * d * d);
            }

            float3 My_FresnelSchlick(float3 F0, float VdotH)
            {
                return F0 + (1.0 - F0) * pow(1.0 - VdotH, 5.0);
            }

            float My_G1_SchlickGGX(float NdotX, float roughness)
            {
                float k = (roughness + 1.0) * (roughness + 1.0) / 8.0;
                return NdotX / (NdotX * (1.0 - k) + k);
            }

            float My_G_Smith(float NdotV, float NdotL, float roughness)
            {
                return My_G1_SchlickGGX(NdotV, roughness) * My_G1_SchlickGGX(NdotL, roughness);
            }

            float3 My_CookTorrance(float3 N, float3 V, float3 L,
            float3 radiance,
            float3 albedo, float metallic, float roughness)
            {
                float3 H = normalize(V + L);
                float NdotV = max(dot(N, V), 1e-4);
                float NdotL = max(dot(N, L), 0.0);
                float NdotH = max(dot(N, H), 0.0);
                float VdotH = max(dot(V, H), 0.0);

                float3 F0 = lerp(0.04, albedo, metallic);
                float3 F  = My_FresnelSchlick(F0, VdotH);
                float  D  = My_D_GGX(NdotH, roughness);
                float  G  = My_G_Smith(NdotV, NdotL, roughness);

                float3 specular = (F * D * G) / max(4.0 * NdotV * NdotL, 1e-4);
                float3 kd = (1.0 - F) * (1.0 - metallic);
                float3 diffuse = kd * albedo / PI;

                return (diffuse + specular) * radiance * NdotL;
            }

            // ---------------- 细分 ----------------

            float CalcTessFactor(float3 worldPos)
            {
                float dist = distance(_WorldSpaceCameraPos, worldPos);
                return lerp(8.0, 2.0, saturate(dist / 50.0));
            }

            TessFactors PatchConstantFunc(InputPatch<Varyings, 3> patch)
            {
                TessFactors f;
                float3 p0 = patch[0].positionWS;
                float3 p1 = patch[1].positionWS;
                float3 p2 = patch[2].positionWS;

                // 三条边的细分因子取两端点的较小值，保证相邻 patch 边界一致
                f.edge[0] = min(CalcTessFactor(p1), CalcTessFactor(p2)); // p0 的对边 (p1-p2)
                f.edge[1] = min(CalcTessFactor(p2), CalcTessFactor(p0)); // p1 的对边 (p2-p0)
                f.edge[2] = min(CalcTessFactor(p0), CalcTessFactor(p1)); // p2 的对边 (p0-p1)

                // 内部因子取三个点的最大值
                f.inside = max(max(CalcTessFactor(p0), CalcTessFactor(p1)), CalcTessFactor(p2));
                return f;
            }

            Varyings vert(Attributes IN)
            {
                Varyings OUT;

                VertexPositionInputs posInputs = GetVertexPositionInputs(IN.positionOS.xyz);
                OUT.positionCS = posInputs.positionCS;
                OUT.positionWS = posInputs.positionWS;
                OUT.uv         = IN.uv;

                OUT.normalOS  = IN.normal;
                OUT.tangentOS = IN.tangentOS;
                OUT.screenUV  = posInputs.positionCS.xy / posInputs.positionCS.w * 0.5 + 0.5;

                return OUT;
            }

            [domain("tri")]
            [partitioning("fractional_odd")]
            [outputtopology("triangle_cw")]
            [outputcontrolpoints(3)]
            [patchconstantfunc("PatchConstantFunc")]
            Varyings HullProgram(InputPatch<Varyings, 3> patch, uint id : SV_OutputControlPointID)
            {
                return patch[id];
            }

            [domain("tri")]
            Varyings DomainProgram(TessFactors factors,
            OutputPatch<Varyings, 3> patch,
            float3 baryCoords : SV_DomainLocation)
            {
                Varyings OUT;

                // 1. 插值所有字段
                float3 positionWS = patch[0].positionWS * baryCoords.x +
                patch[1].positionWS * baryCoords.y +
                patch[2].positionWS * baryCoords.z;
                float2 uv = patch[0].uv * baryCoords.x +
                patch[1].uv * baryCoords.y +
                patch[2].uv * baryCoords.z;
                float3 normalOS = patch[0].normalOS * baryCoords.x +
                patch[1].normalOS * baryCoords.y +
                patch[2].normalOS * baryCoords.z;
                float4 tangentOS = patch[0].tangentOS * baryCoords.x +
                patch[1].tangentOS * baryCoords.y +
                patch[2].tangentOS * baryCoords.z;
                float2 screenUV = patch[0].screenUV * baryCoords.x +
                patch[1].screenUV * baryCoords.y +
                patch[2].screenUV * baryCoords.z;

                // 2. 世界 XZ → 脚印纹理 UV
                float2 rangeMin  = _HeightMapCameraParams.xy - _HeightMapCameraParams.z;
                float2 rangeSize = _HeightMapCameraParams.z * 2.0;
                float2 footUV    = (positionWS.xz - rangeMin) / rangeSize;

                // 3. 越界：原样输出，不采样、不位移、不扰动
                if (any(footUV < 0.0) || any(footUV > 1.0))
                {
                    OUT.positionWS  = positionWS;
                    OUT.uv          = uv;
                    OUT.positionCS  = TransformWorldToHClip(positionWS);
                    OUT.normalOS    = normalOS;
                    OUT.tangentOS   = tangentOS;
                    OUT.screenUV    = screenUV;
                    return OUT;
                }

                // 4. 脚印 texel 对应的世界尺寸（与纹理 1024×1024 对应）
                float2 footTexelSize = rangeSize / 1024.0;

                // 5. 采样脚印图：中心 + 四邻域（domain 阶段必须显式 LOD 0）
                float footCenter = SAMPLE_TEXTURE2D_LOD(_footprintsMap, sampler_footprintsMap, footUV, 0).r;
                float footL = SAMPLE_TEXTURE2D_LOD(_footprintsMap, sampler_footprintsMap, footUV - float2(footTexelSize.x, 0), 0).r;
                float footR = SAMPLE_TEXTURE2D_LOD(_footprintsMap, sampler_footprintsMap, footUV + float2(footTexelSize.x, 0), 0).r;
                float footD = SAMPLE_TEXTURE2D_LOD(_footprintsMap, sampler_footprintsMap, footUV - float2(0, footTexelSize.y), 0).r;
                float footU = SAMPLE_TEXTURE2D_LOD(_footprintsMap, sampler_footprintsMap, footUV + float2(0, footTexelSize.y), 0).r;

                // 6. 标准高度场梯度：hx = ∂h/∂x，hz = ∂h/∂z（单位：米/米）
                float hx = (footR - footL) / (2.0 * footTexelSize.x);
                float hz = (footU - footD) / (2.0 * footTexelSize.y);

                // 7. 原法线 / 切线（世界空间），并构造正交单位基 T'、B'、N0
                float3 normNormalOS  = normalize(normalOS);
                float3 normTangentOS = normalize(tangentOS.xyz);

                float3 N0_ws = TransformObjectToWorldNormal(normNormalOS, true);
                float3 T_ws  = TransformObjectToWorldDir(normTangentOS, true);

                // Gram-Schmidt：保证 T_ws ⊥ N0_ws
                T_ws = normalize(T_ws - dot(T_ws, N0_ws) * N0_ws);

                // 副切线：单位正交向量叉乘，长度 = 1；w 只取符号
                float tangentSign = (tangentOS.w >= 0.0) ? 1.0 : -1.0;
                float3 B_ws = cross(N0_ws, T_ws) * tangentSign;

                // 8. 位移：沿原法线往下压，clamp 防止大 scale 下三角形翻转
                float depth = min(footCenter * _DepthScale, _MaxDepth);
                positionWS -= N0_ws * depth;

                // 9. 法线扰动：N ∝ N0 + s·(hx·T' + hz·B')
                //    零梯度时严格退化为 N0
                float3 perturbation = hx * T_ws + hz * B_ws;
                float3 N_ws = normalize(N0_ws + perturbation * _DepthScale);

                // 10. 转回物体空间；切线仅按法线变化量偏转，零扰动时严格不变
                float3 newNormalOS  = TransformWorldToObjectNormal(N_ws, true);
                float3 newTangentOS = normalize(normTangentOS
                - dot(normTangentOS, newNormalOS - normNormalOS) * newNormalOS);

                // 11. 输出
                OUT.positionWS  = positionWS;
                OUT.positionCS  = TransformWorldToHClip(positionWS);
                OUT.uv          = uv;
                OUT.normalOS    = newNormalOS;
                OUT.tangentOS   = float4(newTangentOS, tangentOS.w);
                OUT.screenUV    = screenUV;

                return OUT;
            }

            half4 frag(Varyings IN) : SV_Target
            {
                // 1. 归一化物体空间法线和切线
                float3 normalOS  = normalize(IN.normalOS);
                float3 tangentOS = normalize(IN.tangentOS.xyz);

                // 2. 物体空间副切线
                float3 bitangentOS = cross(normalOS, tangentOS) * IN.tangentOS.w;

                // 3. 物体空间 TBN
                float3x3 TBN_object = float3x3(tangentOS, bitangentOS, normalOS);

                // 4. 法线贴图：切线空间 → 物体空间 → 世界空间
                half4 normalSample = SAMPLE_TEXTURE2D(_NormalMap, sampler_NormalMap, IN.uv);
                half3 normalTS     = UnpackNormal(normalSample);
                float3 normalObject = normalize(mul(normalTS, TBN_object));
                float3 normalWS     = normalize(TransformObjectToWorldNormal(normalObject));

                // 5. 主光与阴影
                float4 shadowcoord = TransformWorldToShadowCoord(IN.positionWS);
                Light mainLight = GetMainLight(shadowcoord);
                half shadow = mainLight.shadowAttenuation;

                float3 V = normalize(GetWorldSpaceViewDir(IN.positionWS));
                float3 L = normalize(mainLight.direction);
                float3 radiance = mainLight.color;
                float3 basecolor = SAMPLE_TEXTURE2D(_BaseMap, sampler_BaseMap, IN.uv).rgb;

                float3 color = My_CookTorrance(normalWS, V, L, radiance, basecolor, 0, _Roungness) * shadow;

                // 6. IBL
                float3 reflectVector = reflect(-V, normalWS);
                float ao = SAMPLE_TEXTURE2D(_AOMap, sampler_AOMap, IN.uv).r;
                color += GlossyEnvironmentReflection(reflectVector, IN.positionWS, _Roungness, 1.0, IN.screenUV) * ao;

                return float4(color, 1.0);
            }
            ENDHLSL
        }

        Pass
        {
            Name "HeightMap"
            Tags { "LightMode" = "HeightMap" }

            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag

            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"

            struct Attributes
            {
                float4 positionOS : POSITION;
            };

            struct Varyings
            {
                float4 positionCS : SV_POSITION;
                float3 positionWS : TEXCOORD0;
            };

            Varyings vert(Attributes IN)
            {
                Varyings OUT;
                OUT.positionWS = TransformObjectToWorld(IN.positionOS.xyz);
                OUT.positionCS = TransformWorldToHClip(OUT.positionWS);
                return OUT;
            }

            float4 frag(Varyings IN) : SV_Target
            {
                float height = IN.positionWS.y;
                return float4(height, 0, 0, 1);
            }
            ENDHLSL
        }
    }
}