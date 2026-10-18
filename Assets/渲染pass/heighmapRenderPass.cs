// heighmapRenderPass.cs
using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.Rendering.RenderGraphModule;
using UnityEngine.Rendering.Universal;

public class heighmapRenderPass : ScriptableRenderPass
{
    private heighmapRendererFeature.Settings Settings;
    private RTHandle _heightRTHandle;
    private static readonly ShaderTagId HeightMapTag = new ShaderTagId("HeightMap");

    public heighmapRenderPass(heighmapRendererFeature.Settings settings, RTHandle heightRTHandle)
    {
        Settings = settings;
        _heightRTHandle = heightRTHandle;
        renderPassEvent = settings.renderPassEvent;
    }

    private class PassData
    {
        public RendererListHandle rendererList;
        public TextureHandle heightMapTexture;
    }

    public override void RecordRenderGraph(RenderGraph renderGraph, ContextContainer frameData)
    {
        UniversalCameraData cameraData = frameData.Get<UniversalCameraData>();
        UniversalRenderingData renderingData = frameData.Get<UniversalRenderingData>();

        var manager = HeightMapCameraManager.Instance;
        if (manager == null || manager.orthoCamera == null) return;
        Settings.orthoCamera = manager.orthoCamera;

        TextureHandle heightMapHandle = renderGraph.ImportTexture(_heightRTHandle);

        using (var builder = renderGraph.AddRasterRenderPass<PassData>("HeightMapPass", out var passData))
        {
            builder.SetRenderAttachment(heightMapHandle, 0, AccessFlags.Write);

            DrawingSettings drawSettings = new DrawingSettings(HeightMapTag, new SortingSettings(cameraData.camera));
            FilteringSettings filterSettings = new FilteringSettings(RenderQueueRange.all, Settings.terrainLayer);

            RendererListParams rendererListParams = new RendererListParams(renderingData.cullResults, drawSettings, filterSettings);
            passData.rendererList = renderGraph.CreateRendererList(rendererListParams);
            passData.heightMapTexture = heightMapHandle;

            builder.UseRendererList(passData.rendererList);
            builder.AllowPassCulling(false);

            builder.SetRenderFunc((PassData data, RasterGraphContext context) =>
            {
                // 清空渲染目标为黑色
                context.cmd.ClearRenderTarget(true, true, Color.black);

                // 1. 设置正交相机的视图投影矩阵（不要套 GL.GetGPUProjectionMatrix）
                Camera cam = Settings.orthoCamera;
                context.cmd.SetViewProjectionMatrices(cam.worldToCameraMatrix, cam.projectionMatrix);

                // 2. 绘制地形高度图
                context.cmd.DrawRendererList(data.rendererList);

                // 3. 恢复当前渲染相机（Scene视图相机或Game主相机）的原始矩阵
                context.cmd.SetViewProjectionMatrices(
                    cameraData.GetViewMatrix(),
                    cameraData.GetProjectionMatrix()
                );
            });
        }
    }
}