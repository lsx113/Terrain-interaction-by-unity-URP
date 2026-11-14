# PRB-render-by-unity

基于 Unity 6 和 URP 的雪地交互演示项目。角色移动时通过粒子和正交相机生成脚印纹理，雪地着色器读取纹理，通过曲面细分、顶点位移和法线重建表现脚印凹陷。

## 环境要求

<!-- AUTO-GENERATED: environment; sources: ProjectSettings/ProjectVersion.txt, Packages/manifest.json -->
| 项目 | 当前配置 |
| --- | --- |
| Unity Editor | **6000.3.10f1** |
| Universal Render Pipeline | **17.3.0** |
| Input System 包 | **1.18.0** |
| Unity Test Framework | **1.6.0** |
| Unity Pipeline | 项目内嵌包 `Packages/com.unity.pipeline` |
<!-- /AUTO-GENERATED -->

雪地 Shader 使用 `#pragma target 4.6` 和 Hull / Domain 曲面细分阶段，需要支持相应功能的图形 API 与 GPU。项目同时包含 PC / Mobile 渲染配置；移动端兼容性需单独验证。

## 打开与运行

1. 克隆仓库：

   ```bash
   git clone https://github.com/lsx113/PRB-render-by-unity.git
   ```

2. 在 Unity Hub 中添加仓库根目录，使用 **6000.3.10f1** 打开，等待资源导入与包解析完成。
3. 打开 `Assets/Scenes/SampleScene.unity`，进入 Play 模式。
4. 点击 Game 窗口，用下表操作角色，观察雪地表面的脚印。

| 操作 | 按键 |
| --- | --- |
| 移动 | WASD / 方向键（`Horizontal`、`Vertical` 输入轴） |
| 旋转视角 | 按住鼠标右键并移动鼠标 |
| 拉近 / 拉远视角 | 鼠标滚轮 |

`PlayerMove` 和 `ThirdPersonCamera` 使用旧版 `UnityEngine.Input`。项目的 **Active Input Handling** 当前为 **Both**；修改输入配置时需保留旧输入系统支持。

构建时，在 Unity 的 Build Profiles 中选择目标平台并检查场景列表；当前已启用 `Assets/Scenes/SampleScene.unity`。本项目没有独立的命令行构建脚本。

## 目录说明

| 路径 | 用途 |
| --- | --- |
| `Assets/Scenes/` | 演示场景 |
| `Assets/脚本/` | 角色移动、第三人称相机、脚印发射与相机管理 |
| `Assets/渲染pass/` | 高度图 Renderer Feature 和 RenderGraph Pass |
| `Assets/材质/` | 雪地材质与 `snowshader.shader` |
| `Assets/snowTextures/` | 雪地贴图、脚印纹理及粒子材质 |
| `Assets/Settings/` | PC / Mobile URP Asset、Renderer 和 Volume 配置 |
| `Packages/` | 包依赖、锁定文件和内嵌 Unity Pipeline 包 |
| `ProjectSettings/` | Unity 版本、输入、图层及构建配置 |

`Library/`、`Temp/`、`Logs/` 等生成目录由 Unity 自动重建，已通过 `.gitignore` 排除。

## 场景配置

以下以仓库中的 `SampleScene` 为准。搭建新场景时，按顺序连接引用。

### 角色与观察相机

- 角色添加 `CharacterController` 和 `PlayerMove`，提供移动、重力和朝向更新。`cam` 留空时使用带 `MainCamera` Tag 的相机。
- 角色添加 `footprints`，将 `footPS` 指向脚印粒子系统，将 `footcam` 指向脚印相机的 Transform。
- 主相机添加 `ThirdPersonCamera`。`target` 留空时自动查找挂有 `PlayerMove` 的对象，也可手动指定。

<!-- AUTO-GENERATED: player; sources: Assets/Scenes/SampleScene.unity, Assets/脚本/footprints.cs -->
| 参数 | 示例场景值 | 说明 |
| --- | --- | --- |
| `PlayerMove.speed` | `5` | 移动速度 |
| `PlayerMove.gravity` | `-9` | 重力加速度 |
| `PlayerMove.turnSpeed` | `720` | 每秒最大转向角度 |
| `footprints.emitDistance` | **`0.1`** | 超过该移动距离后发射一次；脚本默认值为 `0.5` |
| `ThirdPersonCamera.distance` | `6` | 观察距离 |
| `ThirdPersonCamera.pivotOffset` | `(0, 1.6, 0)` | 观察中心相对角色的偏移 |
<!-- /AUTO-GENERATED -->

### 脚印相机与粒子

| 对象 / 参数 | 配置 |
| --- | --- |
| `footCamera` | 正交投影，Orthographic Size = `10`，覆盖约 `20 × 20 m` |
| 相机朝向 | 世界旋转 `(90, 0, 0)`，垂直向下 |
| 相机层级 | 示例场景为根对象，避免继承角色转身 |
| Culling Mask | 只渲染 Layer 3：`snowfoot` |
| Background Type | `Uninitialized`，对应不清屏 |
| Target Texture | `Assets/snowTextures/snowfootwrite.asset` |
| 粒子对象 Layer | `snowfoot`，与脚印相机一致 |
| 粒子渲染 | Billboard，Render Alignment = World |

`footprints.Update()` 每帧把脚印相机移动到角色的 XZ 坐标，并把世界 Y 固定为 `50`，不会修改旋转。粒子需使用世界空间模拟，使已发射的脚印保持在落点；关闭自动发射，由脚本按距离调用 `Emit`。

仓库另提供 `FootprintCameraLock`，用于在 `LateUpdate` 中锁定世界朝向并按相对高度跟随目标；示例场景未挂载该组件。接入时需注意它会在 `footprints.Update()` 之后再次覆盖相机位置。

