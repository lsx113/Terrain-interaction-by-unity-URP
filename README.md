# PRB-render-by-unity

## 地形交互技术

### 1. 技术方案

本技术旨在实现游戏中人物与环境的交互，其中最经典的就是人物行走时在地面留下脚印。项目中，使用雪地为演示场景，实现基础的交互效果。技术路线大致是：在角色底部搭载粒子系统来模拟脚印，用**正交相机记录粒子的轨迹存进指定纹理，然后在地形shader里读取该纹理，做顶点偏移**，从而实现地面凹陷出脚印的效果。

### 2. 技术步骤

整体数据流

```
角色移动
  └─ footprints.cs 每移动 0.5 m(可改) 发射一颗粒子
       └─ 粒子系统（Layer 3，Billboard，Render Alignment = World）
            └─ footCamera（正交、垂直向下、只渲染 Layer 3、不清屏）
                 └─ snowfootwrite（1024×1024 RFloat CustomRenderTexture，逐帧累积）
                      └─ heighmapRendererFeature 每帧写入 _HeightMapCameraParams
                           └─ snowshader 用世界 XZ 坐标算 UV，采样脚印图
                                └─ 曲面细分提供足够顶点密度
                                     └─ 顶点下沉 + 法线/切线重构
                                          └─ 地面出现脚印凹陷
```

#### 2.1 场景对象一览

| 对象                | 组件                        | 关键配置                                                                                                                                             |
| ----------------- | ------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------ |
| `footCamera`      | Camera                    | 正交；Orthographic Size = 10（覆盖 20 m × 20 m）；Culling Mask 只勾 Layer 3；**Background Type = Uninitialized**（不清屏，逐帧累积）；Target Texture = `snowfootwrite` |
|                   | Transform                 | **场景根物体**，不作为 Player 子物体（避免跟着角色转身）                                                                                                               |
| `Particle System` | Particle System           | Layer = 3；Start Speed = 0；Start Size = 0.4；Start Lifetime = 2；开启 3D Rotation，Start Rotation X = −90°；Play On Awake + Looping                     |
|                   | Particle System Renderer  | Render Mode = Billboard；**Render Alignment = World**；Max Particle Size = 0.07                                                                    |
| `Player`          | `footprints.cs`           | `footPS`、`footcam`、`emitDistance = 0.5`（实际步频调试值 0.1，见 3.8）                                                                                       |
|                   | `playermove.cs`           | 相对相机的移动 + 朝向移动方向转身                                                                                                                               |
| `Manager`         | `HeightMapCameraManager`  | `orthoCamera` 指向 `footCamera`                                                                                                                    |
| `PC_Renderer`     | `heighmapRendererFeature` | Render Pass Event = Before Rendering Opaques (250)；Texture Size = 1024                                                                           |
| `snowfootwrite`   | Custom Render Texture     | 1024 × 1024；RFloat（单通道 32 位浮点）；Wrap = Clamp；Filter = Bilinear；Update Mode = On Load（不自动清屏）                                                       |
| `雪地.mat`          | `snowshader.shader`       | `_BaseMap` / `_NormalMap` / `_AOMap` / `_footprintsMap`                                                                                          |

#### 2.2 创建脚印相机与脚印纹理

**脚印纹理**用 `CustomRenderTexture`（`Assets/snowTextures/snowfootwrite.asset`），而不是运行时 `new` 出来的 `RenderTexture`：

- 它是**资源文件**，可以在 Inspector 里直接指定给相机，也能在 shader 里当普通贴图采样；
- 尺寸 1024 × 1024，格式 **RFloat**（单通道 32 位浮点）。只有高度一个量，单通道就够；选浮点而不是 8 位，一是脚印边缘的梯度需要足够精度，否则量化成台阶，二是浮点可以表达**负高度**，这是后面做"中间凹陷、两边突起"的必要条件；
- Wrap Mode 设为 **Clamp**，避免边界采样时另一侧的粒子"绕"回来（同时这也是 shader 里必须做越界判断的原因，见 3.3）；
- Filter Mode = **Bilinear**，让脚印边缘在纹理层面就是过渡的，避免锯齿；
- **Update Mode = On Load**：不做每帧自动清屏，这样脚印会一直留在纹理上，靠粒子自身的 Lifetime 消失，形成"人走过去脚印逐渐被雪填平"的效果。

**脚印相机** `footCamera` 的配置：

| 参数                | 值                            | 原因                                                            |
| ----------------- | ---------------------------- | ------------------------------------------------------------- |
| Projection        | Orthographic                 | 正交投影下世界 XZ 与纹理 UV 是线性对应，shader 里一次除法就能算 UV                    |
| Orthographic Size | 10                           | 覆盖 20 m × 20 m 的范围，够角色活动                                      |
| Transform         | 位置 (x, 50, z)，旋转 (90°, 0, 0) | 垂直向下俯拍                                                        |
| Culling Mask      | 只勾 Layer 3                   | 相机只"看得见"脚印粒子，不渲染地形/角色，省性能                                     |
| Background Type   | **Uninitialized**            | 对应旧版的 Clear Flags = Nothing / Don't Clear，即**不清屏**，上一帧的脚印得以保留 |
| Target Texture    | `snowfootwrite`              | 渲染结果直接写进脚印纹理                                                  |

#### 2.3 创建粒子系统

粒子系统 `Particle System` 挂在玩家下面，用来"画"脚印。

| 参数                             | 值         | 原因                                                  |
| ------------------------------ | --------- | --------------------------------------------------- |
| GameObject Layer               | 3         | 与脚印相机的 Culling Mask 对应，这是两边唯一的约定                    |
| Start Speed                    | 0         | 粒子发射后原地不动，只标记"这里踩过一脚"                               |
| Start Size                     | 0.4       | 脚印大小（米）                                             |
| Start Lifetime                 | 2         | 2 秒后粒子消失，脚印随之淡去                                     |
| Play On Awake + Looping        | 开启        | 常驻运行，由脚本用 `Emit` 手动发射，不自动喷发                         |
| Render Mode                    | Billboard | 用最简单的四边形面片承载脚印                                      |
| **Render Alignment**           | **World** | 面片对齐**世界坐标轴**、固定在世界空间里，不随相机转动而转身                    |
| 3D Rotation + Start Rotation X | 开启 / −90° | Alignment = World 时面片默认直立（法线朝 +Z），绕 X 转 −90° 躺平到地面上 |
| Max Particle Size              | 0.07      | 渲染器对 billboard 的屏幕占比上限，0.4 m 在这个范围内，不会被裁掉           |

