%PARAMETRICUAV_MAX_INIT Load one JSON profile into the RflySim model.

modelFile = get_param(bdroot, "FileName");
projectRoot = fileparts(fileparts(modelFile));
addpath(fullfile(projectRoot, "src"));

profilePath = getenv("RFLY_UAV_PROFILE");
if strlength(string(profilePath)) == 0
    profilePath = fullfile(projectRoot, "configs", "quad_x.json");
end
[VehicleConfig, ModelParams, ValidationReport] = rfly_load_profile(profilePath); %#ok<NASGU>

ModelParam_3DType = int16(VehicleConfig.visual.class_id);
ModelParam_uavType = int16(3);
ModelParam_uavMotNumbs = int8(ModelParams.active_count);
ModelInit_PosE = double(VehicleConfig.initial.position_ned_m(:)).';
ModelInit_AngEuler = double(VehicleConfig.initial.euler_rad(:)).';
ModelInit_VelB = double(VehicleConfig.initial.velocity_body_m_s(:));
ModelInit_RateB = double(VehicleConfig.initial.rate_body_rad_s(:));
ModelParam_GPSLatLong = double(VehicleConfig.environment.gps_lat_lon_deg(:)).';
ModelParam_envAltitude = double(VehicleConfig.environment.origin_altitude_ned_m);

FaultParamAPI.FaultInParams = zeros(32, 1);
FaultParamAPI.InitInParams = zeros(32, 1);
FaultParamAPI.DynModiParams = zeros(64, 1);
FaultParamAPI.DynModiParams(1) = 100;

ModelParam_uavMass = ModelParams.mass_kg;
ModelParam_uavJ = ModelParams.inertia_kg_m2;
ModelParam_uavCd = ModelParams.drag_coefficient;
ModelParam_uavCCm = ModelParams.angular_damping;
ModelParam_uavDearo = ModelParams.characteristic_length_m;

ModelParam_motorCmdMin = ModelParams.motor_command_min;
ModelParam_motorCmdSpan = ModelParams.motor_command_span;
ModelParam_motorOmegaMax = ModelParams.motor_omega_max_rad_s;
ModelParam_motorInvTau = ModelParams.motor_inverse_tau;
ModelInit_MotorRad_s = ModelParams.initial_motor_rad_s;
ModelParam_forceGain = ModelParams.force_gain;
ModelParam_momentGain = ModelParams.moment_gain;

% Compatibility variables retained for vendor blocks outside the replaced path.
ModelParam_motorMinThr = 0;
ModelParam_motorCr = 0;
ModelParam_motorWb = 0;
ModelParam_motorT = 1;
ModelParam_motorJm = 0;
ModelParam_rotorCm = 0;
ModelParam_rotorCt = 0;
ModelParam_uavR = 0;
ModelInit_RPM = 0;
ModelInit_Inputs = zeros(1, 16);

