# AGENTS.md（中文译文）

> 本文件是 [AGENTS.md](AGENTS.md) 的中文译文，仅供阅读。如有出入，以英文原文为准。

Microduck 是一款约 800 克、约 25 厘米高的双足机器人，带有 14 个 Dynamixel XL330 舵机。本仓库基于 [mjlab](https://github.com/mujocolab/mjlab)（MuJoCo Warp），使用 PPO（rsl_rl）训练强化学习环境。策略在这里以 50 Hz 训练，导出为 ONNX，再由 `pollen-robotics/microduck` 仓库中的运行时部署到真机上。Sim2real 迁移是这个项目的核心目标。下面的每一条约定，都是因为违反它而产生过一个"在 viewer 里能走、上真机却失败"的策略。

## 命令

```bash
uv run list-envs                                    # 实时任务注册表
uv run train <TASK_ID> --env.scene.num-envs 4096    # 训练（加 --hf-jobs 可提交到 Hugging Face Jobs）
uv run train <TASK_ID> --env.scene.num-envs 64 --agent.max_iterations 5   # 冒烟测试，每次长训练前必须先跑
uv run play <TASK_ID> --wandb-run-path <entity/project/run_id>
uv run scripts/export.py <TASK_ID> --wandb-run-path <...>   # → ONNX（烘焙观测归一化器，这是唯一允许的导出路径）
uv run publish --task <TASK_ID> --wandb-run-path <...> --checkpoint N --repo <user>/microduck-<name> --kind episodic --duration-s 4.0
                                                    # → HF Hub 仓库（policy.onnx + schema-2 manifest.json + README），守护进程通过 `robotctl policy add` 加载
                                    #   加 --share-training 可同时打包训练 checkpoint（需主动开启，见下文）
uv run share-training --wandb-run-path <...> --checkpoint N [--onnx hf://<policy-repo>/<file>.onnx]
                                    # → 训练包（完整 .pt + 溯源信息 + teachers）存入 <owner>/microduck-training
uv run train <TASK_ID> --init-checkpoint hf://<owner>/microduck-training/bundles/<exp>/<run>_<iter>
                                    # 从训练包恢复（设置 MICRODUCK_WARM_START=1 可用于热启动另一个任务）
uv run scripts/infer_policy.py --walking out.onnx   # CPU MuJoCo 部署预演（BAM M6 执行器与训练一致；--no-bam 为 XML PD）
uv run --with pytest pytest tests/
```

5 轮、64 环境的冒烟测试能抓住约 95% 的配置错误，成本几乎为零。永远不要在没做冒烟测试的情况下启动长训练。

## 仓库结构

- `src/mjlab_microduck/tasks/mdp.py`：所有自定义 MDP 函数（奖励、事件、观测、命令、课程）。新函数加在这里，并按任务分组。
- `src/mjlab_microduck/tasks/microduck_*_env_cfg.py`：每个任务族一个 cfg 模块。`microduck_velocity_env_cfg.py` 既是主行走配方，也是其他环境构建或参照的共享基础（机器人、域随机化、观测、命令）。
- `src/mjlab_microduck/tasks/__init__.py`：任务注册（基础任务与 `-Backlash-` 变体）。
- `src/mjlab_microduck/tasks/backlash.py`：把任意环境 cfg 包装成它的回差（backlash）版本。
- `src/mjlab_microduck/robot/microduck_constants.py`：机器人 cfg、HOME 姿态、BAM 执行器 cfg。
- `src/mjlab_microduck/robot/microduck/`：从 Onshape 导出的 MJCF 模型（onshape-to-robot，每个模型一个 `config_mjcf_*.json`）、场景文件和 `add_backlash.py`。碰撞类型有三种：`walk`（只有脚）、`groundcontact`（精选的地面接触集合）、`allcollisions`（每个部件都有碰撞体；XL330 外壳会被 `name_servo_collision_geoms` 命名为 `*_servo_collision`，供 VelStand 的舵机撞击传感器使用）。每种都有一个由 `add_backlash.py <xml> --backlash-deg 2.0` 生成的 `_backlash` 版本。
- `src/mjlab_microduck/actuator/friction_dr_bam.py`：BAM 执行器、摩擦域随机化、回差编码器反馈。
- `src/mjlab_microduck/export.py`：ONNX 导出（烘焙归一化器）；`scripts/export.py` 是它的封装。
- `src/mjlab_microduck/publish/`：`uv run publish` 所在目录，包括 schema-2 清单构建器、ONNX 形状与冒烟检查、Hub 上传；`training.py` 对应 `uv run share-training`（训练包）。
- `src/mjlab_microduck/checkpoints.py`：checkpoint 规格（`hf://...` 训练包或本地路径）、`--init-checkpoint` 训练参数，供训练、导出和蒸馏 teachers 使用。契约见 `microduck` 仓库中的 `docs/policy-manifest.md`。只有指令恒定的 episodic / perpetual 策略可以发布（phase 和 posture-flag 是该策略集自己的约定）。
- `scripts/`：导出封装、推理、sim2real 对比、wandb 辅助脚本。
- `tests/`：配置不变量和 mdp 函数的回归测试（CPU 运行，不需要 GPU）。

## 不可破坏的约定

- **观测布局为 61 维（actor），在整个策略家族中保持一致**，这样策略才能在运行时热切换：48 维基础本体感觉，加上 13 维命令块 `[twist(3), head_pose(4), body_pose(6)]`，顺序不能变。不使用某个命令槽的环境要对它做零填充（保留观测项，采样很小的范围），绝不能删除一个槽。
- **关节布局**（14 个舵机，在 walk / groundcontact 模型上 ctrl 索引等于关节索引）：0–4 为左腿（hip_yaw、hip_roll、hip_pitch、knee、ankle），5–8 为颈部和头部（neck_pitch、head_pitch、head_yaw、head_roll），9–13 为右腿。在滚轴和回差模型上，被动关节是交错排列的，所以不要在 mdp 函数里硬编码关节索引，应使用 mdp.py 中的 `_servo_joint_ids` / `_servo_joint_pos` 辅助函数（在普通模型上是恒等映射，在其他模型上也正确）。
- **未驱动的关节都以 `passive_*` 命名**（轮子、回差铰链）。所有执行器、观测和奖励的选择器都使用 `^(?!passive_).*`。添加关节时保持这个前缀约定。新的 `passive_` 正则不能误匹配回差关节，所以用 `^passive_.*wheel`，而不是 `^passive_.*`。
- **执行器是 BAM**（电压控制的 XL330 模型，摩擦由执行器计算）。这带来两个后果：任何独立的环境 cfg 都必须注册 `expand_bam_friction_fields` 启动事件；关节摩擦域随机化必须缩放执行器的 `friction_scale`。在 BAM 下 `dof_frictionloss` 会被置零，对它做随机化会悄无声息地失效。
- **观测归一化是开启的**，所以归一化器必须烘焙进 ONNX。`scripts/export.py` 会处理这一点。仿真中的 play 会隐藏这个问题（它本来就会应用归一化器），所以绝不要手动转换 checkpoint。
- **策略是未滤波的**（训练时没有动作低通滤波）。除非有匹配的运行时标志和迁移测试，否则不要加 EMA 滤波。训练时用了滤波、部署时没用（或反过来），都会破坏迁移。
- **域随机化不能在多次 reset 之间累积。** mjlab 1.3.0 中 `dr.*` 的 `operation="add"` / `"scale"` 天然不累积（它们每次都重新读取编译期的默认值）。自定义的域随机化函数必须先恢复再应用。曾经有一个会累积的质心随机化器，让之后每次长训练都变差，持续了好几个月。
- 如果某个观测被重映射到传感器视角（回差编码器、偏置），那么对同一个量的跟踪奖励也必须在同一视角下计算。否则策略会因为纠正它所看到的东西而受到惩罚。
- `-Backlash-` 任务变体必须与基础任务使用相同的机器人模型（walk / groundcontact / rollers），这样回差的 A/B 对比才没有混淆变量。

## 构建新环境的流程

1. **选择最接近的模板，在它的基础上修改，不要从零开始。** 移动类任务用速度配方；以某个姿态结束的情节式技巧用 standup；指令驱动的两态切换用 sitstand；动态机动用 roulade（先读它的 cfg 文档字符串，里面记录了一套五次实验的经验）。基于 `make_microduck_velocity*_env_cfg` 构建，可以自动同步域随机化、观测、噪声和延迟的设置。如果从 mjlab 的基础模板独立构建，就必须自己移植整套域随机化、观测噪声和 NaN 保护。可以 grep 速度任务里接好的内容：`_safe` 的 critic 观测项、带 sensor_names 的 `nan_state` 终止条件、`expand_bam_friction_fields`、编码器偏置、IMU 安装误差。
2. **训练前先在仿真中验证物理假设，这是最能节省时间的一步。**
   - 目标或静止姿态必须是稳定平衡点：用噪声初始化，保持其控制量 3 秒，检查倾斜角，而不只是高度。只记录高度的稳定性测试会把倒下的状态误报为"静止正常"。
   - 直接从仿真中的真实机器人测量目标高度（例如站立策略下的躯干 z），不要跨模型版本沿用旧数值。曾经有一个偏了 5 毫米的 STAND_Z，让目标在好几天里都无法达到。
3. **配置约定**：文件顶部放 `ENABLE_*` 开关和调好的常量；工厂函数为 `make_..._env_cfg(play: bool, rough: bool)`；在 `tasks/__init__.py` 注册（如适用，还要加入 `_BACKLASH_TASKS` 表）；用独立的 `experiment_name` 定义自己的 `RslRl...RunnerCfg`。对称镜像损失可用（`symmetry.py` 中的 61 维表），但默认关闭，绝不能用于不对称任务。
4. **编写 cfg 测试**（参考 `tests/test_*_cfg.py`）：检查关节索引在真实模型上能解析，奖励权重符号符合预期，门控在预期的地方开启或关闭。这些测试在 CPU 上运行，用来固定上述不变量。
5. **冒烟测试**（64 个环境，5 轮）：确认能构建、仿真无 NaN、观测为 61 维、每个奖励项都能计算、ONNX 能导出。
6. 训练，观察下面讲的日志。预计会有 2 到 5 轮"奖励黑客"式的打地鼠，这很正常，下面的经验能省掉大部分弯路。

## 奖励设计：每条规则都是血泪教训

- **符号约定（最容易出错的地方）：** mdp.py 里有两种惩罚写法。mjlab 基础的代价函数返回 ≥ 0 的值，所以权重取负。微鸭自己写的自我取负函数（`*_penalty`、`*_l1`，返回 ≤ 0）权重取正。对自我取负的惩罚使用负权重，会双重取负，变成对违规行为的奖励，策略就会去刷它，比如屁股跳、崩溃式坐下。**一条可靠的检查方法：每次训练中，wandb 里每个 `Episode_Reward/<penalty>` 都必须 ≤ 0。**
- **强化学习会钻奖励条款的字面漏洞。** 每个没有约束清楚的自由度都会被利用，比如用弹道式甩动代替翻滚，用肩部侧滚代替矢状面运动，用三脚的头部站立代替站直。应该用基于状态的硬门控（支撑接触、姿态轴检查、锁存）来定义什么算作目标动作，而不是用小的惩罚项去轻推。
- **不要设计"奖励跳跃"。** 任何"到达 X"的奖励都必须限速或做斜坡处理。提前到达目标状态、然后每步继续得分，就是一个跳跃奖励，会诱发任意的暴力行为。对于指令驱动的过渡，应该跟踪一个斜坡化的内部目标（恒定速率混合）。领先于斜坡得零分，所以慢才是最优解。仅靠速度上限惩罚，积分后的代价有界，会输给策略。
- **永远不要把正奖励建立在"处于不好状态"上**（摔倒、位置低）。策略会停在最便宜的、满足条件的姿态上并刷分。应该改用基于势函数的整形，只奖励进展的增量，比如 Δcos(倾斜角)：上升时得分，保持时得零分，无法刷。对于静止类任务，要检查每个正向奖励项在各个稳定倒伏姿态（背、脸、侧）下的表现。如果倒下还能保住大部分重心，策略就会倒下。
- **情节式姿态着陆任务：** 从 t=0 就给一个固定的单一目标（对关节和高度使用高斯加 L1，标准差要取宽），加上 |a_z| 冲击惩罚和两层直立约束。**不要用关键帧或路标轨迹**，策略会停在路标上。路径正是 RL 应该去发现的东西。
- **正则化分两类。** 运动阻挡类（body_ang_vel、angular_momentum、姿态标准差）会惩罚动态动作本身需要的运动，动态任务中应保持较低权重。平滑类（action_rate、joint_torque_rate）抑制抖动，但不阻止缓慢的大幅运动，可以安全地加权。不过要在技能发现之后才引入（从 0 开始做课程），因为在困难技能还在探索时加上任何"尝试税"，都会让"什么都不做"占优。
- **复制正则化项时比较奖励总量，而不是权重。** PPO 看的是相对优势。正奖励总量大了 4 倍，同样的 action_rate 权重就弱了 4 倍。
- **跟踪高斯的标准差：** 应该接近你仍然在意的误差大小，而不是最大误差。太宽则小误差时没有梯度。但在收紧之前，先问这个误差是策略能避免的，还是这种行为本身固有的。例如头部质量占体重 38%，走路时头部必然晃动；一个过紧的瞬时头部跟踪标准差让策略负担过重，最后直接站着不动。只对可避免的部分收费，比如对 1 秒 EMA 做 L1，这样只收取直流偏置，并且允许振荡相互抵消。
- **乘性复合优于加性求和（用于目标状态）：** 当加性叠加存在折中盆地（靠一个倾斜姿态让每一项都拿到 80%），高斯乘积在任何一个因子不足时都会大幅下降，因此更能拉开差距。但标准差要选得足够宽，让当前策略也能得到可见的分数，否则梯度不可见，什么也不会改变。
- **关节停在硬限位上：** 用 qpos 侧的限位接近惩罚来修复。原生的 `dof_pos_limits` 只在行程末端约 7.5% 的范围内触发，命令侧的惩罚没有用（故意设置较宽的 ctrlrange，因为低 kp 的舵机需要超调）。

## 命令、观测与"死权重"

- **如果一个命令输入从来不是非零，它的权重就永远是"死"的。** 每个命令槽从第 0 步起就要保留一个很小的非零采样范围（即使奖励权重为 0），这样它的输入神经元才能在之后的课程中保持活跃。
- **零指令行为必须被显式训练**（类似 `zero_command_prob` 的精确零采样）。均匀采样几乎不会产生全零指令，而全零恰恰是部署时的待机状态。
- **罕见但重要的指令区域需要显式分桶。** 例如原地转身（`rel_turn_in_place_envs`）：独立均匀采样时，转身只占约 2% 的经验，结果从来没有学会。

## 课程

- 步数是环境步数：`iteration × 24`（`NUM_STEPS_PER_ENV = 24`）。
- 使用已验证的分工：权重调度用 `microduck_mdp.reward_weight`，命令和事件范围用专门的参数课程。`mdp.reward_weight` 是阶跃函数，不是插值，所以要把斜坡离散成若干阶段。
- 通过管理器修改 term cfg（`env.event_manager.get_term_cfg(...)`），绝不要改 `env.cfg.events[...]`。管理器在初始化时会深拷贝 cfg，写入 `env.cfg` 会静默失效。这也会影响强制设定出生状态的评估脚本。
- **让每个阶段与策略实际学到的内容对齐。** 在当前阶段没有巩固之前，不要加大出生状态的混合难度；在技能还没形成之前，不要引入税或惩罚。当 wandb 里的某个指标恰好在课程阶段边界处下降时，说明节奏不对，应该拉长阶段或把引入时间推后，而不是提前。
- 逆向课程（从动作中途开始的回合，包括接近结束的回合）是解决"学会了开头，却学不会最后一段"的可靠方法。否则前沿状态得不到在线策略的数据。

## 训练运维与读懂一次运行

- wandb 项目名为 `mjlab_microduck`；日志在 `logs/<experiment_name>/`；用 `--agent.load-checkpoint model_XXXX.pt --agent.resume True` 恢复。
- **热启动不等于恢复。** mjlab 的 runner 会把 `common_step_counter` 存进 checkpoint，并在加载时恢复它（以及迭代数）。所以加载另一个任务的 checkpoint，会让所有基于步数的课程在第 1 轮直接跳到最终阶段。加上前缀 `MICRODUCK_WARM_START=1`（mdp.py 中的 Patch 5，也会转发到 HF Jobs），可以把两者都重置为 0，同时保留权重、归一化器和优化器。还要把源任务继承的课程在目标 cfg 中折叠到最终阶段（参见 velstand 中的 `_collapse_curricula_to_final`），因为加载的策略就是在这些条件下训练出来的。只在归一化器兼容的任务之间做热启动。站立专家的 twist 标准差是 0.005，绝不能用它来初始化一个行走环境。
- **部署策略的溯源：** 2026-10-27 之后导出的 ONNX 在元数据中携带溯源信息（`run_path`、`task_id`、`checkpoint`、`checkpoint_sha256`）。更早的 Hub 文件只有 `run_path=None`。`pollen-robotics/microduck-training` 中的训练包在每个 `bundle.json` 的 `onnx[]` 中记录这些信息，并通过 sha256 匹配。对于尚未打包的 ONNX，`scripts/find_onnx_source.py` 会通过与 wandb checkpoint 精确比对权重来找到对应的运行。（2026-09 的记录：walk = 441tzs6d@3750，stand = 69u48n8l@9750；Hub 上的 velstand v7 = v9（当前）= j4i6yoq2@1250，谱系见 `docs/velstand_policy.md`，sitstand 见 `docs/sitstand_policy.md`。）
- 每轮都要观察：平均奖励在上升，同时回合长度符合任务要求；每个惩罚项都 ≤ 0；主任务项确实在增长。总奖励可能只靠正则项上升，而技巧从未学会。`Episode_Reward/<term>` 记录的是**加权后的**值，权重为 0 的项显示为 0，无论行为如何，所以要结合权重调度来解读。
- **预算：** 简单的情节式技巧在 4096 环境下约需 1000 轮；步态以及课程较重的恢复类任务需要 4000 到 6000 轮。
- **先测量，再推理论。** "训练失败"时，先对实际 checkpoint 做无头评估（按出生类型分组的测试、末态聚类、角速度曲线），再修改奖励。过去的"失败"结果分别是：早期 checkpoint、把一个行为簇一分为二的成功判据，以及一个与物理冲突的奖励上限。仿真指标可能通过，而视频肉眼看却失败，所以要同时看视频，并检查是哪个 geom 或轴在接触。
- 汇报实际 rollout 的表现（"能翻滚，但 3 次里有 1 次脸朝下摔倒"），不要写"成功了！"。什么时候足够好，由用户决定。

## 分享训练 checkpoint（训练包）

完整参考：`docs/training_checkpoints.md`。智能体必须遵守的规则：

- **始终需要用户主动选择。** 除非用户在本次会话中明确要求，否则绝不上传 checkpoint，也不要把训练包仓库改为公开。`publish` 不加 `--share-training` 就不会分享额外内容。`share-training` 默认创建私有仓库，除非加 `--public`。
- **绝不把 `.pt` 文件放进策略（ONNX）仓库。** 训练包放在单独的仓库 `<owner>/microduck-training` 中，每个实验、运行、迭代对应一个文件夹 `bundles/<experiment>/<run>_<iter>/`。
- **当某个策略在 Hub 上更新后**（通过 `publish`，或手动在 `pollen-robotics/microduck-policies` 中修改），如果用户希望分享 checkpoint，就对确切的 checkpoint 运行 `share-training`，并附上 `--onnx <已部署的文件>`。如果它拒绝记录某个 ONNX（其 actor 权重与之不是逐位一致），说明溯源信息有误。应该用 `scripts/find_onnx_source.py` 找到正确的 checkpoint，绝不能为了通过检查而去掉 `--onnx`。标签与策略集保持一致（`--tag velstand-v9`）。
- **教师模型会自动附带**（从运行自身的 `bc_cfg` 中读取），所以 velstand 训练包不需要 wandb 访问权限也能训练。不要手动上传教师模型。
- **训练包是不可变的**（以运行和迭代为键；在已存在的 id 下使用不同的 checkpoint 会被拒绝）。只有 `onnx` 记录可以合并进已有训练包。
- **加载：** `--init-checkpoint <spec>` 替代 `--agent.resume` 加 `--wandb-run-path`（两者同时给会报错）。它是**恢复**，课程会继续。跨任务做热启动时加前缀 `MICRODUCK_WARM_START=1`（见上文"热启动不等于恢复"）。先检出训练包中的 `code.commit`（以及 `uncommitted.diff`）。
- `share-training` 的 `--checkpoint-file` 模式（不使用 wandb）会把当前检出的 HEAD 记录为溯源信息，并拒绝有未提交改动的工作区。分享前先提交并推送。

## Sim2real 陷阱（每个都曾耗费数周调试）

- 全新的 `uv sync` 才是基准，HF Jobs 运行的就是它。只能通过手动安装的本地包才能工作的东西，远程必然失败。保持 `pyproject.toml` 诚实。
- **轮子与架构相关。** 在 linux-`aarch64`（DGX Spark / GB10）上，PyPI 的 torch 轮子只有 CPU 版（`2.9.1+cpu`，`torch.version.cuda is None`）。所以 `torch.cuda.device_count() == 0`，mjlab 的 `select_gpus()` 会索引一个空列表，在第 0 轮之前就抛出 `IndexError`。`[tool.uv.sources]` 只在 `aarch64` 上把 torch 指向 cu129 索引（cu129 与 warp 自带的 CUDA 工具包匹配；x86_64 和 HF Jobs 仍使用 PyPI）。有两个会悄无声息出错的地方，都由 `tests/test_aarch64_cuda_torch.py` 锁定：torch 必须保持为直接依赖（uv 只对直接依赖应用 `[tool.uv.sources]`，删掉看似多余的 `torch==` 固定会让这个路由失效）；固定版本必须保持 `==`，因为 CUDA 索引上的版本比 PyPI 更新（一次 `>=` 就悄悄把 torch 从 2.9.1 拖到了 2.13.0）。
- 物理上的限制：25 厘米高的机器人在 3.5–5.5 rad/s 时会自然翻滚。不要用人类尺度的速度直觉去加上限，应该对冲击和抖动施加约束（|a_z|、action_rate、支撑门控），而不是限制旋转速度。
- IMU 域随机化是零中心的。它训练的是对安装误差幅度的容忍度，无法补偿系统性的安装偏差，那需要在运行时做标定。
- 真机会热切换 ONNX 策略（走、站、技巧），它们共享同一套观测契约。在碰真机之前，先在 `scripts/infer_policy.py` 中预演，并正确写入命令槽。姿态标志位于 twist 的 vx 槽；全零输入意味着"站立"，这会让人误以为"策略忽略了按键"。