粒子材质沿用 URP 自带的 `ParticlesUnlit`，不参与光照，写进纹理的就是干净的白点。

#### 2.4 在角色脚本里发射脚印

`Assets/脚本/footprints.cs` 做两件事：**按距离发射粒子**和**把脚印相机贴到角色头顶**。

```csharp
public ParticleSystem footPS;       // 粒子系统
public float emitDistance = 0.5f;   // 每移动这么远留一个
public Transform footcam;           // 脚印相机

private Vector3 lastEmitPos;

void Update()
{
    // ① 相机始终位于角色正上方 50 m 处
    float3 position = transform.position;
    position.y = 50;
    footcam.position = position;

    // ② 每走 0.5 m 落一个脚印
    if (Vector3.Distance(transform.position, lastEmitPos) > emitDistance)
    {
        lastEmitPos = transform.position;
        EmitFootprint();
    }
}

void EmitFootprint()
{
    Vector3 footPos = transform.position;
    footPos.y += 0.01f;   // 略微抬高，避免和地面重叠

    footPS.Emit(new ParticleSystem.EmitParams { position = footPos }, 1);
}
```

几个要点：

- **按距离而不是按时间发射**：用 `Vector3.Distance(当前位置, 上次发射位置) > emitDistance` 判断，走多快脚印都是每 0.5 m 一个，密度稳定；如果用时间间隔，跑起来脚印会拉稀。
- **`Emit(EmitParams, 1)`** 手动发射一颗粒子，并直接指定它的世界坐标，这样脚印就精确落在脚底，不受粒子系统 Transform 的影响。
- **`footcam.position` 每帧被覆盖**：相机是场景根物体，位置和旋转都由这里保证，等于让它"跟着角色平移但永不旋转"。
- y 取 50 是常量而非"角色高度 + 偏移"。地形是平面，相机高度固定即可；它同时决定了 shader 里 20 m 的采样窗口落在哪里。

#### 2.5 相机渲染：把粒子写进纹理

相机是 URP 相机，需要勾选 `Universal Additional Camera Data` 才是完整配置。它每帧做的事：

1. 从 `Background Type = Uninitialized` 开始（不清屏，保留上一帧内容）；
2. 遍历 Layer 3 —— 只有脚印粒子；
3. 正交投影，把角色周围 20 m × 20 m 的脚印粒子按世界坐标画成纹理上的对应位置；
4. 结果写进 `snowfootwrite`。

因为相机的 X、Z 每帧跟着角色走，所以纹理是一张**跟随玩家的滚动地图**：纹理中心始终是角色所在的位置，`(u, v)` 与以角色为中心的世界坐标一一对应。

#### 2.6 把相机范围传给 shader

shader 必须知道"这张纹理覆盖的是世界上哪一块"，才能把世界坐标换算成 UV。这件事由 `Assets/渲染pass/heighmapRendererFeature.cs` 这个 Renderer Feature 在每帧的 `AddRenderPasses` 里完成：

```csharp
Camera camera = manager.orthoCamera;                  // HeightMapCameraManager 单例
Vector3 pos = camera.transform.position;
float halfSize = Mathf.Max(camera.orthographicSize, 0.001f);   // 防止为 0

Vector4 cameraParams = new Vector4(pos.x, pos.z, halfSize, 0);
Shader.SetGlobalVector("_HeightMapCameraParams", cameraParams);
Shader.SetGlobalTexture("_TerrainHeightMap", _heightRT);
renderer.EnqueuePass(_pass);
```

- `_HeightMapCameraParams.xy` = **相机中心的 world XZ**
- `_HeightMapCameraParams.z` = **正交半尺寸**（即 Orthographic Size = 10）

相机对象通过 `HeightMapCameraManager` 单例获取，而不是在 Feature 的 Inspector 里直接拖引用 —— 这样即使 Renderer 资源被重新赋值，引用也不会丢。

#### 2.7 曲面细分：给位移准备顶点密度

顶点位移要能看出来，网格必须足够密。`Assets/材质/snowshader.shader` 的地形平面本身顶点很稀，所以第一个 Pass 用 hull/domain 着色器做**自适应曲面细分**：

```hlsl
#pragma vertex vert
#pragma hull HullProgram
#pragma domain DomainProgram
#pragma fragment frag
#pragma target 4.6
```

- `#pragma target 4.6` 是前提：低于它编译器不认 hull/domain 阶段。
- `PatchConstantFunc` 按**到相机的距离**决定细分等级：近了 8 级，远了降到 2 级（`lerp(8.0, 2.0, saturate(dist / 50.0))`），远处的三角形不浪费性能。
- 三条边的因子取两端点等级的**较小值**，保证相邻 patch 边界等级一致，不会出现裂缝。
- `partitioning("fractional_odd")` 让不同等级之间平滑过渡。

真正的位移发生在这里：`HullProgram` 只把控制点原样传下去，**所有新生成顶点的插值和位移都在 `DomainProgram` 里做**。

#### 2.8 shader 采样脚印纹理

Domain 阶段先用重心坐标插值出世界坐标、UV、法线、切线，再算脚印 UV：

