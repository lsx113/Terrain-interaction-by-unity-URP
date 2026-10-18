using UnityEngine;

[RequireComponent(typeof(CharacterController))]
public class PlayerMove : MonoBehaviour
{
    [Header("移动")]
    public float speed = 5f;
    public float gravity = -9.81f;

    [Tooltip("留空则自动取 Tag 为 MainCamera 的相机")]
    public Camera cam;

    [Header("转身")]
    [Tooltip("角色朝移动方向转身")]
    public bool faceMoveDirection = true;

    [Tooltip("转身速度，度/秒")]
    public float turnSpeed = 720f;

    private CharacterController cc;
    private Vector3 velocity;

    private void Start()
    {
        cc = GetComponent<CharacterController>();
        if (cam == null)
        {
            cam = Camera.main;
        }
    }

    private void Update()
    {
        Vector3 direction = GetMoveDirection();
        if (direction.sqrMagnitude > 0f)
        {
            cc.Move(direction * speed * Time.deltaTime);
            if (faceMoveDirection)
            {
                FaceDirection(direction);
            }
        }

        ApplyGravity();
    }

    /// <summary>把 WASD 按相机的水平朝向换算成世界方向。</summary>
    private Vector3 GetMoveDirection()
    {
        Vector3 input = new Vector3(Input.GetAxis("Horizontal"), 0f, Input.GetAxis("Vertical"));
        if (input.sqrMagnitude < 0.0001f)
        {
            return Vector3.zero;
        }
        input = Vector3.ClampMagnitude(input, 1f);   // 斜着走不加速

        Transform reference = cam != null ? cam.transform : transform;
        Vector3 forward = Vector3.ProjectOnPlane(reference.forward, Vector3.up);
        if (forward.sqrMagnitude < 0.000001f)
        {
            // 相机垂直俯视时 forward 会退化，用它的 up 在水平面的投影兜底
            forward = Vector3.ProjectOnPlane(reference.up, Vector3.up);
        }
        forward.Normalize();
        Vector3 right = Vector3.Cross(Vector3.up, forward);

        return (forward * input.z + right * input.x).normalized;
    }

    private void FaceDirection(Vector3 direction)
    {
        Quaternion wanted = Quaternion.LookRotation(direction, Vector3.up);
        transform.rotation = Quaternion.RotateTowards(
            transform.rotation, wanted, turnSpeed * Time.deltaTime);
    }

    private void ApplyGravity()
    {
        if (cc.isGrounded && velocity.y < 0f)
        {
            velocity.y = -2f;
        }
        velocity.y += gravity * Time.deltaTime;
        cc.Move(velocity * Time.deltaTime);
    }
}
