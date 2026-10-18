Shader "Custom/snowshader"
{
    Properties
    {
        [MainTexture] _BaseMap("Base Map", 2D) = "white" {}
        [Normal]_NormalMap("Normal Map",2D) = "bump" {}
        [NoScaleOffset] _AOMap("AO Map", 2D) = "white" {}
        _footprintsMap("foot Map",2D)="black"{}
        _Roungness("roungness",Range(0,1))=0.1

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
            CBUFFER_END
            float4 _HeightMapCameraParams;
            struct Attributes
            {
                float4 positionOS : POSITION;
                float3 normal:NORMAL;
                float4 tangentOS:TANGENT;
                float2 uv : TEXCOORD0;
            };

            struct Varyings
            {
                float4 positionCS : SV_POSITION;
                float2 uv         : TEXCOORD0;
                float3 positionWS : TEXCOORD1;
                float3 normalOS   : TEXCOORD2;   // 物体空间法线
                float4 tangentOS  : TEXCOORD3;   // 物体空间切线（w 是副切线符号）
                noperspective float2 screenUV : TEXCOORD5;//不做透视插值
            };

            // 细分因子
            struct TessFactors
            {
                float edge[3] : SV_TessFactor;      // 三条边的细分等级
                float inside : SV_InsideTessFactor; // 内部细分等级
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

            float3 LambertBRDF(float3 albedo)
            {
                return albedo / PI;   // 除以 PI 是为了能量守恒
            }

            // 全部加 My_ 前缀
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

            float3 My_ComputeF0(float3 albedo, float metallic)
            {
                return lerp(0.04, albedo, metallic);
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

            float CalcTessFactor(float3 worldPos)
            {
                float dist = distance(_WorldSpaceCameraPos, worldPos);
                // 近处细分多，远处细分少
                return lerp(8.0f, 2.0f, saturate(dist / 50.0f));
            }

            TessFactors PatchConstantFunc(InputPatch<Varyings, 3> patch){//
                TessFactors f;
                float3 p0=patch[0].positionWS;
                float3 p1=patch[1].positionWS;
                float3 p2=patch[2].positionWS;
                // 三条边的细分因子取两端点的较小值，保证边界一致
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
                OUT.uv = IN.uv;
               
                // 只传递物体空间的 TBN 三个轴，不做世界空间变换
                OUT.normalOS = IN.normal;
                OUT.tangentOS = IN.tangentOS;
                OUT.screenUV=posInputs.positionCS.xy / posInputs.positionCS.w * 0.5 + 0.5;
                return OUT;
            }

            [domain("tri")]                          // 处理三角形patch
            [partitioning("fractional_odd")]         // 分数细分，保证不同等级间平滑过渡
            [outputtopology("triangle_cw")]          // 输出三角形，顺时针缠绕
            [outputcontrolpoints(3)]                 // 输出3个控制点
            [patchconstantfunc("PatchConstantFunc")] // 指定细分因子计算函数
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

                // 2. UV映射
                float2 rangeMin = _HeightMapCameraParams.xy - _HeightMapCameraParams.z;
                float2 rangeSize = _HeightMapCameraParams.z * 2.0;
                float2 footUV = (positionWS.xz - rangeMin) / rangeSize;

                // 超出范围：直接原样输出
                if (any(footUV < 0.0) || any(footUV > 1.0))
                {
                    OUT.positionWS = positionWS;
                    OUT.uv = uv;
                    OUT.positionCS = TransformWorldToHClip(positionWS);
                    OUT.normalOS = normalOS;
                    OUT.screenUV = screenUV;
                    OUT.tangentOS = tangentOS;
                    return OUT;
                }

                // 3. 脚印图的 texel 世界尺寸
                float2 footTexelSize = rangeSize / 1024.0;

                // 4. 采样脚印图：中心 + 四邻域
                float footCenter = SAMPLE_TEXTURE2D_LOD(_footprintsMap, sampler_footprintsMap, footUV, 0).r;
                float footL = SAMPLE_TEXTURE2D_LOD(_footprintsMap, sampler_footprintsMap, footUV - float2(footTexelSize.x, 0), 0).r;
                float footR = SAMPLE_TEXTURE2D_LOD(_footprintsMap, sampler_footprintsMap, footUV + float2(footTexelSize.x, 0), 0).r;
                float footD = SAMPLE_TEXTURE2D_LOD(_footprintsMap, sampler_footprintsMap, footUV - float2(0, footTexelSize.y), 0).r;
                float footU = SAMPLE_TEXTURE2D_LOD(_footprintsMap, sampler_footprintsMap, footUV + float2(0, footTexelSize.y), 0).r;

                // 5. 位移顶点（脚印改变高度）
                positionWS.y -= footCenter*0.5;

                // 6. 计算脚印带来的高度梯度（没踩脚印的地方 dhdx = 0, dhdz = 0）
                float dhdx = -(footR - footL) / (2.0 * footTexelSize.x);
                float dhdz = -(footU - footD) / (2.0 * footTexelSize.y);

                // 7. 将脚印梯度直接叠加到原模型平滑法线上（去掉原来的 _TerrainHeightMap 采样）
                float3 normNormalOS = normalize(normalOS);
                float3 normTangentOS = normalize(tangentOS.xyz);

                float3 baseNormalWS = TransformObjectToWorldNormal(normNormalOS, true);
                // 在原地形法线基础上叠加脚印斜率 (-dhdx, 0, -dhdz)
                float3 N_ws = normalize(baseNormalWS + float3(-dhdx, 0.0, -dhdz) * max(baseNormalWS.y, 1e-4));

                // 8. 转回物体空间，并仅按法线变化量 (newNormalOS - normNormalOS) 偏转切线
                // 当 dhdx=0, dhdz=0 时，newNormalOS == normNormalOS，newTangentOS == normTangentOS，与框外 100% 一致
                float3 newNormalOS = TransformWorldToObjectNormal(N_ws, true);
                float3 newTangentOS = normalize(normTangentOS - dot(normTangentOS, newNormalOS - normNormalOS) * newNormalOS);

                // 9. 输出
                OUT.positionWS = positionWS;
                OUT.positionCS = TransformWorldToHClip(positionWS);
                OUT.uv = uv;
                OUT.normalOS = newNormalOS;
                OUT.tangentOS = float4(newTangentOS, tangentOS.w);
                OUT.screenUV = screenUV;

                return OUT;
            }

            half4 frag(Varyings IN) : SV_Target
            {
                //法线
                // 1. 归一化物体空间法线和切线（插值后长度可能不是 1）
                float3 normalOS = normalize(IN.normalOS);
                float3 tangentOS = normalize(IN.tangentOS.xyz);

                // 2. 算副切线（物体空间）
                float3 bitangentOS = cross(normalOS, tangentOS) * IN.tangentOS.w;

                // 3. 构建物体空间 TBN 矩阵
                float3x3 TBN_object = float3x3(tangentOS, bitangentOS, normalOS);

                // 4. 采样法线贴图，得到切线空间法线
                half4 normalSample = SAMPLE_TEXTURE2D(_NormalMap, sampler_NormalMap, IN.uv);
                half3 normalTS = UnpackNormal(normalSample);

                // 5. 切线空间 → 物体空间
                float3 normalObject = mul(normalTS, TBN_object);
                normalObject = normalize(normalObject);

                // 6. 物体空间 → 世界空间（法线用逆转置矩阵）
                float3 normalWS = TransformObjectToWorldNormal(normalObject);
                normalWS = normalize(normalWS);
                float4 shadowcoord=TransformWorldToShadowCoord(IN.positionWS);
                Light mainLight=GetMainLight(shadowcoord);
                half shadow=mainLight.shadowAttenuation;
                float3 V=normalize(GetWorldSpaceViewDir(IN.positionWS));
                float3 L=normalize(mainLight.direction);
                float3 radiance=mainLight.color;
                float3 basecolor=SAMPLE_TEXTURE2D(_BaseMap,sampler_BaseMap,IN.uv);
                float3 color=My_CookTorrance(normalWS,V,L,radiance,basecolor,0,_Roungness)*shadow;
                //IBL光
                float3 reflectVector = reflect(-V, normalWS);
                float mark=SAMPLE_TEXTURE2D(_AOMap,sampler_AOMap,IN.uv).r;
                color+=GlossyEnvironmentReflection(reflectVector,IN.positionWS,_Roungness,1.0,IN.screenUV)*mark;
                return float4(color,1.0f);

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
                // 输出高度到R通道
                float height = IN.positionWS.y;
                return float4(height, 0, 0, 1);
            }
            ENDHLSL
        }

    }
}