```hlsl
// 世界 XZ → 脚印纹理 UV
float2 rangeMin  = _HeightMapCameraParams.xy - _HeightMapCameraParams.z;
float2 rangeSize = _HeightMapCameraParams.z * 2.0;          // 相机尺寸 × 2 = 覆盖边长
float2 footUV    = (positionWS.xz - rangeMin) / rangeSize;

// 超出相机覆盖范围：直接原样输出，不采样
if (any(footUV < 0.0) || any(footUV > 1.0))
{
    OUT.positionWS  = positionWS;
    OUT.positionCS  = TransformWorldToHClip(positionWS);
    OUT.normalOS    = normalOS;
    OUT.tangentOS   = tangentOS;
    OUT.uv          = uv;
    OUT.screenUV    = screenUV;
    return OUT;
}

float2 footTexelSize = rangeSize / 1024.0;   // 一个纹素对应的世界尺寸，与纹理 1024×1024 对应

// 中心 + 上下左右共 5 次采样
float footCenter = SAMPLE_TEXTURE2D_LOD(_footprintsMap, sampler_footprintsMap, footUV, 0).r;
float footL = SAMPLE_TEXTURE2D_LOD(_footprintsMap, sampler_footprintsMap, footUV - float2(footTexelSize.x, 0), 0).r;
float footR = SAMPLE_TEXTURE2D_LOD(_footprintsMap, sampler_footprintsMap, footUV + float2(footTexelSize.x, 0), 0).r;
float footD = SAMPLE_TEXTURE2D_LOD(_footprintsMap, sampler_footprintsMap, footUV - float2(0, footTexelSize.y), 0).r;
float footU = SAMPLE_TEXTURE2D_LOD(_footprintsMap, sampler_footprintsMap, footUV + float2(0, footTexelSize.y), 0).r;

// 到这里采样的活干完了。位移和法线重建放在 2.9，
// 因为它们需要先有世界空间的法线/切线基。
```

两个细节：

- **越界必须提前 return**。纹理 Wrap Mode 是 Clamp，越界采样会把边缘像素拉成一整条长条，地平线附近会莫名出现一条沟。所以在采样前就判断并原样输出。
- **用 `SAMPLE_TEXTURE2D_LOD(..., 0)` 而不是普通采样**：domain 阶段没有屏幕空间导数，隐式 LOD 采样会报错，必须显式指定 mip 0。

> 注意这里的执行顺序：**先采样、再建基、后位移**。采样用的 `footUV` 必须由**位移前**的 `positionWS.xz` 算出来，拿位移后的坐标去算 UV 会形成"位移 → UV 漂移 → 高度变化 → 位移再变"的正反馈，画面上表现为脚印抖动或"爬行"。

#### 2.9 沿法线位移，并在切平面上重建法线和切线

只压顶点而不改法线，脚印在光照下会看着还是平的。而且位移本身也不该写死世界 Y——地形一旦有坡度，代码就错了。所以这一段做三件事：**构造正交的切平面基 → 沿原法线位移 → 在切平面里扰动法线**。

顺序不能换：位移必须用**扰动前**的法线，否则"位移依赖法线、法线又依赖位移"成了循环依赖。

```hlsl
// ① 原法线 / 切线（世界空间），构造正交单位基 T、B、N0
float3 normNormalOS  = normalize(normalOS);
float3 normTangentOS = normalize(tangentOS.xyz);

float3 N0_ws = TransformObjectToWorldNormal(normNormalOS, true);
float3 T_ws  = TransformObjectToWorldDir(normTangentOS, true);

// Gram-Schmidt：把切线拉回与法线垂直的平面
T_ws = normalize(T_ws - dot(T_ws, N0_ws) * N0_ws);

// 副切线：单位正交向量叉乘，长度必为 1；tangent.w 只取符号
float tangentSign = (tangentOS.w >= 0.0) ? 1.0 : -1.0;
float3 B_ws = cross(N0_ws, T_ws) * tangentSign;

// ② 中心差分求梯度：hx = ∂f/∂x，hz = ∂f/∂z（斜率，无量纲）
float hx = (footR - footL) / (2.0 * footTexelSize.x);
float hz = (footU - footD) / (2.0 * footTexelSize.y);

// ③ 位移：沿原法线往下压，clamp 防止大缩放把三角形顶翻
float depth = min(footCenter * _DepthScale, _MaxDepth);
positionWS -= N0_ws * depth;

// ④ 法线扰动：N ∝ N0 + s·(hx·T + hz·B)，零梯度时严格退化为 N0
float3 N_ws = normalize(N0_ws + (hx * T_ws + hz * B_ws) * _DepthScale);

// ⑤ 转回物体空间；切线只按法线的变化量偏转，零扰动时严格不变
float3 newNormalOS  = TransformWorldToObjectNormal(N_ws, true);
float3 newTangentOS = normalize(normTangentOS
                      - dot(normTangentOS, newNormalOS - normNormalOS) * newNormalOS);
```

几个要点：

- **位移沿 `N0_ws`，不是世界 Y。** 平面地形上两者等价，但写成沿法线之后，雪坡、路堤、任意朝向的面用的是同一段代码。`depth > 0` 表示下凹，所以是 `-=`。`_DepthScale` 的物理含义是"mask = 1（踩实）时下压多少米"，默认 0.5，所以 `depth` 的单位是米。
- **梯度取正值，扰动项也用 `+`。** 位移是 `h = −depth`（向下），代进通用式 `n' = N − h_ξ·T − h_η·B` 时两个负号抵消，最后落在法线上的就是 `+_DepthScale·(hx·T + hz·B)`。符号写反的表现是"坑看起来像凸起"，灯光一扫立刻露馅。
- **`_DepthScale` 同时缩放位移和法线扰动。** 几何深度和明暗对比共用一个系数，调参时只有一个旋钮，不会出现"几何是 1 倍、法线是 2 倍"这种两套手感（早期版本就踩过这个坑，见 2.9.1 第四节）。
- **`_MaxDepth` 是一道保险。** 粒子重叠、反复踩踏都可能让 mask 冲到 1 以上，`mask × _DepthScale` 在大尺寸物体上足以把顶点推出面片之外，出现破洞和翻转的三角形。clamp 之后最坏情况只是"脚印不再变深"。
- **T 必须正交化，B 必须用 `cross(N, T)`。** 片元里重建法线贴图的 TBN 就是这么定义的，扰动方向必须落在同一套基上，否则"几何凹陷的方向"和"贴图凹凸的方向"会差出一个角度。
- **在"原法线"上做叠加，而不是整体替换**。没有脚印的地方梯度为 0，`N_ws` 与 `N0_ws` 完全相等，`newNormalOS` 与 `normNormalOS` 逐位相同——这套系统在"没有脚印"时是**零侵入**的，不改变地形原有的造型和着色。有脚印时，坡度只是叠在原法线上的一层扰动，网格起伏、法线贴图的效果都保留。
- **切线要重新正交化**。法线变了之后原来的切线不再垂直，会影响法线贴图的 TBN 变换，所以减去切线在新法线方向上的分量。`tangentOS.w`（副切线符号）原样保留。
- 全部在**物体空间**交接给片元，`TransformWorldToObjectNormal(x, true)` 的第二个参数表示对归一化法线做非等比缩放修正。

