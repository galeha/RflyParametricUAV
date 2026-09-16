

%% 关键参数

% 下面这个参数决定了飞机的显示样式
ModelParam_3DType = int16(3); %这里是四旋翼X型，具体定义见文档"机型定义文档.docx"
% 注意，这里需要和RflySim3D的XML文件中的ClassID相匹配。

ModelParam_uavType = int16(3); %决定了四旋翼力和力矩的计算方式

% 初始位姿参数，这两个变量名必须存在，CopterSim才能修改飞机的初始位置
ModelInit_PosE=[0,0,0]; % 飞机初始位置，单位米
ModelInit_AngEuler=[0,0,0];% 飞机初始姿态，单位弧度
% 注意1：当ModelInit_PosE参数存在时，CopterSim会根据UI上的x和y坐标来修改ModelInit_PosE[0]和ModelInit_PosE[1]的值，来配置飞机的初始位置
% ModelInit_PosE[2]初始高度的值，会被CopterSim中读取的地图txt文件中的高度修改，不可以手动配置。
% ModelInit_AngEuler[2]会被CopterSim会根据UI上的yaw输入填充，从而改变飞机初始偏航角
% 初始滚转角和俯仰角ModelInit_AngEuler[0]和ModelInit_AngEuler[1]由这里设置的值决定，CopterSim无法修改。

% 注意2：你也可以不使用ModelInit_PosE和ModelInit_AngEuler变量名，这样CopterSim就没法修改你的初始位置，在集群仿真时，所有飞机会初始化在同一位置。


% 下面的参数，决定了QGC中显示的地图坐标和高度原点
ModelParam_GPSLatLong = [40.1540302 116.2593683]; % 飞机初始的纬度和精度，单位度。
ModelParam_envAltitude = -50;     %原点的海拔高度，竖直向下为正，高于海平面填负值，单位米。
% 注意1：由于Simulink使用的地球大气模型不支持海平面以下的输入，ModelParam_envAltitude取值必须为负。
% 注意2：你也可以不使用ModelParam_GPSLatLong和ModelParam_envAltitude变量名，这样CopterSim无法从外部（地图txt中读取）修改GPS坐标。



%% 故障与参数接口参数
% Define the 32-D FaultInParams vector for external modification

% 故障注入参数接口，32维
FaultParamAPI.FaultInParams = zeros(32,1);

% 模型重新初始化接口，32维
FaultParamAPI.InitInParams = zeros(32,1);

% 模型动态修改参数接口，64维
FaultParamAPI.DynModiParams = zeros(64,1);
FaultParamAPI.DynModiParams(1)=100;

%Initial condition


%% 6DOF模块相关参数
% 飞机质量：
ModelParam_uavMass=1.515;
% 转动惯量
ModelParam_uavJ= [0.0211,0,0;0,0.0219,0;0,0,0.0366];
ModelInit_VelB=[0,0,0];
ModelInit_RateB=[0,0,0];


%% 电机模型参数
ModelParam_uavMotNumbs = int8(4);
%ModelParam_ControlMode = int8(1); %整型 1表示Auto模式，0表示Manual模式
ModelParam_motorMinThr=0.05;
ModelParam_motorCr=842.1;
ModelParam_motorWb=22.83;
ModelParam_motorT= 0.0214;%0.0261;
ModelParam_motorJm =0.0001287;
ModelParam_rotorCm=2.783e-07;
ModelParam_rotorCt=1.681e-05;
ModelInit_RPM = 0; %Initial motor speed (rad/s)
ModelInit_Inputs = [0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0];



%% 力和力矩模型参数
ModelParam_uavR=0.225;
%ModelParam_uavCtrlEn = int8(0);
ModelParam_uavCd = 0.055;
ModelParam_uavCCm = [0.0035 0.0039 0.0034];
ModelParam_uavDearo = 0.12;%%unit m