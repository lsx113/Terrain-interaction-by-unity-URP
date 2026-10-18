using UnityEngine;

[ExecuteAlways]
public class HeightMapCameraManager : MonoBehaviour
{
    public static HeightMapCameraManager Instance { get; private set; }

    public Camera orthoCamera;

    void OnEnable()
    {
        Instance = this;
    }

    void Awake()
    {
        if (Application.isPlaying && Instance != null && Instance != this)
        {
            Destroy(gameObject);
            return;
        }
        Instance = this;
    }

    void OnDestroy()
    {
        if (Instance == this)
            Instance = null;
    }
}