#### 2.9.1 为什么写成"沿法线位移 + 切平面扰动"，以及梯度到底怎么算

**一、位移为什么沿法线，而不是 `positionWS.y -= h`**

早期版本写的是 `positionWS.y -= footCenter * 0.5`。它能用，是因为地形是一块朝上的平面，法线正好是 (0,1,0)——**沿世界 Y 下沉和沿法线下沉是一回事**，白省一次矩阵变换。但这个写法绑死了"平面地形"这个前提，挪到雪坡上就变成了"斜着往下切"。

改成沿法线之后，三条纪律必须守住：

1. **用位移前的法线（`N0_ws`）。** 不能用叠加了脚印坡度的 `N_ws`——那会变成"位移依赖法线、法线又依赖位移"的循环依赖。
2. **采样 UV 必须用位移前的 `positionWS.xz`。** 否则采样点随位移漂移，形成正反馈：位移 → UV 移动 → 高度值变化 → 位移再变，表现为画面抖动或脚印"爬行"。
3. **位移之后要重新算 `TransformWorldToHClip(positionWS)`，用新的位置。**

**二、沿法线位移之后，法线也必须重建（推导）**

位移改了表面，原法线就不再垂直于新表面，必须重建。严格推导一遍：

把位移后的表面写成 `S(ξ, η) = P(ξ, η) − h(ξ, η)·N`，其中 ξ、η 是切平面上沿切向量 `T`、`B` 的两个坐标，`h` 是沿 `N` 的位移量（正数表示内凹、负数表示外凸）。对两个方向求偏导再叉乘，忽略底面本身的曲率项：

```
S_ξ ≈ T − h_ξ·N ,     S_η ≈ B − h_η·N
n'  = normalize(S_ξ × S_η) = normalize(N − h_ξ·T − h_η·B)
```

这就是高度场法线的**通用形式**，它不要求表面是平的，也不要求 `T`/`B` 恰好是世界 X/Z——**代码第 ④ 步就是这条式子**，只不过把 `h_ξ`、`h_η` 换成了对 mask 的偏导再乘 `_DepthScale`（因为 `h = −_DepthScale·f`，负号又和式中的减号抵消，所以代码里是 `+`）。

代入平面的情形（`N = (0,1,0)`、`T = (1,0,0)`、`B = (0,0,1)`），它退化成：

```
n' = normalize(−∂h/∂x, 1, −∂h/∂z)
```

**三、早期那个 `max(baseNormalWS.y, 1e-4)` 为什么被换掉了**

旧写法是：

```hlsl
// 已废弃
float3 N_ws = normalize(baseNormalWS + float3(-dhdx, 0.0, -dhdz) * max(baseNormalWS.y, 1e-4));
```

两个问题：

- **扰动方向写死在世界 XZ 上**，和表面实际朝向无关。地形一旦倾斜，坑壁该倒的方向和实际倒的方向会差一个角度，坡度越大差得越离谱。
- **`max(N.y, 1e-4)` 是个补丁。** 它的本意是"让竖直面不被地面坡度带歪"，效果上相当于把扰动按法线的水平程度衰减。但它同时把陡坡上的脚印明暗也一起压掉了——雪坡上的凹坑会看起来越来越平。

换成切平面基之后，这两件事都不需要补丁：扰动整个落在由 `T`、`B` 张成的平面内，法线永远只在表面内部倾倒，不会把面拽离表面；竖直面的 `T`/`B` 本来就在竖直平面里，扰动自然也是对的。缩放系数也换成了有物理含义的 `_DepthScale`（米），和位移共用一个值。

> 符号方向取决于 `T`/`B` 的手性（`tangent.w` 只在构造 `B` 时作为符号使用，叉乘出来的 `B` 长度必为 1）。实用校验方法：让主光绕地形转一圈，看脚印的凹凸是否"跟着光走"——凸起朝向光源的一侧应该更亮；如果整体反了，把 `T`/`B` 那一项的符号取反即可。

**四、梯度到底怎么算**

梯度是高度 `h(x, z)` 对世界坐标的两个偏导 `(∂h/∂x, ∂h/∂z)`，**单位是"米 / 米"，无量纲**——只有无量纲的斜率才能直接和法线的分量相加。整个换算链有三步：

**第 1 步：确定采样间距。**
脚印图是从正交相机拍的，一个纹素对应的世界尺寸：

```
texelWorld = 2 × orthographicSize / 分辨率 = 2 × 10 / 1024 ≈ 0.0195 m
```

**第 2 步：用中心差分求导。** 纹理里只有离散纹素，导数只能用差分近似：

```
∂h/∂x ≈ ( h(x + Δ) − h(x − Δ) ) / (2Δ) ,    Δ = texelWorld
```

- 左右各偏**一个纹素**，所以两点间距是 `2Δ`，不是 `Δ`，也不是 `2`。
- 中心差分是**二阶精度**，左右对称；前向差分 `(h(x+Δ) − h(x))/Δ` 是一阶精度，会让凹陷边缘的明暗整体偏到一侧。
- 想要更平滑可以对高度图先用 3×3 的 Sobel 或高斯预平滑，但代价是脚印边缘变钝。

