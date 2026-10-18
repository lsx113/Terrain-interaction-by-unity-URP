using UnityEngine;

/// <summary>
/// 把脚印相机锁在世界轴向上：始终位于目标正上方固定高度，始终朝正下方看。
///
/// 为什么需要：脚印相机是 player 的子物体，而 PlayerMove 会让 player 转身，
/// 子物体连世界旋转一起转，RT 的 U/V 轴就跟着 yaw 转了，
/// 而雪地着色器是按世界 XZ 算 footUV 的 —— 一转身脚印就错位。
/// 这里每帧强制覆盖世界位置和世界旋转，让两边始终对齐。
/// </summary>
[DisallowMultipleComponent]
public class FootprintCameraLock : MonoBehaviour
{
    [Tooltip("留空则自动取父物体（player），再找不到就找挂 PlayerMove 的物体")]
    public Transform target;

    [Tooltip("相机相对目标的高度（米）")]
    public float height = 33.79f;

    private void Awake()
    {
        if (target == null && transform.parent != null)
        {
            target = transform.parent;
        }

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
            Debug.LogWarning("[FootprintCameraLock] 找不到目标，请在 Inspector 里手动指定 Target。", this);
            enabled = false;
        }
    }

    private void LateUpdate()
    {
        Vector3 position = target.position;

        transform.SetPositionAndRotation(
            new Vector3(position.x, position.y + height, position.z),
            Quaternion.Euler(90f, 0f, 0f));
    }
}