### 脚印纹理与雪地材质

`Assets/snowTextures/snowfootwrite.asset` 是供相机写入的 Custom Render Texture，配置为 `1024 × 1024`、RFloat、Bilinear、Clamp，无 Mipmap。它与 Renderer Feature 运行时创建的 `HeightMapRT` 是两张不同纹理。

| 材质属性 | 用途 / 当前值 |
| --- | --- |
| `_BaseMap` | 雪地底色贴图 |
| `_NormalMap` | 雪地法线贴图 |
| `_AOMap` | 环境遮蔽贴图 |
| `_footprintsMap` | 绑定 `snowfootwrite.asset`，读取脚印强度 |
| `_Roungness` | 粗糙度，`雪地.mat` 当前为 `1`；属性名保留代码中的拼写 |
| `_DepthScale` | 位移与法线扰动强度，Shader 默认 `0.5`，范围 `0–2` |
| `_MaxDepth` | 最大下压深度，Shader 默认 `0.2 m`，范围 `0–1` |

把 `Assets/材质/雪地.mat` 赋给需要交互的网格。几何凹陷由 Shader 在 GPU 上生成，不会同步修改 `CharacterController` 使用的地面碰撞体。

> 不清屏会保留纹理内容，粒子 Lifetime 只控制粒子存活时间，不能保证已写入的脚印自动消退。当前脚本没有纹理衰减或滚动重投影逻辑；需要定时恢复或长期保存脚印时，应另行实现。

### Renderer Feature

1. 在场景对象上添加 `HeightMapCameraManager`，将 `orthoCamera` 指向 `footCamera`。
2. 使用 `Assets/Settings/PC_RPAsset.asset` 及其 `PC_Renderer.asset`；后者已经包含 `heighmapRendererFeature`。
3. 保持 URP RenderGraph 路径，该自定义 Pass 实现的是 `RecordRenderGraph`。

| Feature 参数 | 当前配置 | 说明 |
| --- | --- | --- |
| `renderPassEvent` | `BeforeRenderingOpaques`（250） | 自定义 Pass 执行时机 |
| `textureSize` | `1024` | 运行时 `HeightMapRT` 的宽高 |
| `terrainLayer` | **Nothing（掩码 0）** | 当前不绘制地形高度；启用时选择地形所在层 |
| `orthoCamera` | 运行时从 Manager 获取 | 不需要在 Renderer 资源中直接引用场景相机 |

Feature 会更新全局 `_HeightMapCameraParams`，内容为相机中心 XZ 与正交半尺寸，雪地 Shader 用它计算脚印 UV。Feature 同时发布 `_TerrainHeightMap`；当前雪地 Shader 虽声明该纹理，但未采样它，脚印形变实际读取材质的 `_footprintsMap`。不要把这条高度输出通道当成已实现的脚印自阴影。

## 效果原理与调整

```text
角色移动 → footprints 按距离发射粒子
         → footCamera 将粒子渲染到 snowfootwrite
         → snowshader 按世界 XZ 计算脚印 UV
         → 曲面细分后沿原法线下压，并重建法线 / 切线
```

- 脚印疏密：调整 `emitDistance`，值越小发射越密。
- 凹陷深度：调整材质 `_DepthScale` 与 `_MaxDepth`，同时观察边缘光照。
- 覆盖范围：调整脚印相机 Orthographic Size；相同分辨率下，范围越大，每米的纹素越少。
- 几何精度：当前细分等级随观察距离从 `8` 降至 `2`，距离尺度为 `50 m`，常量位于 `snowshader.shader`。
- 纹理精度：Shader 中差分计算含固定的 `1024`。调整脚印纹理分辨率时应同步修改该处；Feature 的 `textureSize` 只控制另一张 `HeightMapRT`。

## 常见问题

| 现象 | 检查项 |
| --- | --- |
| 角色或视角无法操作 | Game 窗口是否获得焦点；Active Input Handling 是否支持旧输入系统；输入轴是否存在 |
| 看不到脚印 | `footPS`、`footcam`、Manager 的相机引用是否齐全；粒子 Layer 与相机 Culling Mask 是否一致；相机 Target Texture 与材质 `_footprintsMap` 是否为同一资源 |
| 粒子有输出但雪地不凹陷 | Manager 与 Renderer Feature 是否生效；雪地 Shader、深度参数及曲面细分支持是否正常 |
| 转身后脚印错位 | 脚印相机是否继承角色旋转；相机是否保持世界 `(90, 0, 0)`；粒子是否使用世界空间模拟与对齐 |
| 脚印残留或随相机移动拖影 | 当前使用不清屏且未实现滚动重投影；先检查纹理内容与相机移动关系，按需求增加清理或重投影 |
| `_TerrainHeightMap` 没有地形内容 | `terrainLayer` 当前为 Nothing；需配置地形层与 `HeightMap` Pass，该纹理不直接驱动现有脚印位移 |
| 材质变粉或 Shader 报错 | Unity / URP 版本是否匹配；图形 API 是否支持 Shader Target 4.6 与曲面细分 |

## 修改后检查

1. 打开示例场景，确认 Console 无新增脚本或 Shader 编译错误。
2. 进入 Play 模式，检查角色移动、转向、视角旋转和缩放。
3. 连续移动并转身，确认粒子落点、纹理输出和雪地凹陷对应。
4. 修改深度、间距或覆盖范围后，检查近处细节与范围边界。
5. 提交资源变更时一并提交对应 `.meta`；保留 `Packages/manifest.json`、`packages-lock.json` 和所需内嵌包。

以上为人工验证步骤；文档中的配置值依据仓库文件整理，不代表已完成各平台构建或性能验证。