**第 3 步：把 mask 换算成"米"的位移量。** 纹理里存的是 0~1 的脚印 mask `f`，不是米。真正沿法线的位移是 `depth = _DepthScale · f`（默认 0.5，再 clamp 到 `_MaxDepth`），也就是 `h = −_DepthScale · f`，所以：

```
∂h/∂x = −_DepthScale · ( f(x + Δ) − f(x − Δ) ) / (2Δ)
```

代码里把两步分开了：`hx`、`hz` 是对 **mask** 的中心差分（第 2 步算出来的斜率），乘 `_DepthScale` 之后才等价于 `∂h/∂x`：

```hlsl
float hx = (footR - footL) / (2.0 * footTexelSize.x);            // ∂f/∂x
float depth = min(footCenter * _DepthScale, _MaxDepth);           // 位移（米）
float3 N_ws = normalize(N0_ws + (hx * T_ws + hz * B_ws) * _DepthScale);
```

**这里最典型的错法是漏掉尺度系数，或者位移和法线各用一个。** 早期的实现里位移用 `× 0.5`、法线扰动用 `× 1`，等价于"法线比几何陡一倍"，视觉上反而讨喜（纯几何算出来的法线在掠射光下几乎看不出凹陷），但那是个隐式的手感参数，一旦改了深度，凹凸强度不会跟着变。现在两处共用 `_DepthScale`，改一个旋钮，几何深度和明暗对比同步变化。

**符号自检**：因为 `h = −s·f`（`s = _DepthScale > 0`），所以 `∂h/∂x = −s·∂f/∂x`，代进 `n' = normalize(N − h_x·T − h_z·B)`：

```
n' ∝ N + s·(∂f/∂x)·T + s·(∂f/∂z)·B
```

即 `N + s·(hx·T + hz·B)`——和代码第 ④ 步逐项一致。在坑的右壁（`∂f/∂x < 0`）扰动把法线往 `−T` 方向推，法线朝坑的中心倒，符合直觉。

**边界情况**：越界的纹素不能采样。Wrap 是 Clamp 的话，`footUV` 出界会拿到边缘那一行像素，梯度就变成了一条凭空出现的斜坡。所以在算 UV 之后、采样之前就要 early return（见 3.3）。

#### 2.10 光照与着色

片元阶段重建 TBN、采样法线贴图，然后走自定义光照：

```hlsl
float3 bitangentOS = cross(normalOS, tangentOS) * IN.tangentOS.w;
float3x3 TBN_object = float3x3(tangentOS, bitangentOS, normalOS);

half3 normalTS = UnpackNormal(SAMPLE_TEXTURE2D(_NormalMap, sampler_NormalMap, IN.uv));
float3 normalWS = TransformObjectToWorldNormal(normalize(mul(normalTS, TBN_object)));

float4 shadowcoord = TransformWorldToShadowCoord(IN.positionWS);
Light mainLight = GetMainLight(shadowcoord);

float3 color = My_CookTorrance(normalWS, V, L, mainLight.color,
                               basecolor, 0, _Roungness) * mainLight.shadowAttenuation;

color += GlossyEnvironmentReflection(reflectVector, IN.positionWS, _Roungness, 1.0, IN.screenUV)
       * SAMPLE_TEXTURE2D(_AOMap, sampler_AOMap, IN.uv).r;
```

- 直接光用自己写的 **Cook-Torrance**（GGX 法线分布 + Smith 几何项 + Schlick 菲涅尔），所有函数加 `My_` 前缀避免和 URP 库重名。
- 阴影走 `TransformWorldToShadowCoord` + `GetMainLight(shadowcoord)`，由 `#pragma multi_compile _ _MAIN_LIGHT_SHADOWS _MAIN_LIGHT_SHADOWS_CASCADE _MAIN_LIGHT_SHADOWS_SCREEN` 三个关键字控制。
- 间接光用 `GlossyEnvironmentReflection` 采样反射探针，再乘 AO 贴图，兼顾雪地对天空的反射。

#### 2.11 附：地形高度图烘焙（当前未启用）

`Assets/渲染pass/` 下另有一套按同样思路做的**地形高度图烘焙**链路，作为后续扩展预留：

- `snowshader.shader` 的第二个 Pass 打了 `Tags { "LightMode" = "HeightMap" }`，片元直接把 `positionWS.y` 写进 R 通道；
- `heighmapRenderPass.cs` 用 `ShaderTagId("HeightMap")` 建 RendererList，在 `BeforeRenderingOpaques` 阶段把地形高度渲染进一张 `RFloat` 的 `RenderTexture`（1024 × 1024）；
- 结果通过 `_TerrainHeightMap` 全局纹理暴露给 shader。

### 3. 踩坑记录

这一节按"踩到的顺序"记录，重点放在**从脚印图/高度图里求梯度并重建法线**这一段——它是整个方案里唯一一处"数学必须写对、否则肉眼立刻能看出来"的地方。

#### 3.1 切线方向错了：法线是对的，但法线贴图被"镜像"了

这里记录的是法线重建阶段真正踩到的坑——**问题不在法线，在切线**。

现象很迷惑人：加完这套系统之后，地形的几何轮廓、大块明暗关系全都对，但**法线贴图的细节反了**——雪面的颗粒看起来像是被"抠"进去而不是凸出来，主光换个方向时，这些细节的亮暗还跟着错位；脚印边缘偶尔会有一圈方向不对的高光。

定位过程：

1. **先怀疑法线。** 把 `N_ws` 临时换成 `N0_ws`，异常消失——但这只能说明"扰动参与了计算"，不能说明扰动本身算错了。
2. **再单独可视化 TBN 的三个基向量。** 把法线、切线、副切线分别当颜色输出，一眼就能看出来：法线和模型自带的一致，**切线不对**。
3. 切线一错，`B = cross(N, T) * tangent.w` 跟着错，整个 TBN 成了镜像系。片元里 `mul(normalTS, TBN)` 会把法线贴图里每个像素的某个分量翻个号——**凹凸就反了**。

**为什么切线容易出错**：切线的方向只有一个合法来源，就是模型 UV 展开时的那套方向——美术烘法线贴图时用的是同一个方向，DCC 导出时写进顶点的是同一个方向，Unity 导入时算出来的也必须是同一个方向。常见的几种错法：

