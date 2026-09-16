# RflyParametricUAV

基于 RflySim `Exp2_MaxModelTemp` 最大模板的参数化无人机动力学工程。
第一版支持标准 Quad-X 和四旋翼加尾推两种固定构型。RflySim 的
6DOF、碰撞、传感器、GPS、3D、SIL、外部控制和集群接口保持不变；
项目只替换电机动态以及执行器合力/合力矩计算。

## 快速开始

1. 复制并检查 `settings.example.json`，按本机环境创建
   `settings.local.json`。当前工作机已经生成了一份本地配置。
2. 校验配置：

   ```powershell
   .\rfly-uav.cmd validate -Profile configs\tailpusher_36kg.json
   ```

3. 构建带缓存的 DLL：

   ```powershell
   .\rfly-uav.cmd build -Profile configs\tailpusher_36kg.json
   ```

   缓存键由配置、模型、初始化脚本、构建工具和 `src/*.m` 的 SHA-256
   共同生成；完全相同的物理配置和模型会直接复用缓存 DLL。

4. 启动单机 SITL：

   ```powershell
   .\rfly-uav.cmd run -Profile configs\tailpusher_36kg.json
   ```

5. 只关闭该次启动所记录的进程：

   ```powershell
   .\rfly-uav.cmd stop -RunId <run-id>
   ```

`rfly-uav.cmd` 只负责绕过本机默认的 PowerShell 脚本执行策略，实际逻辑仍在
`rfly-uav.ps1`。也可以在允许脚本执行的 PowerShell 会话中直接调用 `.ps1`。

部署不会覆盖不同内容的已有 DLL/XML。`visual.install_mode` 控制 UE 三维资源：

- `builtin`：使用 RflySim 内置 ClassID，不安装 XML；
- `reuse_existing`：校验并复用 `existing_xml_name`，不覆盖 XML；
- `generated`：安装本项目生成的 XML，遇到 ClassID 或文件冲突时停止。

当前 Quad-X 使用内置 `ClassID=3`，TailPusher 复用现有
`TailPusher_F450.xml`（`ClassID=4510`）。

两种构型统一使用 `settings.local.json` 中的 `custom_px4` 源码树：Quad-X
加载标准 `iris` airframe，TailPusher 加载 `4510_tailpusher`。项目不会自动
修改该 PX4 源码树、control allocation 或 PID。

## 配置约定

- 动力学采用 FRD：`+X` 向前、`+Y` 向右、`+Z` 向下。
- `thrust_axis_b` 是推力方向的机体系单位向量。
- `reaction_torque_sign` 直接定义反扭矩沿 `thrust_axis_b` 的正负，
  因而反扭矩为
  `reaction_torque_sign * C_Q * omega^2 * thrust_axis_b`。
- 执行器通道必须从 1 开始且连续；通道 1--4 为升力旋翼，TailPusher
  的通道 5 为尾推。
- 所有物理量只接受 JSON 字段名标注的 SI 单位。
- `validation_status` 不是 `measured` 时会产生警告，但不会阻止构建。
- v1 不会自动修改 PX4 control allocation 或 PID，只校验既有 airframe
  与输出顺序。

配置可以直接给出 `thrust_coeff_N_s2`、`torque_coeff_Nm_s2` 和
`max_speed_rad_s`，也可以改为提供 `static_table`（`rpm`、`thrust_N`、
`torque_Nm`）；两种方式不能同时使用。静态表采用过原点最小二乘拟合
`T=C_T*omega^2`、`Q=C_Q*omega^2`。

## 目录

- `vendor/`：未经修改的 RflySim 最大模板基线。
- `model/ParametricUAV_Max.slx`：项目自有模型。
- `src/`：JSON 校验、参数转换、构建和 3D XML 生成函数。
- `configs/`：可版本控制的机型配置。
- `artifacts/`：按配置哈希缓存的 DLL、XML 和构建清单。
- `logs/`：启动状态与运行日志。
- `tests/`：MATLAB 类测试。
- `scripts/sitl_multiple_run_rfly_custom.sh`：在不修改 RflySim/PX4 的前提下，
  将已安装的 Rfly 多实例启动逻辑适配到自定义 TailPusher PX4 源码树。

TailPusher 下的 LADAC 派生模型只用于离线对照；运行 DLL 不链接或复制
LADAC 模型内容。

## 仿真进程清理与机型选择

使用终端编号菜单选择 `configs` 目录中的机型并启动仿真：

```powershell
.\select-sim.cmd
```

菜单会自动显示配置的 `profile_id`、构型、PX4 airframe 和执行器数量。
如果已有仿真运行，菜单会列出相关进程，并在得到确认后清理旧仿真再启动
所选机型。

一键关闭本项目的 PX4、CopterSim、RflySim3D 和 QGroundControl：

```powershell
.\cleanup-sim.cmd
```

默认会显示目标并要求确认。无人值守清理可使用：

```powershell
.\cleanup-sim.cmd -Force
```

清理命令只匹配 `settings.local.json` 中配置的 PX4 源码树和项目启动脚本，
不会关闭整个 WSL 发行版。原有的以下命令仍用于只停止指定运行记录：

```powershell
.\rfly-uav.cmd stop -RunId <run-id>
```

启动命令现在会在打开 QGC、RflySim3D 和 CopterSim 前同时检查 Windows 与
WSL 残留；发现冲突时会提示先运行 `cleanup-sim.cmd`。

PowerShell 进程工具测试：

```powershell
Invoke-Pester .\tests\RflyUav.ProcessTools.Tests.ps1
```

## 来源与授权

本项目基于 RflySim 提供的 `Exp2_MaxModelTemp` 最大模型模板开发，
并使用其 `GenerateModelDLLFile.p` DLL 生成接口。具体的上游文件、
项目修改范围和归属说明见 [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md)。

本仓库当前公开仅为了查看、学习和协作，尚未选定开源许可证。
除第三方内容受其各自条款约束外，未经明确授权，不额外授予复制、
修改、分发或商业使用本项目自有内容的许可。
