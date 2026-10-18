using UnityEngine;

/// <summary>
/// 第三人称跟随摄像机：绕目标旋转 + 滚轮缩放 + 自动避免穿墙。
/// 默认按住鼠标右键才能转视角，防止编辑时误转。
/// </summary>
[RequireComponent(typeof(Camera))]
[DisallowMultipleComponent]
public class ThirdPersonCamera : MonoBehaviour
{
    [Header("目标")]
    [Tooltip("留空则自动查找挂 PlayerMove 的物体")]
    public Transform target;

    [Tooltip("视点相对目标原点的偏移，一般在头顶附近")]
    public Vector3 pivotOffset = new Vector3(0f, 1.6f, 0f);

    [Header("视角")]
    public float distance = 6f;
    public float minDistance = 1.5f;
    public float maxDistance = 15f;
    public float zoomSpeed = 4f;
    public float mouseSensitivity = 3f;
    public float minPitch = -35f;
    public float maxPitch = 75f;

    [Tooltip("勾上 = 必须按住鼠标右键才能转视角")]
    public bool requireRightButton = true;

    [Header("平滑")]
    public float followSmoothTime = 0.06f;
    public float zoomSmoothSpeed = 12f;

    [Header("防穿墙")]
    public LayerMask collisionMask = ~0;
    public float collisionRadius = 0.25f;

    private const int MaxHits = 8;
    private const float MinCollisionDistance = 0.1f;

    private readonly RaycastHit[] _hits = new RaycastHit[MaxHits];

    private float _yaw;
    private float _pitch;
    private float _currentDistance;
    private Vector3 _pivotVelocity;
    private Vector3 _smoothedPivot;

    private void Awake()
    {
        if (target == null)
        {
            PlayerMove move = FindFirstObjectByType<PlayerMove>();
            if (move != null)
            {
                target = move.transform;
            }
        }

        if (target == null)
        {
            Debug.LogWarning("[ThirdPersonCamera] 找不到目标，请在 Inspector 里手动指定 Target。", this);
            enabled = false;
            return;
        }

        // 用场景里摆好的朝向作为初始视角
        Vector3 euler = transform.eulerAngles;
        _yaw = euler.y;
        _pitch = Mathf.DeltaAngle(0f, euler.x);

        distance = Mathf.Clamp(distance, minDistance, maxDistance);
        _currentDistance = distance;
        _smoothedPivot = GetPivot();
    }

    private void LateUpdate()
    {
        ReadInput();

        _smoothedPivot = Vector3.SmoothDamp(
            _smoothedPivot, GetPivot(), ref _pivotVelocity, followSmoothTime);

        ApplyTransform();
    }

    private void ReadInput()
    {
        if (!requireRightButton || Input.GetMouseButton(1))
        {
            // 鼠标轴本身就是「这一帧的位移量」，不要再乘 deltaTime
            _yaw += Input.GetAxis("Mouse X") * mouseSensitivity;
            _pitch -= Input.GetAxis("Mouse Y") * mouseSensitivity;
        }
        _pitch = Mathf.Clamp(_pitch, minPitch, maxPitch);

        float scroll = Input.GetAxis("Mouse ScrollWheel");
        if (Mathf.Abs(scroll) > Mathf.Epsilon)
        {
            distance = Mathf.Clamp(
                distance - scroll * zoomSpeed, minDistance, maxDistance);
        }
    }

    private void ApplyTransform()
    {
        Quaternion rotation = Quaternion.Euler(_pitch, _yaw, 0f);
        Vector3 back = rotation * Vector3.back;

        float wanted = Mathf.Clamp(distance, minDistance, maxDistance);
        float allowed = ResolveCollision(_smoothedPivot, back, wanted);

        // 撞墙立刻拉近（否则会看到墙体截面），离开墙体后平滑拉远
        _currentDistance = allowed < _currentDistance
            ? allowed
            : Mathf.Lerp(_currentDistance, allowed,
                1f - Mathf.Exp(-zoomSmoothSpeed * Time.deltaTime));

        transform.SetPositionAndRotation(_smoothedPivot + back * _currentDistance, rotation);
    }

    private float ResolveCollision(Vector3 pivot, Vector3 direction, float wanted)
    {
        int count = Physics.SphereCastNonAlloc(
            pivot, collisionRadius, direction, _hits, wanted,
            collisionMask, QueryTriggerInteraction.Ignore);

        float nearest = wanted;
        for (int i = 0; i < count; i++)
        {
            Collider collider = _hits[i].collider;
            if (collider == null || IsPartOfTarget(collider.transform))
            {
                continue;
            }
            if (_hits[i].distance < nearest)
            {
                nearest = _hits[i].distance;
            }
        }

        return Mathf.Max(nearest, MinCollisionDistance);
    }

    private bool IsPartOfTarget(Transform candidate)
    {
        return candidate == target || candidate.IsChildOf(target);
    }

    private Vector3 GetPivot()
    {
        return target.TransformPoint(pivotOffset);
    }
}