- 自己拿高度场梯度去构造切线（比如 `T = normalize(1, footR - footL, 0)`），它和 UV 的 U 方向根本不是一回事；
- 叉乘顺序写成 `cross(T, N)` 而不是 `cross(N, T)`，副切线整体反号；
- 忘记乘 `tangent.w`（副切线符号，处理 UV 镜像过的手性）；
- 想当然地对 `normalTS.xy` 做 `(-x, y)` 之类的"修正"，反而把它改错了。

**正确的做法是让法线和切线各守自己的来源**：

|     | 来源    | 能不能自己构造               |
| --- | ----- | --------------------- |
| 法线  | 几何    | 可以——在模型法线上、沿切平面叠加脚印坡度 |
| 切线  | UV 展开 | **不能**，只能跟着法线做正交化     |

```hlsl
float3 newNormalOS  = TransformWorldToObjectNormal(N_ws, true);
float3 newTangentOS = normalize(normTangentOS
                      - dot(normTangentOS, newNormalOS - normNormalOS) * newNormalOS);
```

这里用"新法线 − 旧法线"的差作为偏移方向，而不是直接对 `newNormalOS` 做投影——这样在零扰动时（`newNormalOS == normNormalOS`）减去的项恰好是 0，切线**严格不变**。`tangentOS.w`（副切线符号）原样保留，不要在这里重新算符号。

顺带一提，法线一侧的写法是：

```hlsl
float3 N_ws = normalize(N0_ws + (hx * T_ws + hz * B_ws) * _DepthScale);
```

扰动项整个落在 `T`、`B` 张成的切平面里，所以法线只在**表面内部**倾倒，不会把面拽离表面；竖直面也天然不会被地面的坡度带歪。早期版本用的是 `baseNormalWS + (−dhdx, 0, −dhdz) · max(baseNormalWS.y, 1e-4)`——扰动写死在世界 XZ 上、再拿法线的 y 分量当补丁，只有"平面地形"时才近似成立，现已替换（对照见 2.9.1 第三节）。

**这条坑的结论**：法线决定"表面朝哪"，切线决定"法线贴图怎么摆"，这是两个独立的自由度，改一个必须检查另一个。反过来说，凡是出现"几何看起来是对的，但贴图细节反了 / 镜像了"的现象，第一反应应该是查 TBN，而不是查法线。

#### 3.2 梯度的量纲必须换算到"每米"

这是整个法线重建里最容易写错的一处，而且错了不会报错，只是"效果看着怪"。

脚印图是正交相机拍的，一个纹素对应的世界尺寸是：

```
texelWorld = 2 × orthographicSize / 1024 = 2 × 10 / 1024 ≈ 0.0195 m
```

中心差分用的是左右各偏**一个纹素**的两个样本，两点间距是 `2 × texelWorld`，所以斜率必须是：

```hlsl
float2 footTexelSize = rangeSize / 1024.0;           // 一个纹素对应的世界尺寸，单位：米
float  hx = (footR - footL) / (2.0 * footTexelSize.x);   // 斜率，无量纲
float  hz = (footU - footD) / (2.0 * footTexelSize.y);
```

分母必须是 **`2 × 纹素世界尺寸`**：既不能省掉那个 `2`（左右各偏一个纹素，两点间距是 `2Δ`），也不能直接拿 UV 空间的距离（`1/1024`）当分母。我第一次就写错了分母，斜率整体偏了几十倍，脚印边缘出现一圈塑料质感的高光和不合物理的亮边——**量纲错一个常数，视觉上表现为"材质变了"，几乎不可能从现象反推到除法上**。

> 顺带记一笔这里容易混淆的单位：**采样偏移是 UV 空间的量**（一个纹素 = `1/1024`），**分母是世界空间的距离**（`2 × 0.0195 m`）。两者数值差约 20 倍，混用不会报错，只会让脚印边缘"糊掉一片"。当前代码把同一个 `footTexelSize`（米）同时当作采样偏移和分母，属于可接受的近似，精确写法应另设一个 `footTexelUV = 1.0 / 1024.0` 用于偏移。

#### 3.3 越界采样：地平线上出现一条莫名其妙的沟

纹理 Wrap 是 Clamp，而脚印相机只覆盖玩家周围 20 m。远处地形算出来的 `footUV` 是负的或大于 1，采样到的是纹理最边缘的那一行/列像素，等于把一个像素拉成了几百米长的条带，地平线附近就会横着一条不属于任何东西的沟。

改法是在 domain 阶段算完 UV 立刻判断，越界就原样输出并 return：

```hlsl
if (any(footUV < 0.0) || any(footUV > 1.0)) { /* 原样输出，直接 return */ }
```

顺带的好处是：相机窗口之外的地形**一个采样都不做**，天然就有了按范围裁剪的开销控制，这也是当前方案里最有效的一条性能边界。

#### 3.4 domain 阶段没有屏幕空间导数，采样必须显式指定 LOD

在 domain 里写 `SAMPLE_TEXTURE2D(...)` 会编译失败，或者采样结果全黑。原因是 domain/geometry 阶段没有 `ddx/ddy`，隐式求导的采样算不出 mip 级别。所有这里的采样都要写成：

```hlsl
SAMPLE_TEXTURE2D_LOD(_footprintsMap, sampler_footprintsMap, footUV, 0)
```

同样的原因，法线贴图、AO 贴图不要挪到 domain 去采——它们既没必要（位移用不到），也徒增开销，留在片元里按插值后的 UV 采即可。

#### 3.5 曲面细分的三个细节

- **`#pragma target 4.6` 是硬前提。** 低于这个 target，hull/domain 会被编译器直接丢掉，shader 静默退回普通顶点着色器——表现是"位移完全没效果"，而且不报任何错。这个坑排查了很久，因为从表面看像是纹理没写进去。
- **位移只能在 domain 做。** 如果在 hull 里改控制点，位移量会被 domain 再次插值，等于把位移摊平了，不同 patch 的接缝处还会对不上。hull 的职责只有一件事：决定细分多少。
- **相邻 patch 的边因子必须一致。** 每条边的 tess factor 取它两端点计算结果的最小值，内部取最大值，再配合 `fractional_odd` 分区，才不会在细分等级的交界处出现裂缝和闪动的锯齿。等级本身按相机距离从 8 降到 2，远处的三角形不浪费。

