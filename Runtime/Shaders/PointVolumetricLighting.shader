Shader "KuanMi/PointVolumetricLighting"
{
    Properties
    {
        _Intensity("Intensity",Range(0.0,50.0)) = 1.0
        _MieK("MieK",Range(-1.0,1.0)) = 0.8

        _Range("Range",float) = 1.0
        _lightIndex("lightIndex",int) = 0
    }

    SubShader
    {
        Tags
        {
            "RenderPipeline" = "UniversalPipeline"
            "RenderType"="Transparent"
            "Queue"="Transparent"
        }

        Pass
        {

            Name "ForwardLit"
            Tags
            {
                "LightMode" = "UniversalForward"
            }

            Cull Front
            Blend One One, One One
            //            Blend One Zero, One Zero
            ZTest Always
            ZWrite Off

            //            Cull Off
            //            // 附加
            //            Blend one one
            //            //            Blend Off
            //            ZTest Off
            //            ZWrite Off

            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag

            #define MAIN_LIGHT_CALCULATE_SHADOWS
            #define _ADDITIONAL_LIGHT_SHADOWS
            // #define _MAIN_LIGHT_SHADOWS_CASCADE

            #include "Packages/com.unity.render-pipelines.core/ShaderLibrary/Common.hlsl"
            #include "Packages/com.unity.render-pipelines.core/ShaderLibrary/CommonMaterial.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/DeclareDepthTexture.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/DeclareOpaqueTexture.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Shadows.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/RealtimeLights.hlsl"

            #include "KuanMiTool.hlsl"

            #define MieScattering(cosAngle, g) g.w * (g.x / (pow(g.y - g.z * cosAngle, 1.5)))
            #define MieScattering2(cosAngle, k) (1-k*k)/(4*PI*(1+k*cosAngle)*(1+k*cosAngle))


            struct Attributes
            {
                float4 positionOS : POSITION;
            };

            struct Varyings
            {
                float4 positionCS : SV_POSITION;
            };

            CBUFFER_START(UnityPerMaterial)
            float _Intensity;
            float _MieK;
            float _Range;
            int _lightIndex;
            CBUFFER_END

            Varyings vert(Attributes IN)
            {
                Varyings output;
                output.positionCS = TransformObjectToHClip(IN.positionOS.xyz);
                return output;
            }

            float noise(float2 uv)
            {
                return frac(sin(dot(uv, float2(12.9898, 78.233))) * 43758.5453);
            }

            float3 noise3(float2 uv)
            {
                return float3(noise(uv), noise(uv + float2(1, 0)), noise(uv + float2(0, 1)));
            }


            Light GetAdditionalPerObjectLightForVol(int perObjectLightIndex, float3 positionWS)
            {
                // Abstraction over Light input constants

                float4 lightPositionWS = _AdditionalLightsPosition[perObjectLightIndex];
                half3 color = _AdditionalLightsColor[perObjectLightIndex].rgb;
                half4 distanceAndSpotAttenuation = _AdditionalLightsAttenuation[perObjectLightIndex];
                half4 spotDirection = _AdditionalLightsSpotDir[perObjectLightIndex];
                uint lightLayerMask = asuint(_AdditionalLightsLayerMasks[perObjectLightIndex]);

                // Directional lights store direction in lightPosition.xyz and have .w set to 0.0.
                // This way the following code will work for both directional and punctual lights.
                float3 lightVector = lightPositionWS.xyz - positionWS * lightPositionWS.w;
                float distanceSqr = max(dot(lightVector, lightVector), HALF_MIN);

                half3 lightDirection = half3(lightVector * rsqrt(distanceSqr));
                // full-float precision required on some platforms
                float attenuation = DistanceAttenuation(distanceSqr, distanceAndSpotAttenuation.xy) * AngleAttenuation(
                    spotDirection.xyz, lightDirection, distanceAndSpotAttenuation.zw);

                Light light;
                light.direction = lightDirection;
                light.distanceAttenuation = attenuation;
                light.shadowAttenuation = 1.0;
                // This value can later be overridden in GetAdditionalLight(uint i, float3 positionWS, half4 shadowMask)
                light.color = color;
                light.layerMask = lightLayerMask;

                return light;
            }


            Light GetAdditionalLightForVol(uint lightIndex, float3 positionWS, half4 shadowMask)
            {
                // int lightIndex = GetPerObjectLightIndex(i);
                Light light = GetAdditionalPerObjectLightForVol(lightIndex, positionWS);
                half4 occlusionProbeChannels = _AdditionalLightsOcclusionProbes[lightIndex];
                light.shadowAttenuation = AdditionalLightShadow(lightIndex, positionWS, light.direction, shadowMask,
                                                                occlusionProbeChannels);
                return light;
            }


            half4 frag(Varyings IN) : SV_Target
            {
                float2 screenUV = GetNormalizedScreenSpaceUV(IN.positionCS);

                // return float4(screenUV, 0, 1);
                #if UNITY_REVERSED_Z
                real depth = SampleSceneDepth(screenUV);
                #else
                real depth = lerp(UNITY_NEAR_CLIP_VALUE, 1, SampleSceneDepth(screenUV));
                #endif
                float3 worldPos = ComputeWorldSpacePosition(screenUV, depth, UNITY_MATRIX_I_VP);

                float3 ray = worldPos - _WorldSpaceCameraPos;

                int perObjectLightIndex = _lightIndex;

                float4 lightPositionWS = _AdditionalLightsPosition[perObjectLightIndex];

                Sphere sphere;
                sphere.origin = lightPositionWS.xyz;
                sphere.r = _Range;

                Line viewLine;
                viewLine.origin = _WorldSpaceCameraPos;
                viewLine.direction = normalize(ray);

                float3 TP1;
                float3 TP2;
                float num = LineToSpherePoint(viewLine, sphere, TP1, TP2);

                clip(num - 0.5);

                float3 nearPoint = TP1;;
                float3 farPoint = TP2;;

                float3 nearLen = nearPoint - _WorldSpaceCameraPos;
                float3 worldLen = worldPos - _WorldSpaceCameraPos;


                float3 rayOrigin = dot(nearLen, ray) > 0 ? nearPoint : _WorldSpaceCameraPos;

                clip(length(worldLen) - length(rayOrigin - _WorldSpaceCameraPos));

                worldPos = dot(farPoint - worldPos,ray)<0 ?farPoint : worldPos;

                float numSteps = 15;

                float3 rayDir = (worldPos - rayOrigin) / numSteps;
                float n = length(rayDir);

                float3 density = 0;

                float3 currentPos;

                for (int i = 1; i < numSteps; i++)
                {
                    currentPos = rayOrigin + rayDir * (i + noise(screenUV * i + _Time.xy)) ;

                    Light addLight = GetAdditionalLightForVol(_lightIndex, currentPos, half4(1, 1, 1, 1));
                    float3 light = addLight.color * addLight.distanceAttenuation * addLight.shadowAttenuation;

                    float cosAngle = dot(-addLight.direction, normalize(ray));
                    light *= MieScattering2(cosAngle, _MieK);

                    light *= n;
                    density += light;
                }

                density = 1 - exp(-density);
                density *= _Intensity;

                return half4(density, 1.0);
            }
            ENDHLSL
        }
    }
}