// heighmapRendererFeature.cs
using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.Rendering.Universal;

public class heighmapRendererFeature : ScriptableRendererFeature
{
    [System.Serializable]
    public class Settings
    {
        public Camera orthoCamera;
        public LayerMask terrainLayer = 1;
        public RenderPassEvent renderPassEvent = RenderPassEvent.BeforeRenderingOpaques;
        public int textureSize = 1024;
    }

    public Settings settings = new Settings();
    private heighmapRenderPass _pass;
    private RenderTexture _heightRT;
    private RTHandle _heightRTHandle;

    public override void Create()
    {
        if (settings == null)
            settings = new Settings();

        ReleaseRT();

        _heightRT = new RenderTexture(settings.textureSize, settings.textureSize, 0, RenderTextureFormat.RFloat);
        _heightRT.name = "HeightMapRT";
        _heightRT.wrapMode = TextureWrapMode.Clamp;
        _heightRT.Create();

        _heightRTHandle = RTHandles.Alloc(_heightRT);
        _pass = new heighmapRenderPass(settings, _heightRTHandle);
    }

    public override void AddRenderPasses(ScriptableRenderer renderer, ref RenderingData renderingData)
    {
        if (_heightRT == null || _heightRTHandle == null) return;

        var manager = HeightMapCameraManager.Instance;
        if (manager == null || manager.orthoCamera == null) return;

        Camera camera = manager.orthoCamera;
        Vector3 pos = camera.transform.position;
        float halfSize = Mathf.Max(camera.orthographicSize, 0.001f); // ·ÀÖ¹³ý0

        Vector4 cameraParams = new Vector4(pos.x, pos.z, halfSize, 0);
        Shader.SetGlobalVector("_HeightMapCameraParams", cameraParams);
        Shader.SetGlobalTexture("_TerrainHeightMap", _heightRT);
        renderer.EnqueuePass(_pass);
    }

    private void ReleaseRT()
    {
        if (_heightRTHandle != null)
        {
            _heightRTHandle.Release();
            _heightRTHandle = null;
        }
        if (_heightRT != null)
        {
            _heightRT.Release();
            DestroyImmediate(_heightRT);
            _heightRT = null;
        }
    }

    protected override void Dispose(bool disposing)
    {
        ReleaseRT();
    }
}