#### 3.6 正交相机不能在 Renderer Feature 里直接拖引用

Renderer Feature 本身是资源，Inspector 里拖进去的相机引用会在资源重载、切分支、换机器时丢掉，表现为"忽然没有脚印了"，而且不报错。改成通过 `HeightMapCameraManager.Instance` 单例拿相机，并在 `AddRenderPasses` 里做空判断——相机不存在就直接 return，不抛异常。

### 4. 技术总结

#### 4.1 方案的本质

把"角色与地形的交互"这个看起来偏逻辑的问题，转换成一个**纯图形问题**：

> 用一个正交相机把"交互"画成一张高度图，再让地形着色器把这张图读回来做顶点位移。

整个方案里没有任何一处需要 CPU 知道"地面上现在有几个脚印"。这个转换是整套设计成立的根本原因，也是它容易被扩展的原因——**任何能画进这张纹理的东西，都能驱动地形**：脚印、车辙、爆炸坑、血迹、被踩塌的雪檐。

#### 4.2 三个关键设计决策

| 决策          | 选择                       | 收益                                        |
| ----------- | ------------------------ | ----------------------------------------- |
| 交互数据怎么进 GPU | 粒子 + 正交相机写 RenderTexture | 交互源与地形解耦；粒子系统白送生命周期、淡出、累积混合，不用手写"雪被填平"的逻辑 |
| 位移发生在哪一步    | Domain 阶段（而非顶点/片元）       | 顶点密度可按距离自适应，近处 8 级、远处 2 级；远处几何成本不变        |
| 位移与法线怎么来    | 沿原法线位移；扰动落在切平面 `T`/`B` 内 | 不绑定"平面地形"，任意朝向的面都成立；零扰动时严格退化为原法线，对原渲染零侵入  |

#### 4.3 各阶段的实际开销

| 阶段               | 频率                    | 代价                                                                            |
| ---------------- | --------------------- | ----------------------------------------------------------------------------- |
| 粒子发射             | 每移动 `emitDistance` 一次 | 一次 `Emit`                                                                     |
| `footCamera`     | 每帧                    | 一次 1024² 正交渲染，只画 Layer 3（通常几十个面片）                                             |
| Renderer Feature | 每帧                    | 两次全局 uniform 写入（`_HeightMapCameraParams` / `_TerrainHeightMap`），无额外 draw call |
| 地形 Domain        | 每个细分后顶点               | 5 次纹理采样（含越界早退）；无脚印区域 0 次                                                      |
| 地形 Fragment      | 每个像素                  | 与原有效果相同（Cook-Torrance + IBL），无新增开销                                            |

结论：**新增成本集中在顶点阶段，且被"相机窗口"和"距离降级"两把尺子限制住了**，这是这个方案能在实时场景里跑起来的原因。

#### 4.4 收获

- **法线/切线是"解释空间"的一部分，不是自由变量。** 法线决定表面朝哪，切线决定法线贴图怎么摆，两者相互独立。我这次栽在切线上：法线没错，但切线被换成了按高度场构造的方向，TBN 变成镜像系，整张法线贴图的凹凸都反了。教训很直接：改法线的时候，先问一句"这张法线贴图原本是相对谁定义的"，再问一句"我动它的时候，切线守住了没有"。
- **纹理与世界的量纲换算必须显式写出来。** 从纹理空间取数再驱动世界空间时，正确做法是把 `texelWorldSize` 算成一个命名变量并参与推导，而不是靠"看起来差不多"来调参数。量纲错一个常数，表现为材质不对，几乎无法从现象反推。
- **可编程渲染管线的接入方式。** 掌握 Renderer Feature + `ScriptableRenderPass` + RenderGraph 的 `AddRasterRenderPass` 写法；理解了为什么这里可以直接用 `cam.projectionMatrix` 而不用 `GL.GetGPUProjectionMatrix`（目标是一张 2D 纹理、不涉及平台相关的 y 翻转和深度区间），以及为什么绘制后必须把 view/projection 矩阵还原，否则会污染主相机的后续 pass。
- **曲面细分各阶段的职责边界。** hull 决定细分多少、domain 生成顶点并做插值，位移只能发生在 domain。。

#### 4.5 结果

- 1024 × 1024 RFloat 高度图，约 4 MB 显存，跟随角色滚动，覆盖周围 20 m × 20 m；
- 单个顶点额外 5 次采样，无脚印区域零采样、零细分损失；
- 细分等级 2 ~ 8 随距离平滑过渡，接缝无裂缝；
- 位移与法线扰动共用 `_DepthScale`（默认 0.5），并由 `_MaxDepth`（默认 0.2 m）兜底，极值下不会翻面；
- 脚印密度由"每 0.5 m 一次"控制，与移动速度无关；
- 脚印的消退完全由粒子 Lifetime 驱动，没有额外的清理逻辑。

### 5. 改进方向

#### 5.1 当前方案的局限

先把问题说清楚，改进才有方向：

1. **拿渲染管线当计算用。** 为了往纹理里画几十个白点，每帧要跑一整条相机渲染；内容绝大多数时候不变，成本却是固定的。
2. **交互数据没有持久化。** 高度图始终只覆盖角色周围 20 m，走出这个范围，旧脚印就永远丢了。想要"整张地图的踩踏记录"做不到。
3. **表达力只有"高度"一个通道。** 想表达方向（脚印朝向）、边缘隆起、深度随速度变化，都要绕道。
4. **采样次数和细分半径都是偏保守的值**，可以再压。

#### 5.2 性能优化

1. **把 5 次采样降到 2 次。** 用 SM5.0 的 `GatherRed` 一次取回 2 × 2 个纹素，中心差分需要的左右上下四个点一次到位；中心点用 `Load`。采样指令从 5 条降到 2 条。
2. **更彻底的做法：预计算梯度。** 在生成高度图的同一趟里直接把 `(hx, hz)` 写进第二张 RG16F 纹理，地形着色器只采一次就能拿到法线扰动——domain 阶段的开销几乎归零。这需要 compute shader，见 5.4。
3. **细分范围裁剪。** 在 hull 阶段先用 patch 的包围盒和相机 20 m 的窗口做一次相交测试，不相交的 patch 直接把 tess factor 给 1。现在的做法是"细分完再在 domain 里早退"，等于先花了细分的钱才发现不用花。
4. **距离 LOD。** 超过约 25 m 直接关掉曲面细分，改用视差/法线贴图伪造凹陷，几何零成本。视觉上远处本来也分辨不出几何凹陷。
5. **脚印相机按需渲染 + 精简配置。** 一是"没人在动就不更新"：粒子系统空闲时不写新数据，脚印相机可以整帧跳过（注意 URP Asset 是按质量等级全局配置的，能按相机切换的是 Renderer / Universal Renderer Data，所以精简项要落在 Renderer 上：关阴影、关后处理、关 MSAA）。二是相机只画 Layer 3 的不透明几何，本来就已经排除了绝大部分场景物体。

#### 5.3 用高度图做 raymarch 自阴影

现在的阴影只来自主光的级联阴影贴图，分辨率和精度都不足以表达"脚印坑壁的自遮挡"这种厘米级效果。既然高度信息已经在一张图里，就可以在片元里做一次 **height-field ray march**：

```hlsl
// p：片元世界坐标；L：指向光源的单位向量
float3 p = positionWS + N * _RayBias;   // 沿法线偏移，避免自遮挡
float occlusion = 0.0;
for (int i = 0; i < STEPS; i++)
{
    p += L * _StepSize;
    if (any(p.xz < _HeightMapMin) || any(p.xz > _HeightMapMax)) break;   // 出界视为未遮挡
    if (p.y < SampleHeight(p.xz)) { occlusion = 1.0; break; }
}
```

这条链路的基础设施是现成的：`snowshader.shader` 的第二个 Pass 已经把 `positionWS.y` 写进了 R 通道，`heighmapRenderPass` 也已经把它渲染成一张 RFloat 纹理并通过 `_TerrainHeightMap` 暴露出来，只是当前没有启用（见 2.11）。

几个要点：

- **越界必须视为未遮挡**，否则边缘会出现一圈假的暗边。
- **步长和坑深要匹配。** 脚印是厘米级深度，步长取 1 ~ 2 个纹素（约 2 ~ 4 cm）就够；固定步进 16 ~ 24 步可以覆盖约 0.5 m 的影响半径。
- **用 Cone Step Mapping 加速。** 把每一步探测到的"离地表还有多高"当成安全步长，坑壁陡的地方步子小、平坦处步子大，通常 4 ~ 6 步就能收敛，比固定步进快一个数量级。
- **硬边要处理。** 单步采样的遮挡边界是硬的，可以用 2 ~ 4 次抖动采样再取平均，或者对结果做一次小半径的模糊，得到软阴影。
- **注意这是屏幕外数据。** URP 的实时阴影系统用不上，必须完全手写；同时因为它读取的是本 pass 之外的纹理，没有屏幕空间导数的限制和 3.4 一样，采样要显式指定 LOD。

#### 5.4 用 Compute Shader 重写整个形变系统

现在的链路是"**交互事件 → 粒子 → 相机 → 纹理**"，能跑，但有 5.1 说的那几个结构性限制。换成 Compute Shader 之后，链路变成：

```
交互事件（C#）
  └─ StructuredBuffer<FootprintStamp>   { worldXZ, dir, radius, depth, time }
       └─ Compute Shader（每次有新 stamp 时 Dispatch 一次）
            ├─ RWTexture2D<float>  _HeightTex   高度
            └─ RWTexture2D<float2> _GradTex     预计算的梯度 (hx, hz)
                 └─ 地形 shader：各采 1 次，拿到高度和法线扰动
```

能换来的东西：

- **完全脱离相机。** 不再需要 `footCamera`、不再需要 Layer 约定、不再有"跟着玩家跑的视窗"。高度图可以做全局的，按 tile 分块管理（比如 64 m 一块），玩家走多远脚印都在，这是 5.1 第 2 条的直接解法。

- **参数自由，能做出更精确的形状。** 每个 stamp 自带朝向和形状，可以做椭圆脚印、左右脚交替、深度随速度变化。之前提的"中间凹陷、两边突起"在这里只是一个解析表达式，不再需要靠粒子的混合模式硬凑：
  
  ```hlsl
  float pit   = -depth * (1.0 - smoothstep(0.0, r, d));                       // 中间凹陷
  float ridge =  ridgeH * exp(-pow((d - r * 0.85) / (r * 0.12), 2.0));        // 边缘隆起
  h += pit + ridge;   // RFloat 能存负值，这一步在 8 位纹理上是做不到的
  ```

- **梯度预计算。** 梯度在 compute 里一次算好写进 RG16F，地形 shader 的采样从 5 次降到 2 次，domain 阶段的开销接近归零（对应 5.2 第 2 条）。

- **可维护的衰减。** 脚印的"被雪填平"不再依赖粒子 Lifetime，而是一个随时间指数衰减的参数 `exp(-t / tau)`，可以做到先快后慢、不同深度不同速率，比"到时间就消失"自然得多。

- **成本模型更合理。** 从"每帧固定"变成"每次交互一次"，绝大多数帧的 dispatch 成本是 0。

- 

**代价也要说清楚**：需要自己管理 dispatch 时机与 tile 的加载卸载；需要 `AsyncGPUReadback` 才能把状态同步回 CPU（物理、存档）；`RWTexture2D` 的格式与随机写入在各平台上有兼容性差异；以及没了粒子系统，生命周期/淡出这些都要自己写。

但整体上，这是把这个系统从"一个能跑的 Demo"推到"一个能进项目的系统"的正确方向。
